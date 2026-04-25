//! Unified lifecycle management for multiple heterogeneous controllers.
//!
//! `ControllerManager` owns a collection of type-erased `Runnable` controllers
//! and provides ordered startup, graceful shutdown (with optional timeout),
//! health checking, and rollback on partial start failures.

const std = @import("std");
const HealthCheck = @import("../util/health_check.zig").HealthCheck;
const logging = @import("../util/logging.zig");
const Logger = logging.Logger;
const LogField = logging.Field;
const controller_mod = @import("controller.zig");
const Client = @import("../client/Client.zig").Client;
const testing = std.testing;

/// A type-erased interface for running a controller.
///
/// `Runnable` wraps any `Controller(T)` behind a vtable so that
/// `ControllerManager` can store and manage heterogeneous controllers
/// in a single collection.
///
/// Created via `Runnable.fromController(T, ctrl_ptr)`.
pub const Runnable = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        start: *const fn (ptr: *anyopaque, io: std.Io) anyerror!void,
        cancel: *const fn (ptr: *anyopaque, io: std.Io) void,
        join: *const fn (ptr: *anyopaque) void,
        has_synced: *const fn (ptr: *anyopaque, io: std.Io) bool,
        get_error: *const fn (ptr: *anyopaque) ?anyerror,
    };

    /// Create a `Runnable` from a pointer to `Controller(T)`.
    ///
    /// The caller must ensure that the pointed-to controller outlives the
    /// `Runnable` (and any `ControllerManager` it is added to).
    pub fn fromController(comptime T: type, ctrl: *controller_mod.Controller(T)) Runnable {
        const Impl = struct {
            fn start(ptr: *anyopaque, io: std.Io) anyerror!void {
                const self: *controller_mod.Controller(T) = @ptrCast(@alignCast(ptr));
                return self.start(io);
            }
            fn cancel(ptr: *anyopaque, io: std.Io) void {
                const self: *controller_mod.Controller(T) = @ptrCast(@alignCast(ptr));
                self.cancel(io);
            }
            fn join(ptr: *anyopaque) void {
                const self: *controller_mod.Controller(T) = @ptrCast(@alignCast(ptr));
                self.join();
            }
            fn hasSynced(ptr: *anyopaque, io: std.Io) bool {
                const self: *controller_mod.Controller(T) = @ptrCast(@alignCast(ptr));
                return self.hasSynced(io);
            }
            fn getError(ptr: *anyopaque) ?anyerror {
                const self: *controller_mod.Controller(T) = @ptrCast(@alignCast(ptr));
                return self.getInformerError();
            }
        };

        return .{
            .ptr = @ptrCast(ctrl),
            .vtable = &.{
                .start = Impl.start,
                .cancel = Impl.cancel,
                .join = Impl.join,
                .has_synced = Impl.hasSynced,
                .get_error = Impl.getError,
            },
        };
    }

    /// Start the controller's informer and reconciler threads.
    pub fn start(self: Runnable, io: std.Io) anyerror!void {
        return self.vtable.start(self.ptr, io);
    }

    /// Signal the controller to stop (non-blocking).
    pub fn cancel(self: Runnable, io: std.Io) void {
        self.vtable.cancel(self.ptr, io);
    }

    /// Block until the controller's threads have exited.
    pub fn join(self: Runnable) void {
        self.vtable.join(self.ptr);
    }

    /// Cancel and then join: signal shutdown and wait for completion.
    pub fn stop(self: Runnable, io: std.Io) void {
        self.cancel(io);
        self.join();
    }

    /// Return whether the controller's informer has completed its initial list.
    pub fn hasSynced(self: Runnable, io: std.Io) bool {
        return self.vtable.has_synced(self.ptr, io);
    }

    /// Return the informer error, if any.
    pub fn getError(self: Runnable) ?anyerror {
        return self.vtable.get_error(self.ptr);
    }
};

/// Manages multiple type-erased controllers with unified lifecycle.
///
/// Controllers are added in idle state, then started together. On failure,
/// already-started controllers are rolled back. `stop()` tears down
/// controllers in reverse registration order. `run()` blocks until another
/// thread calls `stop()`.
pub const ControllerManager = struct {
    allocator: std.mem.Allocator,
    controllers: std.ArrayList(Runnable),
    state: State,
    mutex: std.Io.Mutex,
    /// Wakeup epoch for the stop condition.
    stop_cond_epoch: std.atomic.Value(u32),
    client: ?*Client = null,
    logger: Logger = Logger.noop,
    shutdown_timeout_ns: ?u64 = null,
    join_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    join_mutex: std.Io.Mutex = .init,
    /// Wakeup epoch for the join completion signal.
    join_cond_epoch: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    join_thread: ?std.Thread = null,

    const State = enum {
        idle,
        running,
        stopped,
    };

    pub const Options = struct {
        logger: Logger = Logger.noop,
        client: ?*Client = null,
        /// Timeout for graceful shutdown. When set, stop() returns after
        /// this duration even if some controllers have not finished joining.
        /// When null (default), stop() blocks until all controllers join.
        shutdown_timeout_ns: ?u64 = null,
    };

    /// Create a new controller manager in `idle` state.
    pub fn init(allocator: std.mem.Allocator, opts: Options) ControllerManager {
        return .{
            .allocator = allocator,
            .controllers = .empty,
            .state = .idle,
            .mutex = .init,
            .stop_cond_epoch = std.atomic.Value(u32).init(0),
            .client = opts.client,
            .logger = opts.logger.withScope("controller_manager"),
            .shutdown_timeout_ns = opts.shutdown_timeout_ns,
        };
    }

    /// Release resources. The manager must not be in `running` state.
    /// If a background join thread is still active, blocks until it finishes.
    pub fn deinit(self: *ControllerManager) void {
        std.debug.assert(self.state != .running);
        if (self.join_thread) |t| {
            if (!self.join_done.load(.acquire)) {
                self.logger.warn("deinit blocking on join thread, controllers still running", &.{});
            }
            t.join();
            self.join_thread = null;
        }
        self.controllers.deinit(self.allocator);
    }

    /// Register a controller. Only valid in `idle` state (before `start()`).
    pub fn add(self: *ControllerManager, runnable: Runnable) !void {
        std.debug.assert(self.state == .idle);
        try self.controllers.append(self.allocator, runnable);
    }

    /// Start all controllers in registration order.
    ///
    /// If controller N fails to start, controllers 0..N-1 are stopped in
    /// reverse order and the error from N is returned.
    pub fn start(self: *ControllerManager, io: std.Io) !void {
        std.debug.assert(self.state == .idle);

        self.logger.info("starting controller manager", &.{
            LogField.uint("controllers", self.controllers.items.len),
        });
        const items = self.controllers.items;
        for (items, 0..) |runnable, i| {
            self.logger.info("starting controller", &.{
                LogField.uint("index", i),
            });
            runnable.start(io) catch |err| {
                self.logger.err("controller failed to start, rolling back", &.{
                    LogField.uint("index", i),
                    LogField.string("error", @errorName(err)),
                });
                // Rollback: cancel 0..i-1 in forward order, then join.
                // Cancelling all first gives controllers maximum time
                // to react before we block on joins.
                for (items[0..i]) |r| r.cancel(io);

                if (self.shutdown_timeout_ns) |timeout_ns| {
                    self.timedJoinN(io, i, timeout_ns);
                } else {
                    self.joinN(i);
                }
                self.logger.info("rollback complete", &.{});
                return err;
            };
        }

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.state = .running;
    }

    /// Stop all controllers: cancel all, then join all.
    ///
    /// Safe to call from any thread. Signals `run()` to unblock.
    pub fn stop(self: *ControllerManager, io: std.Io) void {
        {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

            if (self.state != .running) return;
            self.logger.info("stopping controller manager", &.{});
            self.state = .stopped;
            _ = self.stop_cond_epoch.fetchAdd(1, .release);
            io.futexWake(u32, &self.stop_cond_epoch.raw, std.math.maxInt(u32));
        }

        // Set the client's shutdown flag.  This propagates to all
        // contexts derived from client.context(), unblocking any thread
        // in interruptibleSleep() or ctx.check().
        if (self.client) |c| c.shutdown(io);

        // Cancel ALL controllers (non-blocking).
        // Each cancel() sets informer cancel flags, interrupts watch
        // sockets, and shuts down work queues.
        const items = self.controllers.items;
        for (items) |runnable| {
            runnable.cancel(io);
        }

        // Join ALL controller threads (reverse order).
        // When a shutdown timeout is configured, the join phase is bounded:
        // if controllers do not exit within the deadline, stop() returns
        // and the remaining joins continue in a background thread.
        const n = self.controllers.items.len;
        if (self.shutdown_timeout_ns) |timeout_ns| {
            self.timedJoinN(io, n, timeout_ns);
        } else {
            self.joinN(n);
        }
    }

    /// Returns true when all controller threads have been joined.
    ///
    /// After a timed-out `stop()`, this returns false while background
    /// joins are still in progress. Callers can use this to decide
    /// whether `deinit()` will block.
    pub fn shutdownComplete(self: *ControllerManager) bool {
        return self.join_thread == null or self.join_done.load(.acquire);
    }

    /// Join the first `n` controllers in reverse order. Blocks until
    /// every targeted controller thread has exited.
    fn joinN(self: *ControllerManager, n: usize) void {
        const items = self.controllers.items;
        var i: usize = n;
        while (i > 0) {
            i -= 1;
            items[i].join();
        }
    }

    /// Spawn a helper thread to join the first `n` controllers, then
    /// wait for it with the given timeout. If the timeout expires, the
    /// helper thread is left running and will be joined by deinit().
    fn timedJoinN(self: *ControllerManager, io: std.Io, n: usize, timeout_ns: u64) void {
        self.join_done.store(false, .release);

        const join_thread = std.Thread.spawn(.{}, joinNThread, .{ self, io, n }) catch {
            self.logger.warn("failed to spawn join thread, falling back to blocking join", &.{});
            self.joinN(n);
            return;
        };

        const begin: std.Io.Clock.Timestamp = .now(io, .awake);
        while (!self.join_done.load(.acquire)) {
            const elapsed_ns_i: i96 = begin.untilNow(io).raw.nanoseconds;
            const elapsed: u64 = if (elapsed_ns_i < 0) 0 else @intCast(elapsed_ns_i);
            if (elapsed >= timeout_ns) break;
            const remaining: u64 = timeout_ns - elapsed;
            const observed = self.join_cond_epoch.load(.acquire);
            const timeout: std.Io.Timeout = .{ .duration = .{ .clock = .awake, .raw = .{ .nanoseconds = @intCast(remaining) } } };
            io.futexWaitTimeout(u32, &self.join_cond_epoch.raw, observed, timeout) catch break;
        }

        if (self.join_done.load(.acquire)) {
            join_thread.join();
        } else {
            self.logger.warn("shutdown timeout expired, some controllers may still be running", &.{
                LogField.uint("timeout_ns", timeout_ns),
            });
            self.join_thread = join_thread;
        }
    }

    fn joinNThread(self: *ControllerManager, io: std.Io, n: usize) void {
        self.joinN(n);
        self.join_mutex.lockUncancelable(io);
        defer self.join_mutex.unlock(io);
        self.join_done.store(true, .release);
        _ = self.join_cond_epoch.fetchAdd(1, .release);
        io.futexWake(u32, &self.join_cond_epoch.raw, std.math.maxInt(u32));
    }

    /// Start all controllers, then block until `stop()` is called.
    pub fn run(self: *ControllerManager, io: std.Io) !void {
        try self.start(io);

        self.logger.info("controller manager blocking, waiting for stop signal", &.{});
        while (true) {
            const observed = self.stop_cond_epoch.load(.acquire);
            self.mutex.lockUncancelable(io);
            const still_running = self.state == .running;
            self.mutex.unlock(io);
            if (!still_running) break;
            io.futexWaitUncancelable(u32, &self.stop_cond_epoch.raw, observed);
        }
        self.logger.info("controller manager unblocked, returning", &.{});
    }

    /// Returns `true` if every registered controller has synced.
    /// Vacuously true when no controllers are registered.
    pub fn allSynced(self: *ControllerManager, io: std.Io) bool {
        for (self.controllers.items) |runnable| {
            if (!runnable.hasSynced(io)) return false;
        }
        return true;
    }

    /// Return a health check that reports healthy when all controllers have synced.
    pub fn healthCheck(self: *ControllerManager) HealthCheck {
        return HealthCheck.fromTypedCtx(ControllerManager, self, struct {
            fn check(mgr: *ControllerManager, io: std.Io) bool {
                return mgr.allSynced(io);
            }
        }.check);
    }

    /// Return the error (if any) for the controller at `index`.
    pub fn getError(self: *ControllerManager, index: usize) ?anyerror {
        return self.controllers.items[index].getError();
    }

    /// Number of registered controllers.
    pub fn count(self: *ControllerManager) usize {
        return self.controllers.items.len;
    }
};

/// Mock state used by test runnables to track calls.
const MockState = struct {
    started: bool = false,
    stopped: bool = false,
    canceled: bool = false,
    joined: bool = false,
    synced: bool = false,
    err: ?anyerror = null,
    fail_start: bool = false,
    stop_order: ?usize = null,
    cancel_order: ?usize = null,
    join_order: ?usize = null,
    join_blocker: ?*std.atomic.Value(u32) = null,
    stop_counter: ?*std.atomic.Value(usize) = null,
    cancel_counter: ?*std.atomic.Value(usize) = null,
    join_counter: ?*std.atomic.Value(usize) = null,
};

fn makeMockRunnable(state: *MockState) Runnable {
    const Impl = struct {
        fn start(ptr: *anyopaque, _: std.Io) anyerror!void {
            const s: *MockState = @ptrCast(@alignCast(ptr));
            if (s.fail_start) return error.MockStartFailed;
            s.started = true;
        }
        fn cancel(ptr: *anyopaque, _: std.Io) void {
            const s: *MockState = @ptrCast(@alignCast(ptr));
            s.canceled = true;
            s.stopped = true; // backwards compat for existing tests
            if (s.cancel_counter) |counter| {
                s.cancel_order = counter.fetchAdd(1, .seq_cst);
            }
            if (s.stop_counter) |counter| {
                s.stop_order = counter.fetchAdd(1, .seq_cst);
            }
        }
        fn join(ptr: *anyopaque) void {
            const s: *MockState = @ptrCast(@alignCast(ptr));
            if (s.join_blocker) |blocker| {
                while (blocker.load(.acquire) == 0) {
                    std.Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .{ .nanoseconds = 1 * std.time.ns_per_ms } }, std.testing.io) catch {};
                }
            }
            s.joined = true;
            if (s.join_counter) |counter| {
                s.join_order = counter.fetchAdd(1, .seq_cst);
            }
        }
        fn hasSynced(ptr: *anyopaque, _: std.Io) bool {
            const s: *MockState = @ptrCast(@alignCast(ptr));
            return s.synced;
        }
        fn getError(ptr: *anyopaque) ?anyerror {
            const s: *MockState = @ptrCast(@alignCast(ptr));
            return s.err;
        }
    };

    return .{
        .ptr = @ptrCast(state),
        .vtable = &.{
            .start = Impl.start,
            .cancel = Impl.cancel,
            .join = Impl.join,
            .has_synced = Impl.hasSynced,
            .get_error = Impl.getError,
        },
    };
}

test "Runnable: VTable has expected fields" {
    // Act / Assert
    const vtable_info = @typeInfo(Runnable.VTable);
    try testing.expectEqual(5, vtable_info.@"struct".fields.len);
}

test "init/deinit: count is 0, allSynced is vacuously true" {
    // Arrange
    var mgr = ControllerManager.init(testing.allocator, .{});
    defer mgr.deinit();

    // Act / Assert
    try testing.expectEqual(0, mgr.count());
    try testing.expect(mgr.allSynced(std.testing.io));
}

test "add increments count" {
    // Arrange
    var mgr = ControllerManager.init(testing.allocator, .{});
    defer mgr.deinit();

    // Act
    var s1 = MockState{};
    var s2 = MockState{};

    // Assert
    try mgr.add(makeMockRunnable(&s1));
    try testing.expectEqual(1, mgr.count());
    try mgr.add(makeMockRunnable(&s2));
    try testing.expectEqual(2, mgr.count());
}

test "start calls all controllers" {
    // Arrange
    var mgr = ControllerManager.init(testing.allocator, .{});
    defer mgr.deinit();

    // Act
    var s1 = MockState{};
    var s2 = MockState{};
    try mgr.add(makeMockRunnable(&s1));
    try mgr.add(makeMockRunnable(&s2));

    // Assert
    try mgr.start(std.testing.io);
    defer mgr.stop(std.testing.io);

    try testing.expect(s1.started);
    try testing.expect(s2.started);
}

test "start rolls back on failure" {
    // Arrange
    var mgr = ControllerManager.init(testing.allocator, .{});
    defer mgr.deinit();

    // Act
    var s1 = MockState{};
    var s2 = MockState{ .fail_start = true };
    try mgr.add(makeMockRunnable(&s1));
    try mgr.add(makeMockRunnable(&s2));

    // Assert
    try testing.expectError(error.MockStartFailed, mgr.start(std.testing.io));

    // First controller was started then rolled back.
    try testing.expect(s1.started);
    try testing.expect(s1.stopped);
    // Second controller never started.
    try testing.expect(!s2.started);
}

test "stop in reverse order" {
    // Arrange
    var mgr = ControllerManager.init(testing.allocator, .{});
    defer mgr.deinit();

    // Act
    var counter = std.atomic.Value(usize).init(0);
    var s1 = MockState{ .stop_counter = &counter };
    var s2 = MockState{ .stop_counter = &counter };
    var s3 = MockState{ .stop_counter = &counter };
    try mgr.add(makeMockRunnable(&s1));
    try mgr.add(makeMockRunnable(&s2));
    try mgr.add(makeMockRunnable(&s3));

    // Assert
    try mgr.start(std.testing.io);
    mgr.stop(std.testing.io);

    // s3 stopped first (order 0), then s2 (order 1), then s1 (order 2).
    try testing.expectEqual(2, s1.stop_order.?);
    try testing.expectEqual(1, s2.stop_order.?);
    try testing.expectEqual(0, s3.stop_order.?);
}

test "allSynced: false until all report synced" {
    // Arrange
    var mgr = ControllerManager.init(testing.allocator, .{});
    defer mgr.deinit();

    // Act
    var s1 = MockState{ .synced = true };
    var s2 = MockState{ .synced = false };
    try mgr.add(makeMockRunnable(&s1));
    try mgr.add(makeMockRunnable(&s2));

    // Assert
    try testing.expect(!mgr.allSynced(std.testing.io));

    s2.synced = true;
    try testing.expect(mgr.allSynced(std.testing.io));
}

test "healthCheck: reflects allSynced state" {
    // Arrange
    var mgr = ControllerManager.init(testing.allocator, .{});
    defer mgr.deinit();

    var s1 = MockState{ .synced = false };
    try mgr.add(makeMockRunnable(&s1));
    const check = mgr.healthCheck();

    // Act / Assert
    try testing.expect(!check.check_fn(check.ctx, std.testing.io));

    s1.synced = true;
    try testing.expect(check.check_fn(check.ctx, std.testing.io));
}

test "getError returns per-controller errors" {
    // Arrange
    var mgr = ControllerManager.init(testing.allocator, .{});
    defer mgr.deinit();

    // Act
    var s1 = MockState{ .err = error.SomeError };
    var s2 = MockState{};
    try mgr.add(makeMockRunnable(&s1));
    try mgr.add(makeMockRunnable(&s2));

    // Assert
    try testing.expectEqual(error.SomeError, mgr.getError(0).?);
    try testing.expect(mgr.getError(1) == null);
}

test "stop without start is safe" {
    // Arrange
    var mgr = ControllerManager.init(testing.allocator, .{});
    defer mgr.deinit();

    // Act
    var s1 = MockState{};
    try mgr.add(makeMockRunnable(&s1));

    // Assert
    // Should not crash because state is idle, not running.
    mgr.stop(std.testing.io);

    try testing.expect(!s1.stopped);
}

test "run blocks until stop" {
    // Arrange
    var mgr = ControllerManager.init(testing.allocator, .{});
    defer mgr.deinit();

    // Act
    var s1 = MockState{};
    try mgr.add(makeMockRunnable(&s1));

    // Assert
    // Spawn a thread to call stop() after a short delay.
    const stopper = try std.Thread.spawn(.{}, struct {
        fn run(io: std.Io, m: *ControllerManager) void {
            std.Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .{ .nanoseconds = 10 * std.time.ns_per_ms } }, io) catch {};
            m.stop(io);
        }
    }.run, .{ std.testing.io, &mgr });

    try mgr.run(std.testing.io);
    stopper.join();

    try testing.expect(s1.started);
    try testing.expect(s1.stopped);
}

test "add: OOM on allocation does not corrupt manager" {
    // Arrange
    var fa = std.testing.FailingAllocator.init(testing.allocator, .{});
    var mgr = ControllerManager.init(fa.allocator(), .{});
    defer mgr.deinit();

    // Act
    var s1 = MockState{};

    // Assert
    fa.fail_index = fa.alloc_index;

    try testing.expectError(error.OutOfMemory, mgr.add(makeMockRunnable(&s1)));

    try testing.expectEqual(0, mgr.count());
}

test "stop cancels all before joining any" {
    // Arrange
    var mgr = ControllerManager.init(testing.allocator, .{});
    defer mgr.deinit();

    // Act
    var cancel_counter = std.atomic.Value(usize).init(0);
    var join_counter = std.atomic.Value(usize).init(0);

    // Assert
    var s1 = MockState{ .cancel_counter = &cancel_counter, .join_counter = &join_counter };
    var s2 = MockState{ .cancel_counter = &cancel_counter, .join_counter = &join_counter };
    var s3 = MockState{ .cancel_counter = &cancel_counter, .join_counter = &join_counter };
    try mgr.add(makeMockRunnable(&s1));
    try mgr.add(makeMockRunnable(&s2));
    try mgr.add(makeMockRunnable(&s3));

    try mgr.start(std.testing.io);
    mgr.stop(std.testing.io);

    try testing.expect(s1.canceled);
    try testing.expect(s2.canceled);
    try testing.expect(s3.canceled);
    try testing.expect(s1.joined);
    try testing.expect(s2.joined);
    try testing.expect(s3.joined);
    // Cancel order: s1=0, s2=1, s3=2 (forward order).
    try testing.expectEqual(0, s1.cancel_order.?);
    try testing.expectEqual(1, s2.cancel_order.?);
    try testing.expectEqual(2, s3.cancel_order.?);
    // Join order: s3=0, s2=1, s1=2 (reverse order).
    try testing.expectEqual(2, s1.join_order.?);
    try testing.expectEqual(1, s2.join_order.?);
    try testing.expectEqual(0, s3.join_order.?);
}

test "stop with shutdown_timeout: completes within timeout" {
    // Arrange
    var mgr = ControllerManager.init(testing.allocator, .{
        .shutdown_timeout_ns = 5 * std.time.ns_per_s,
    });
    defer mgr.deinit();

    var s1 = MockState{};
    var s2 = MockState{};
    try mgr.add(makeMockRunnable(&s1));
    try mgr.add(makeMockRunnable(&s2));

    // Act
    try mgr.start(std.testing.io);
    mgr.stop(std.testing.io);

    // Assert
    try testing.expect(s1.joined);
    try testing.expect(s2.joined);
}

test "stop with shutdown_timeout: timeout expires with stuck controller" {
    // Arrange
    var blocker = std.atomic.Value(u32).init(0);
    var mgr = ControllerManager.init(testing.allocator, .{
        .shutdown_timeout_ns = 50 * std.time.ns_per_ms,
    });
    defer mgr.deinit();

    var s1 = MockState{};
    var s2 = MockState{ .join_blocker = &blocker };
    try mgr.add(makeMockRunnable(&s1));
    try mgr.add(makeMockRunnable(&s2));

    // Act
    try mgr.start(std.testing.io);
    const start_time: std.Io.Clock.Timestamp = .now(std.testing.io, .awake);
    mgr.stop(std.testing.io);
    const elapsed_i: i96 = start_time.untilNow(std.testing.io).raw.nanoseconds;
    const elapsed: u64 = if (elapsed_i < 0) 0 else @intCast(elapsed_i);

    // Assert
    try testing.expect(elapsed < 1 * std.time.ns_per_s);
    try testing.expect(!s1.joined);
    try testing.expect(!s2.joined);

    // Unblock so the background join thread can finish during deinit.
    blocker.store(1, .release);
}

test "shutdownComplete: true after clean stop" {
    // Arrange
    var mgr = ControllerManager.init(testing.allocator, .{});
    defer mgr.deinit();

    var s1 = MockState{};
    try mgr.add(makeMockRunnable(&s1));

    // Act
    try mgr.start(std.testing.io);
    mgr.stop(std.testing.io);

    // Assert
    try testing.expect(mgr.shutdownComplete());
}

test "shutdownComplete: false during timed-out stop" {
    // Arrange
    var blocker = std.atomic.Value(u32).init(0);
    var mgr = ControllerManager.init(testing.allocator, .{
        .shutdown_timeout_ns = 50 * std.time.ns_per_ms,
    });
    defer mgr.deinit();

    var s1 = MockState{ .join_blocker = &blocker };
    try mgr.add(makeMockRunnable(&s1));

    // Act
    try mgr.start(std.testing.io);
    mgr.stop(std.testing.io);

    // Assert
    try testing.expect(!mgr.shutdownComplete());

    // Unblock so the background join thread can finish during deinit.
    blocker.store(1, .release);
}

test "start rollback with shutdown_timeout" {
    // Arrange
    var blocker = std.atomic.Value(u32).init(0);
    var mgr = ControllerManager.init(testing.allocator, .{
        .shutdown_timeout_ns = 50 * std.time.ns_per_ms,
    });
    defer mgr.deinit();

    var s1 = MockState{ .join_blocker = &blocker };
    var s2 = MockState{ .fail_start = true };
    try mgr.add(makeMockRunnable(&s1));
    try mgr.add(makeMockRunnable(&s2));

    // Act / Assert
    try testing.expectError(error.MockStartFailed, mgr.start(std.testing.io));
    try testing.expect(s1.canceled);

    // Unblock so the background join thread can finish during deinit.
    blocker.store(1, .release);
}

test "start rollback cancels all before joining" {
    // Arrange
    var mgr = ControllerManager.init(testing.allocator, .{});
    defer mgr.deinit();

    var cancel_counter = std.atomic.Value(usize).init(0);
    var join_counter = std.atomic.Value(usize).init(0);

    var s1 = MockState{ .cancel_counter = &cancel_counter, .join_counter = &join_counter };
    var s2 = MockState{ .cancel_counter = &cancel_counter, .join_counter = &join_counter };
    var s3 = MockState{ .fail_start = true };
    try mgr.add(makeMockRunnable(&s1));
    try mgr.add(makeMockRunnable(&s2));
    try mgr.add(makeMockRunnable(&s3));

    // Act
    try testing.expectError(error.MockStartFailed, mgr.start(std.testing.io));

    // Assert
    // All cancels (orders 0,1) happened before any joins (orders 0,1)
    // because cancel and join use separate counters starting at 0.
    try testing.expectEqual(0, s1.cancel_order.?);
    try testing.expectEqual(1, s2.cancel_order.?);
    try testing.expectEqual(1, s1.join_order.?);
    try testing.expectEqual(0, s2.join_order.?);
}
