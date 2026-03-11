//! Leader election using a Kubernetes `coordination.k8s.io/v1` Lease resource.
//!
//! A background thread periodically attempts to acquire or renew a Lease
//! object. When leadership is acquired or lost, caller-provided callbacks
//! are invoked. On graceful shutdown the holder identity is cleared so
//! another replica can take over immediately.

const std = @import("std");
const HealthCheck = @import("../util/health_check.zig").HealthCheck;
const client_mod = @import("../client/Client.zig");
const Client = client_mod.Client;
const Context = client_mod.Context;
const Api_mod = @import("../api/Api.zig");
const LeaderMetrics = @import("../util/metrics.zig").LeaderMetrics;
const logging_mod = @import("../util/logging.zig");
const Logger = logging_mod.Logger;
const LogField = logging_mod.Field;
const types = @import("types");
const time_mod = @import("../util/time.zig");
const testing = std.testing;

/// Configuration for leader election via a Kubernetes Lease resource.
pub const LeaderElectionConfig = struct {
    /// Name of the Lease resource to use for leader election.
    lease_name: []const u8,
    /// Namespace in which the Lease resource lives.
    lease_namespace: []const u8,
    /// Unique identity of this candidate (e.g. pod name).
    identity: []const u8,
    /// How long (seconds) a lease is valid before it expires.
    lease_duration_s: i32 = 15,
    /// How often (seconds) the leader renews the lease.
    renew_interval_s: i32 = 10,
    /// How often (seconds) a non-leader retries to acquire.
    retry_period_s: i32 = 2,
    /// Called when this instance becomes the leader.
    on_started_leading: *const fn (ctx: ?*anyopaque) void,
    /// Called when this instance loses leadership.
    on_stopped_leading: *const fn (ctx: ?*anyopaque) void,
    /// Opaque context pointer passed to callbacks.
    callback_ctx: ?*anyopaque = null,
    /// Metrics for observability. Default is no-op.
    metrics: LeaderMetrics = LeaderMetrics.noop,
    /// Structured logger. Default is no-op.
    logger: Logger = Logger.noop,
};

/// Leader elector using a Kubernetes `coordination.k8s.io/v1` Lease resource
/// as a distributed lock. A background thread periodically renews (or attempts
/// to acquire) the lease, and callbacks notify the application when leadership
/// is acquired or lost.
pub const LeaderElector = struct {
    allocator: std.mem.Allocator,
    client: *Client,
    ctx: Context,
    config: LeaderElectionConfig,
    mutex: std.Thread.Mutex,
    stop_cond: std.Thread.Condition,
    state: std.atomic.Value(State),
    renew_thread: ?std.Thread,
    /// Heap-owned resourceVersion from the last observed Lease.
    observed_resource_version: ?[]const u8,
    /// Monotonic time of the last observed lease renewal.
    observed_renew_time: ?std.time.Instant,

    pub const State = enum(u8) {
        idle,
        standby,
        leading,
        stopped,
    };

    const LeaseResult = enum {
        acquired,
        renewed,
        lost,
        err,
    };

    /// Create an elector in `idle` state. Asserts that `renew_interval_s < lease_duration_s`.
    pub fn init(allocator: std.mem.Allocator, client: *Client, ctx: Context, config: LeaderElectionConfig) LeaderElector {
        std.debug.assert(config.renew_interval_s < config.lease_duration_s);
        std.debug.assert(config.retry_period_s > 0);

        var cfg = config;
        cfg.logger = config.logger.withScope("leader_election");

        return .{
            .allocator = allocator,
            .client = client,
            .ctx = ctx,
            .config = cfg,
            .mutex = .{},
            .stop_cond = .{},
            .state = std.atomic.Value(State).init(.idle),
            .renew_thread = null,
            .observed_resource_version = null,
            .observed_renew_time = null,
        };
    }

    /// Release owned memory. The elector must not be in `standby` or `leading` state.
    pub fn deinit(self: *LeaderElector) void {
        const s = self.state.load(.acquire);
        std.debug.assert(s != .standby and s != .leading);
        if (self.observed_resource_version) |rv| {
            self.allocator.free(rv);
            self.observed_resource_version = null;
        }
    }

    /// Spawn the background election loop. Transitions from `idle` to `standby`.
    pub fn start(self: *LeaderElector) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(self.state.raw == .idle);
        self.config.logger.info("leader election starting", &.{
            LogField.string("identity", self.config.identity),
            LogField.string("lease_name", self.config.lease_name),
            LogField.string("lease_namespace", self.config.lease_namespace),
        });
        self.state.store(.standby, .release);

        self.renew_thread = try std.Thread.spawn(.{}, run, .{self});
    }

    /// Signal the election loop to stop and wait for the thread to exit.
    pub fn stop(self: *LeaderElector) void {
        {
            self.mutex.lock();
            defer self.mutex.unlock();

            const s = self.state.raw;
            if (s == .idle or s == .stopped) return;
            self.config.logger.info("leader election stopping", &.{
                LogField.string("identity", self.config.identity),
            });
            self.state.store(.stopped, .release);
            self.stop_cond.signal();
        }

        if (self.renew_thread) |t| {
            t.join();
            self.renew_thread = null;
        }
        self.config.metrics.is_leader.set(0.0);
    }

    /// Returns `true` if currently the leader.
    pub fn isLeader(self: *LeaderElector) bool {
        return self.state.load(.acquire) == .leading;
    }

    /// Return a health check that reports healthy when this instance is the leader.
    pub fn healthCheck(self: *LeaderElector) HealthCheck {
        return HealthCheck.fromTypedCtx(LeaderElector, self, struct {
            fn check(e: *LeaderElector) bool {
                return e.isLeader();
            }
        }.check);
    }

    // Background thread entry point
    fn run(self: *LeaderElector) void {
        if (!self.runAcquirePhase()) return;
        self.runRenewPhase();
    }

    /// Retry until we become the leader or are stopped.
    /// Returns `true` if leadership was acquired, `false` if stopped.
    fn runAcquirePhase(self: *LeaderElector) bool {
        while (true) {
            {
                self.mutex.lock();
                defer self.mutex.unlock();
                if (self.state.raw == .stopped) return false;
            }

            self.config.logger.debug("attempting to acquire leadership", &.{
                LogField.string("identity", self.config.identity),
            });
            const result = self.tryAcquireOrRenew();
            if (result == .acquired) {
                {
                    self.mutex.lock();
                    defer self.mutex.unlock();
                    if (self.state.raw == .stopped) return false;
                    self.state.store(.leading, .release);
                }

                self.config.metrics.is_leader.set(1.0);
                self.config.metrics.transitions_total.inc();
                self.config.logger.info("acquired leadership", &.{
                    LogField.string("identity", self.config.identity),
                    LogField.string("lease_name", self.config.lease_name),
                    LogField.string("lease_namespace", self.config.lease_namespace),
                });
                self.config.on_started_leading(self.config.callback_ctx);
                return true;
            }

            // Sleep for retry_period_s (interruptible).
            {
                self.mutex.lock();
                defer self.mutex.unlock();
                if (self.state.raw == .stopped) return false;
                const retry_ns: u64 = std.math.cast(u64, @as(i64, self.config.retry_period_s) * std.time.ns_per_s) orelse 2 * std.time.ns_per_s;
                self.stop_cond.timedWait(&self.mutex, retry_ns) catch {};
                if (self.state.raw == .stopped) return false;
            }
        }
    }

    /// Keep renewing the lease until we lose leadership or are stopped.
    fn runRenewPhase(self: *LeaderElector) void {
        while (true) {
            {
                self.mutex.lock();
                defer self.mutex.unlock();
                if (self.state.raw == .stopped) return;
            }

            // Sleep for renew_interval_s (interruptible).
            const stopped = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                if (self.state.raw == .stopped) break :blk true;
                const renew_ns: u64 = std.math.cast(u64, @as(i64, self.config.renew_interval_s) * std.time.ns_per_s) orelse 10 * std.time.ns_per_s;
                self.stop_cond.timedWait(&self.mutex, renew_ns) catch {};
                break :blk self.state.raw == .stopped;
            };
            if (stopped) {
                self.config.metrics.is_leader.set(0.0);
                self.releaseLease();
                self.config.logger.info("lease released on shutdown", &.{
                    LogField.string("identity", self.config.identity),
                });
                return;
            }

            const result = self.tryAcquireOrRenew();
            if (result == .renewed) {
                self.config.logger.debug("renewed lease", &.{
                    LogField.string("identity", self.config.identity),
                    LogField.string("lease_name", self.config.lease_name),
                });
                continue;
            }

            // Check if renewal deadline exceeded.
            if (self.renewalDeadlineExceeded()) {
                self.transitionToStandby();
                return;
            }

            if (result == .lost or result == .err) {
                if (result == .err) {
                    self.config.logger.err("lease renewal failed", &.{
                        LogField.string("identity", self.config.identity),
                        LogField.string("lease_name", self.config.lease_name),
                    });
                }
                self.transitionToStandby();
                return;
            }
        }
    }

    /// Transition out of leadership: update metrics, set state to standby, notify callback.
    fn transitionToStandby(self: *LeaderElector) void {
        self.config.logger.warn("lost leadership", &.{
            LogField.string("identity", self.config.identity),
            LogField.string("lease_name", self.config.lease_name),
            LogField.string("lease_namespace", self.config.lease_namespace),
        });
        self.config.metrics.is_leader.set(0.0);
        self.config.metrics.transitions_total.inc();
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.state.raw != .stopped) self.state.store(.standby, .release);
        }
        self.config.on_stopped_leading(self.config.callback_ctx);
    }

    // Core algorithm
    fn tryAcquireOrRenew(self: *LeaderElector) LeaseResult {
        const Lease = types.CoordinationV1Lease;
        const LeaseApi = Api_mod.Api(Lease);

        const api = LeaseApi.init(self.client, self.ctx, self.config.lease_namespace);

        // Format timestamp once for all lease operations in this cycle.
        var ts_buf: [27]u8 = undefined;
        const now_str = time_mod.bufNow(.micros, &ts_buf);

        // GET the existing lease.
        const get_result = api.get(self.config.lease_name) catch |err| {
            self.config.logger.err("failed to get lease", &.{
                LogField.string("error", @errorName(err)),
                LogField.string("lease_name", self.config.lease_name),
            });
            return .err;
        };

        switch (get_result) {
            .ok => |parsed| {
                // Lease exists.
                defer parsed.deinit();
                const lease = parsed.value;

                // Store the observed resourceVersion for optimistic concurrency.
                const rv = if (lease.metadata) |m| m.resourceVersion else null;
                if (rv) |new_rv| {
                    self.setObservedResourceVersion(new_rv);
                }

                const holder = if (lease.spec) |s| s.holderIdentity else null;
                const is_us = if (holder) |h| std.mem.eql(u8, h, self.config.identity) else false;

                if (is_us) {
                    // We hold it, so renew.
                    return self.updateLease(rv, now_str);
                }

                // Someone else holds it. Check if expired.
                const lease_duration_s = if (lease.spec) |s| (s.leaseDurationSeconds orelse self.config.lease_duration_s) else self.config.lease_duration_s;

                if (holder) |h| if (h.len > 0) {
                    // Check expiry based on our observed renewal time.
                    if (self.observed_renew_time) |obs| {
                        const now = std.time.Instant.now() catch return .lost;
                        const elapsed_ns = now.since(obs);
                        const lease_duration_ns: u64 = std.math.cast(u64, @as(i64, lease_duration_s) * std.time.ns_per_s) orelse 0;
                        if (elapsed_ns < lease_duration_ns) {
                            // Not expired yet.
                            return .lost;
                        }
                    } else {
                        // First observation; record it and report lost.
                        self.observed_renew_time = std.time.Instant.now() catch null;
                        return .lost;
                    }
                };

                // Expired or no holder; take over.
                return self.updateLeaseTakeover(lease.spec, rv, now_str);
            },
            .api_error => |api_err| {
                defer api_err.deinit();
                if (api_err.status == .not_found) {
                    // 404: create a new lease.
                    return self.createLease(now_str);
                }
                return .err;
            },
        }
    }

    fn createLease(self: *LeaderElector, now_str: []const u8) LeaseResult {
        const Lease = types.CoordinationV1Lease;
        const LeaseApi = Api_mod.Api(Lease);

        const lease_body = Lease{
            .apiVersion = "coordination.k8s.io/v1",
            .kind = "Lease",
            .metadata = .{
                .name = self.config.lease_name,
                .namespace = self.config.lease_namespace,
            },
            .spec = .{
                .holderIdentity = self.config.identity,
                .leaseDurationSeconds = self.config.lease_duration_s,
                .acquireTime = now_str,
                .renewTime = now_str,
                .leaseTransitions = 0,
            },
        };

        const api = LeaseApi.init(self.client, self.ctx, self.config.lease_namespace);
        const create_result = api.create(lease_body, .{}) catch |err| {
            self.config.logger.err("failed to create lease", &.{
                LogField.string("error", @errorName(err)),
                LogField.string("lease_name", self.config.lease_name),
            });
            return .err;
        };

        switch (create_result) {
            .ok => |parsed| {
                defer parsed.deinit();
                const rv = if (parsed.value.metadata) |m| m.resourceVersion else null;
                if (rv) |new_rv| {
                    self.setObservedResourceVersion(new_rv);
                }
                self.observed_renew_time = std.time.Instant.now() catch null;
                return .acquired;
            },
            .api_error => |api_err| {
                api_err.deinit();
                return .err;
            },
        }
    }

    fn updateLease(
        self: *LeaderElector,
        rv: ?[]const u8,
        now_str: []const u8,
    ) LeaseResult {
        const Lease = types.CoordinationV1Lease;
        const LeaseApi = Api_mod.Api(Lease);

        const update_body = Lease{
            .apiVersion = "coordination.k8s.io/v1",
            .kind = "Lease",
            .metadata = .{
                .name = self.config.lease_name,
                .namespace = self.config.lease_namespace,
                .resourceVersion = rv,
            },
            .spec = .{
                .holderIdentity = self.config.identity,
                .leaseDurationSeconds = self.config.lease_duration_s,
                .renewTime = now_str,
            },
        };

        const api = LeaseApi.init(self.client, self.ctx, self.config.lease_namespace);
        const update_result = api.update(self.config.lease_name, update_body, .{}) catch |err| {
            self.config.logger.err("failed to update lease", &.{
                LogField.string("error", @errorName(err)),
                LogField.string("lease_name", self.config.lease_name),
            });
            return .err;
        };

        switch (update_result) {
            .ok => |parsed| {
                defer parsed.deinit();
                const new_rv = if (parsed.value.metadata) |m| m.resourceVersion else null;
                if (new_rv) |nrv| {
                    self.setObservedResourceVersion(nrv);
                }
                self.observed_renew_time = std.time.Instant.now() catch null;
                return .renewed;
            },
            .api_error => |api_err| {
                api_err.deinit();
                return .err;
            },
        }
    }

    fn updateLeaseTakeover(
        self: *LeaderElector,
        existing_spec: ?types.CoordinationV1LeaseSpec,
        rv: ?[]const u8,
        now_str: []const u8,
    ) LeaseResult {
        const Lease = types.CoordinationV1Lease;
        const LeaseApi = Api_mod.Api(Lease);

        const old_transitions: i32 = if (existing_spec) |s| (s.leaseTransitions orelse 0) else 0;

        const update_body = Lease{
            .apiVersion = "coordination.k8s.io/v1",
            .kind = "Lease",
            .metadata = .{
                .name = self.config.lease_name,
                .namespace = self.config.lease_namespace,
                .resourceVersion = rv,
            },
            .spec = .{
                .holderIdentity = self.config.identity,
                .leaseDurationSeconds = self.config.lease_duration_s,
                .acquireTime = now_str,
                .renewTime = now_str,
                .leaseTransitions = old_transitions + 1,
            },
        };

        const api = LeaseApi.init(self.client, self.ctx, self.config.lease_namespace);
        const update_result = api.update(self.config.lease_name, update_body, .{}) catch |err| {
            self.config.logger.err("failed to update lease for takeover", &.{
                LogField.string("error", @errorName(err)),
                LogField.string("lease_name", self.config.lease_name),
            });
            return .err;
        };

        switch (update_result) {
            .ok => |parsed| {
                defer parsed.deinit();
                const new_rv = if (parsed.value.metadata) |m| m.resourceVersion else null;
                if (new_rv) |nrv| {
                    self.setObservedResourceVersion(nrv);
                }
                self.observed_renew_time = std.time.Instant.now() catch null;
                return .acquired;
            },
            .api_error => |api_err| {
                api_err.deinit();
                return .err;
            },
        }
    }

    /// Best-effort lease release on graceful shutdown.
    /// Clears holderIdentity so another replica can acquire immediately.
    fn releaseLease(self: *LeaderElector) void {
        const Lease = types.CoordinationV1Lease;
        const LeaseApi = Api_mod.Api(Lease);

        const api = LeaseApi.init(self.client, self.ctx, self.config.lease_namespace);

        const get_result = api.get(self.config.lease_name) catch return;

        switch (get_result) {
            .ok => |parsed| {
                defer parsed.deinit();
                const lease = parsed.value;
                const holder = if (lease.spec) |s| s.holderIdentity else null;
                const is_us = if (holder) |h| std.mem.eql(u8, h, self.config.identity) else false;
                if (!is_us) return;

                const rv = if (lease.metadata) |m| m.resourceVersion else null;

                const release_body = Lease{
                    .apiVersion = "coordination.k8s.io/v1",
                    .kind = "Lease",
                    .metadata = .{
                        .name = self.config.lease_name,
                        .namespace = self.config.lease_namespace,
                        .resourceVersion = rv,
                    },
                    .spec = .{
                        .holderIdentity = "",
                        .leaseDurationSeconds = self.config.lease_duration_s,
                    },
                };

                const update_result = api.update(self.config.lease_name, release_body, .{}) catch return;
                switch (update_result) {
                    .ok => |p| p.deinit(),
                    .api_error => |e| e.deinit(),
                }
            },
            .api_error => |api_err| {
                api_err.deinit();
            },
        }
    }

    // Helpers
    fn setObservedResourceVersion(self: *LeaderElector, new_rv: []const u8) void {
        const new_copy = self.allocator.dupe(u8, new_rv) catch return;
        if (self.observed_resource_version) |old| {
            self.allocator.free(old);
        }
        self.observed_resource_version = new_copy;
    }

    /// Returns `true` when we haven't successfully renewed within `lease_duration_s`.
    fn renewalDeadlineExceeded(self: *LeaderElector) bool {
        const obs = self.observed_renew_time orelse return true;
        const now = std.time.Instant.now() catch return true;
        const elapsed_ns = now.since(obs);
        const deadline_ns: u64 = std.math.cast(u64, @as(i64, self.config.lease_duration_s) * std.time.ns_per_s) orelse return true;
        return elapsed_ns >= deadline_ns;
    }

    /// Perform an interruptible sleep using the stop condition variable.
    /// Returns `true` if the sleep completed without interruption,
    /// `false` if `stop()` was signalled.
    pub fn interruptibleSleep(self: *LeaderElector, ns: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.state.raw == .stopped) return false;
        self.stop_cond.timedWait(&self.mutex, ns) catch {};
        return self.state.raw != .stopped;
    }
};

fn dummyOnStarted(_: ?*anyopaque) void {}
fn dummyOnStopped(_: ?*anyopaque) void {}

test "config defaults" {
    // Arrange
    const config = LeaderElectionConfig{
        .lease_name = "test-lease",
        .lease_namespace = "default",
        .identity = "test-pod",
        .on_started_leading = dummyOnStarted,
        .on_stopped_leading = dummyOnStopped,
    };

    // Act / Assert
    try testing.expectEqual(15, config.lease_duration_s);
    try testing.expectEqual(10, config.renew_interval_s);
    try testing.expectEqual(2, config.retry_period_s);
    try testing.expect(config.callback_ctx == null);
}

test "renewalDeadlineExceeded: true when no observation" {
    // Arrange
    var client = try Client.init(testing.allocator, "http://127.0.0.1:8001", .{});
    defer client.deinit();

    // Act
    var elector = LeaderElector.init(testing.allocator, &client, client.context(), .{
        .lease_name = "test",
        .lease_namespace = "default",
        .identity = "pod-1",
        .on_started_leading = dummyOnStarted,
        .on_stopped_leading = dummyOnStopped,
    });
    defer elector.deinit();

    // Assert
    // No observation yet, so deadline is exceeded.
    try testing.expect(elector.renewalDeadlineExceeded());
}

test "renewalDeadlineExceeded: false within duration" {
    // Arrange
    var client = try Client.init(testing.allocator, "http://127.0.0.1:8001", .{});
    defer client.deinit();

    // Act
    var elector = LeaderElector.init(testing.allocator, &client, client.context(), .{
        .lease_name = "test",
        .lease_namespace = "default",
        .identity = "pod-1",
        .lease_duration_s = 15,
        .on_started_leading = dummyOnStarted,
        .on_stopped_leading = dummyOnStopped,
    });
    defer elector.deinit();

    // Assert
    elector.observed_renew_time = std.time.Instant.now() catch unreachable;

    try testing.expect(!elector.renewalDeadlineExceeded());
}

test "renewalDeadlineExceeded: true past duration" {
    // Arrange
    var client = try Client.init(testing.allocator, "http://127.0.0.1:8001", .{});
    defer client.deinit();

    // Act
    var elector = LeaderElector.init(testing.allocator, &client, client.context(), .{
        .lease_name = "test",
        .lease_namespace = "default",
        .identity = "pod-1",
        .lease_duration_s = 15,
        .on_started_leading = dummyOnStarted,
        .on_stopped_leading = dummyOnStopped,
    });
    defer elector.deinit();

    // Assert
    // Set observed time to now, then set duration to 0 so any elapsed
    // time exceeds the deadline.
    elector.observed_renew_time = std.time.Instant.now() catch unreachable;
    elector.config.lease_duration_s = 0;

    try testing.expect(elector.renewalDeadlineExceeded());
}

test "interruptibleSleep wakes on stop" {
    // Arrange
    var client = try Client.init(testing.allocator, "http://127.0.0.1:8001", .{});
    defer client.deinit();

    // Act
    var elector = LeaderElector.init(testing.allocator, &client, client.context(), .{
        .lease_name = "test",
        .lease_namespace = "default",
        .identity = "pod-1",
        .on_started_leading = dummyOnStarted,
        .on_stopped_leading = dummyOnStopped,
    });
    defer elector.deinit();

    // Assert
    // Set state to standby so interruptibleSleep doesn't return immediately.
    elector.state.raw = .standby;

    const sleeper = try std.Thread.spawn(.{}, struct {
        fn run(e: *LeaderElector) void {
            // Sleep for a very long time; should be woken early.
            const completed = e.interruptibleSleep(60 * std.time.ns_per_s);
            _ = completed;
        }
    }.run, .{&elector});

    // Give the thread time to enter the wait.
    std.Thread.sleep(10 * std.time.ns_per_ms);

    // Signal stop.
    {
        elector.mutex.lock();
        defer elector.mutex.unlock();
        elector.state.raw = .stopped;
        elector.stop_cond.signal();
    }

    sleeper.join();

    // If we get here, the thread was woken.
    try testing.expectEqual(LeaderElector.State.stopped, elector.state.load(.acquire));
}

test "stop without start is safe" {
    // Arrange
    var client = try Client.init(testing.allocator, "http://127.0.0.1:8001", .{});
    defer client.deinit();

    // Act
    var elector = LeaderElector.init(testing.allocator, &client, client.context(), .{
        .lease_name = "test",
        .lease_namespace = "default",
        .identity = "pod-1",
        .on_started_leading = dummyOnStarted,
        .on_stopped_leading = dummyOnStopped,
    });
    defer elector.deinit();

    // Assert
    // Should not crash.
    elector.stop();

    try testing.expectEqual(LeaderElector.State.idle, elector.state.load(.acquire));
}

test "isLeader state check" {
    // Arrange
    var client = try Client.init(testing.allocator, "http://127.0.0.1:8001", .{});
    defer client.deinit();

    // Act
    var elector = LeaderElector.init(testing.allocator, &client, client.context(), .{
        .lease_name = "test",
        .lease_namespace = "default",
        .identity = "pod-1",
        .on_started_leading = dummyOnStarted,
        .on_stopped_leading = dummyOnStopped,
    });
    defer elector.deinit();

    // Assert
    try testing.expect(!elector.isLeader());

    elector.state.raw = .standby;

    try testing.expect(!elector.isLeader());

    elector.state.raw = .leading;

    try testing.expect(elector.isLeader());

    elector.state.raw = .stopped;

    try testing.expect(!elector.isLeader());
}

test "healthCheck: reflects isLeader state" {
    // Arrange
    var client = try Client.init(testing.allocator, "http://127.0.0.1:8001", .{});
    defer client.deinit();

    var elector = LeaderElector.init(testing.allocator, &client, client.context(), .{
        .lease_name = "test",
        .lease_namespace = "default",
        .identity = "pod-1",
        .on_started_leading = dummyOnStarted,
        .on_stopped_leading = dummyOnStopped,
    });
    defer elector.deinit();
    const check = elector.healthCheck();

    // Act / Assert
    try testing.expect(!check.check_fn(check.ctx));

    elector.state.raw = .leading;
    try testing.expect(check.check_fn(check.ctx));
}

test "setObservedResourceVersion: OOM on dupe does not corrupt state" {
    // Arrange
    var fa = std.testing.FailingAllocator.init(testing.allocator, .{});
    var client = try Client.init(testing.allocator, "http://127.0.0.1:8001", .{});
    defer client.deinit();

    // Act
    var elector = LeaderElector.init(fa.allocator(), &client, client.context(), .{
        .lease_name = "test",
        .lease_namespace = "default",
        .identity = "pod-1",
        .on_started_leading = dummyOnStarted,
        .on_stopped_leading = dummyOnStopped,
    });
    defer elector.deinit();

    // Assert
    fa.fail_index = fa.alloc_index;
    elector.setObservedResourceVersion("12345");

    try testing.expect(elector.observed_resource_version == null);
}
