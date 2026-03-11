//! List-watch reflector that syncs Kubernetes API server state to a local store.
//!
//! Drives the initial paginated list and ongoing watch stream as a state
//! machine, producing `ReflectorEvent` values for the owning `Informer`
//! to process. Handles 410 Gone re-listing, exponential backoff on
//! transient errors, and cross-thread watch interruption for shutdown.

const std = @import("std");
const client_mod = @import("../client/Client.zig");
const Client = client_mod.Client;
const Context = client_mod.Context;
const StreamState = client_mod.StreamState;
const watch_mod = @import("../api/watch.zig");
const store_mod = @import("store.zig");
const ObjectKey = store_mod.ObjectKey;
const Api_mod = @import("../api/Api.zig");
const options_mod = @import("../api/options.zig");
const retry_mod = @import("../util/retry.zig");
const RetryPolicy = retry_mod.RetryPolicy;
const context_mod = @import("../util/context.zig");
const deepClone = @import("../util/deep_clone.zig").deepClone;
const InformerMetrics = @import("../util/metrics.zig").InformerMetrics;
const logging_mod = @import("../util/logging.zig");
const Logger = logging_mod.Logger;
const LogField = logging_mod.Field;

/// Events produced by the Reflector for the Informer to process.
pub fn ReflectorEvent(comptime T: type) type {
    return union(enum) {
        /// A batch of objects from the initial list.
        /// Ownership of arenas transfers to the receiver.
        init_page: InitPage,

        /// A single watch event (add/modify/delete).
        /// Ownership of the ParsedEvent's arena transfers to the receiver.
        watch_event: watch_mod.ParsedEvent(T),

        /// The watch stream ended cleanly (server timeout). Reflector will reconnect.
        watch_ended: void,

        /// A 410 Gone error occurred. The store should prepare for a full re-list.
        gone: void,

        /// A transient error occurred. The reflector will backoff and retry.
        transient_error: anyerror,

        /// Consecutive errors have exceeded the configured threshold.
        /// The reflector has entered the `.failed` state and will not retry.
        persistent_error: anyerror,

        pub const InitPage = struct {
            items: []store_mod.Store(T).ReplaceItem,
            is_last: bool,
            resource_version: []const u8,
            /// Allocator-owned memory for items array and RV string.
            /// Caller must free items array after consuming and free rv_buf.
            rv_buf: ?[]const u8,

            /// Free metadata memory. Caller must handle item arenas separately.
            pub fn deinitMeta(self: *InitPage, allocator: std.mem.Allocator) void {
                allocator.free(self.items);
                if (self.rv_buf) |buf| allocator.free(buf);
            }
        };
    };
}

/// Reflector state machine states for the list/watch lifecycle.
///
/// Valid transitions under normal operation:
///   initial --[stepInitial]--> listing
///   listing --[last page]--> watching
///   listing --[410 Gone]--> gone
///   listing --[persistent error]--> failed
///   watching --[stream end]--> watch_ended
///   watching --[410 Gone]--> gone
///   watching --[persistent error]--> failed
///   watch_ended --[reconnect]--> watching
///   gone --[re-list]--> initial
///   forceRelist(): any (except failed) --> initial
pub const ReflectorState = enum {
    initial,
    listing,
    watching,
    watch_ended,
    gone,
    failed,

    /// Returns whether a transition from one state to another is valid
    /// under normal operation. This excludes forceRelist(), which can
    /// transition from any non-failed state as an external trigger.
    pub fn isValidTransition(from: ReflectorState, to: ReflectorState) bool {
        return switch (from) {
            .initial => to == .listing,
            .listing => to == .watching or to == .gone or to == .failed,
            .watching => to == .watch_ended or to == .gone or to == .failed,
            .watch_ended => to == .watching,
            .gone => to == .initial,
            .failed => false,
        };
    }
};

/// Options for configuring the reflector.
pub const ReflectorOptions = struct {
    /// Label selector for filtering resources.
    label_selector: ?[]const u8 = null,
    /// Field selector for filtering resources.
    field_selector: ?[]const u8 = null,
    /// Page size for initial list pagination (default: 500).
    page_size: i64 = 500,
    /// Watch timeout in seconds (server-side). Actual timeout is randomized
    /// between this value and 2x this value.
    watch_timeout_seconds: i64 = 290,
    /// Maximum consecutive errors before transitioning to `.failed` state and
    /// emitting a `.persistent_error` event. `null` means unlimited retries
    /// (default).
    max_consecutive_errors: ?u32 = null,
    /// Metrics for observability. Shared with the owning Informer.
    metrics: InformerMetrics = InformerMetrics.noop,
    /// Structured logger for observability.
    logger: Logger = Logger.noop,
};

/// List+watch lifecycle manager. Drives the initial list and ongoing watch,
/// producing events for the Informer to process via `step()`.
pub fn Reflector(comptime T: type) type {
    const meta = T.resource_meta;
    const ListT = meta.list_kind;
    const ApiT = Api_mod.Api(T);

    return struct {
        const Self = @This();

        pub const State = ReflectorState;

        allocator: std.mem.Allocator,
        client: *Client,
        ctx: Context,
        namespace: if (meta.namespaced) []const u8 else ?[]const u8,
        state: State,
        resource_version: ?[]const u8,
        continue_token: ?[]const u8,
        watch_stream: ?watch_mod.WatchStream(T),
        options: ReflectorOptions,
        metrics: InformerMetrics,
        logger: Logger,
        retry_policy: RetryPolicy,
        backoff_attempt: u32,
        consecutive_errors: u32,
        /// Mutex protecting `active_stream_state` for cross-thread interrupt.
        watch_mu: std.Thread.Mutex = .{},
        /// Points to the current watch stream's `StreamState` while active.
        /// Guarded by `watch_mu`.
        active_stream_state: ?*StreamState = null,

        /// Create a new reflector for the given resource type and namespace.
        pub fn init(
            allocator: std.mem.Allocator,
            client: *Client,
            ctx: Context,
            namespace: if (meta.namespaced) []const u8 else ?[]const u8,
            opts: ReflectorOptions,
        ) Self {
            return .{
                .allocator = allocator,
                .client = client,
                .ctx = ctx,
                .namespace = namespace,
                .state = .initial,
                .resource_version = null,
                .continue_token = null,
                .watch_stream = null,
                .options = opts,
                .metrics = opts.metrics,
                .logger = opts.logger.withScope("reflector"),
                .retry_policy = .{
                    .max_retries = std.math.maxInt(u32),
                    .initial_backoff_ns = 500 * std.time.ns_per_ms,
                    .max_backoff_ns = 30 * std.time.ns_per_s,
                    .backoff_multiplier = 2,
                    .jitter = true,
                },
                .backoff_attempt = 0,
                .consecutive_errors = 0,
            };
        }

        /// Release all resources owned by the reflector.
        pub fn deinit(self: *Self) void {
            self.closeWatch();
            if (self.resource_version) |rv| self.allocator.free(rv);
            if (self.continue_token) |ct| self.allocator.free(ct);
        }

        /// Shut down the active watch socket, causing any blocked `read()`
        /// to return immediately.  Safe to call from another thread.
        pub fn interruptWatch(self: *Self) void {
            self.watch_mu.lock();
            defer self.watch_mu.unlock();
            if (self.active_stream_state) |state| {
                state.interrupt();
            }
        }

        /// Run one step of the reflector state machine.
        /// Returns an event for the informer, or null for internal-only steps.
        pub fn step(self: *Self) !?ReflectorEvent(T) {
            self.ctx.check() catch return error.Canceled;

            return switch (self.state) {
                .initial => self.stepInitial(),
                .listing => self.stepListing(),
                .watching => self.stepWatching(),
                .watch_ended => self.stepWatchEnded(),
                .gone => self.stepGone(),
                .failed => return error.ReflectorFailed,
            };
        }

        fn transitionTo(self: *Self, new_state: State) void {
            std.debug.assert(State.isValidTransition(self.state, new_state));
            self.state = new_state;
        }

        // State handlers
        fn stepInitial(self: *Self) !?ReflectorEvent(T) {
            if (self.continue_token) |ct| {
                self.allocator.free(ct);
                self.continue_token = null;
            }
            // First list: rv="0" (serve from watch cache).
            // After 410: rv="" (quorum read).
            if (self.resource_version == null) {
                self.resource_version = try self.allocator.dupe(u8, "0");
            }
            self.logger.info("initial list starting", &.{
                LogField.string("resource", meta.resource),
            });
            self.transitionTo(.listing);
            return self.stepListing();
        }

        fn stepListing(self: *Self) !?ReflectorEvent(T) {
            const list_start = std.time.Instant.now() catch null;
            const api = ApiT.init(self.client, self.ctx, self.namespace);

            const rv = self.resource_version;

            // Disable pagination when using a specific RV (not "0" or "")
            // to avoid extra etcd load.
            const use_pagination = rv == null or
                (rv != null and (rv.?.len == 0 or std.mem.eql(u8, rv.?, "0")));

            const list_opts: options_mod.ListOptions = .{
                .label_selector = self.options.label_selector,
                .field_selector = self.options.field_selector,
                .resource_version = rv,
                .limit = if (use_pagination) self.options.page_size else null,
                .continue_token = self.continue_token,
            };

            const result = api.list(list_opts) catch |err| {
                return self.recordError(err);
            };

            // Record list duration.
            if (list_start) |s| {
                if (std.time.Instant.now() catch null) |end| {
                    const dur_ns: f64 = @floatFromInt(end.since(s));
                    self.metrics.list_duration.observe(dur_ns / @as(f64, std.time.ns_per_s));
                }
            }

            switch (result) {
                .ok => |parsed_list| {
                    defer parsed_list.deinit();
                    self.resetErrors();

                    // Extract metadata.
                    const list_meta = self.extractListMeta(parsed_list.value);
                    const new_rv = list_meta.resource_version;
                    const new_continue = list_meta.continue_token;

                    // Clone items into individual arenas.
                    const items_slice = self.extractListItems(parsed_list.value);
                    const replace_items = self.cloneItemsToArenas(items_slice) catch |err| {
                        return .{ .transient_error = err };
                    };

                    const is_last = new_continue == null;

                    // Save resource version from the last page.
                    if (new_rv) |rv_str| {
                        const owned_rv = self.allocator.dupe(u8, rv_str) catch |err| {
                            // Free cloned items on failure. This is safe and cannot
                            // double-free: the transient_error event variant carries
                            // only the error value (anyerror), not the items, so the
                            // informer never receives or frees replace_items.
                            self.freeReplaceItems(replace_items);
                            return .{ .transient_error = err };
                        };
                        if (self.resource_version) |old_rv| self.allocator.free(old_rv);
                        self.resource_version = owned_rv;
                    }

                    // Save continue token.
                    if (new_continue) |ct| {
                        const owned_ct = self.allocator.dupe(u8, ct) catch |err| {
                            // Same safety reasoning as the rv dupe above:
                            // transient_error carries only anyerror, not items.
                            self.freeReplaceItems(replace_items);
                            return .{ .transient_error = err };
                        };
                        if (self.continue_token) |old_ct| self.allocator.free(old_ct);
                        self.continue_token = owned_ct;
                    } else {
                        if (self.continue_token) |old_ct| self.allocator.free(old_ct);
                        self.continue_token = null;
                    }

                    if (is_last) {
                        self.logger.info("initial list completed", &.{
                            LogField.string("resource", meta.resource),
                            LogField.uint("item_count", @intCast(replace_items.len)),
                            LogField.string("resource_version", self.resource_version orelse ""),
                        });
                        self.transitionTo(.watching);
                    }

                    return .{
                        .init_page = .{
                            .items = replace_items,
                            .is_last = is_last,
                            .resource_version = self.resource_version orelse "",
                            .rv_buf = null, // RV is owned by self
                        },
                    };
                },
                .api_error => |err| {
                    defer err.deinit();
                    if (err.status == .gone) {
                        self.transitionTo(.gone);
                        return .gone;
                    }
                    if (err.status == .unauthorized or err.status == .forbidden) {
                        self.logger.err("list auth error", &.{
                            LogField.string("resource", meta.resource),
                            LogField.uint("status_code", @intFromEnum(err.status)),
                        });
                    }
                    return self.recordError(err.statusError());
                },
            }
        }

        fn stepWatching(self: *Self) !?ReflectorEvent(T) {
            // Open watch stream if needed.
            if (self.watch_stream == null) {
                self.logger.info("watch reconnecting", &.{
                    LogField.string("resource", meta.resource),
                    LogField.string("resource_version", self.resource_version orelse ""),
                });
                const timeout = self.randomizedWatchTimeout();
                const api = ApiT.init(self.client, self.ctx, self.namespace);
                self.watch_stream = api.watch(.{
                    .label_selector = self.options.label_selector,
                    .field_selector = self.options.field_selector,
                    .resource_version = self.resource_version,
                    .timeout_seconds = timeout,
                    .allow_bookmarks = true,
                }) catch |err| {
                    self.watch_stream = null;
                    // Check for 410 Gone from the HTTP response.
                    if (err == error.HttpGone) {
                        self.transitionTo(.gone);
                        return .gone;
                    }
                    if (err == error.HttpUnauthorized or err == error.HttpForbidden) {
                        self.logger.err("watch auth error", &.{
                            LogField.string("resource", meta.resource),
                            LogField.string("error", @errorName(err)),
                        });
                    }
                    return self.recordError(err);
                };
                // Register the active stream state for cross-thread interrupt.
                self.watch_mu.lock();
                self.active_stream_state = self.watch_stream.?.state;
                self.watch_mu.unlock();
                self.resetErrors();
            }

            // Read next event from the watch stream.
            const parsed_event = self.watch_stream.?.next() catch |err| {
                self.closeWatch();
                return self.recordError(err);
            };

            if (parsed_event) |event| {
                switch (event.event) {
                    .bookmark => |bm| {
                        // Update RV silently, don't forward to informer.
                        const owned_rv = self.allocator.dupe(u8, bm.resource_version) catch {
                            event.deinit();
                            return .{ .transient_error = error.OutOfMemory };
                        };
                        if (self.resource_version) |rv| self.allocator.free(rv);
                        self.resource_version = owned_rv;
                        event.deinit();
                        return null; // internal-only step
                    },
                    .api_error => |api_err| {
                        if (api_err.code) |c| if (c == 410) {
                            event.deinit();
                            self.closeWatch();
                            self.transitionTo(.gone);
                            return .gone;
                        };
                        const code = api_err.code;
                        if (code) |c| if (c == 401 or c == 403) {
                            self.logger.err("watch stream auth error", &.{
                                LogField.string("resource", meta.resource),
                                LogField.uint("status_code", @intCast(c)),
                            });
                        };
                        const watch_err: anyerror = if (code) |c| switch (c) {
                            401 => error.HttpUnauthorized,
                            403 => error.HttpForbidden,
                            else => error.HttpRequestFailed,
                        } else error.HttpRequestFailed;
                        event.deinit();
                        self.closeWatch();
                        return self.recordError(watch_err);
                    },
                    .added, .modified, .deleted => {
                        self.resetErrors();
                        // Update RV from the event object.
                        const ev_rv = self.extractEventRV(event.event);
                        if (ev_rv) |rv_str| {
                            const owned_rv = self.allocator.dupe(u8, rv_str) catch {
                                // Can't track RV but still forward the event.
                                return .{ .watch_event = event };
                            };
                            if (self.resource_version) |rv| self.allocator.free(rv);
                            self.resource_version = owned_rv;
                        }
                        return .{ .watch_event = event };
                    },
                }
            } else {
                // Clean end of stream (server timeout or connection close).
                self.logger.warn("watch stream ended (server timeout), will reconnect", &.{
                    LogField.string("resource", meta.resource),
                });
                self.closeWatch();
                self.transitionTo(.watch_ended);
                return .watch_ended;
            }
        }

        fn stepWatchEnded(self: *Self) !?ReflectorEvent(T) {
            // Reconnect from last known resource version.
            self.transitionTo(.watching);
            return null;
        }

        fn stepGone(self: *Self) !?ReflectorEvent(T) {
            // Reset for a fresh list with quorum read.
            self.logger.warn("re-listing after 410 Gone", &.{
                LogField.string("resource", meta.resource),
                LogField.string("old_resource_version", self.resource_version orelse ""),
            });
            if (self.resource_version) |rv| self.allocator.free(rv);
            self.resource_version = try self.allocator.dupe(u8, "");
            self.transitionTo(.initial);
            return null;
        }

        /// Force a re-list by resetting to initial state with a quorum read.
        /// Called by the informer when a watch event cannot be applied
        /// (e.g. OOM on store.put), to ensure the cache is eventually consistent.
        pub fn forceRelist(self: *Self) std.mem.Allocator.Error!void {
            self.logger.warn("forcing re-list", &.{
                LogField.string("resource", meta.resource),
            });
            self.closeWatch();
            const new_rv = try self.allocator.dupe(u8, "");
            if (self.resource_version) |rv| self.allocator.free(rv);
            self.resource_version = new_rv;
            std.debug.assert(self.state != .failed);
            self.state = .initial;
        }

        // Helpers
        fn closeWatch(self: *Self) void {
            // Clear the active stream state under lock *before* closing,
            // so interruptWatch() cannot operate on a deinit'd stream.
            self.watch_mu.lock();
            self.active_stream_state = null;
            self.watch_mu.unlock();
            if (self.watch_stream) |*ws| {
                ws.close(); // infallible (returns void)
                self.watch_stream = null;
            }
        }

        /// Free a slice of ReplaceItems, deinitializing each arena.
        fn freeReplaceItems(self: *Self, items: []store_mod.Store(T).ReplaceItem) void {
            for (items) |item| {
                item.arena.deinit();
                self.allocator.destroy(item.arena);
            }
            self.allocator.free(items);
        }

        fn randomizedWatchTimeout(self: *Self) i64 {
            const base = self.options.watch_timeout_seconds;
            if (base <= 0) return 300;
            // Clamp so that base + jitter (up to 2*base) cannot overflow i64.
            const clamped: u64 = std.math.cast(u64, @min(base, std.math.maxInt(i64) / 2)) orelse return 300;
            // Randomize between base and 2*base to avoid thundering herd.
            const jitter = std.crypto.random.uintAtMost(u64, clamped);
            return std.math.cast(i64, clamped + jitter) orelse 300;
        }

        fn extractListMeta(_: *Self, list: ListT) struct {
            resource_version: ?[]const u8,
            continue_token: ?[]const u8,
        } {
            if (@hasField(ListT, "metadata")) {
                if (list.metadata) |m| {
                    const rv = if (@hasField(@TypeOf(m), "resourceVersion")) m.resourceVersion else null;
                    // Kubernetes returns continue:"" (empty string) when there are
                    // no more pages.  Normalize to null so callers can simply check
                    // for null to detect the last page.
                    const ct: ?[]const u8 = blk: {
                        if (!@hasField(@TypeOf(m), "continue")) break :blk null;
                        const c = m.@"continue" orelse break :blk null;
                        break :blk if (c.len > 0) c else null;
                    };
                    return .{ .resource_version = rv, .continue_token = ct };
                }
            }
            return .{ .resource_version = null, .continue_token = null };
        }

        fn extractListItems(_: *Self, list: ListT) []const T {
            if (!@hasField(ListT, "items")) return &.{};
            const items_field = list.items;
            const ItemsType = @TypeOf(items_field);
            // Handle both optional and non-optional items fields.
            if (@typeInfo(ItemsType) == .optional) {
                return items_field orelse &.{};
            } else {
                return items_field;
            }
        }

        fn extractEventRV(_: *Self, event: watch_mod.WatchEvent(T)) ?[]const u8 {
            const obj = switch (event) {
                .added => |o| o,
                .modified => |o| o,
                .deleted => |o| o,
                .bookmark, .api_error => return null,
            };
            if (@hasField(T, "metadata")) {
                if (obj.metadata) |m| {
                    if (@hasField(@TypeOf(m), "resourceVersion")) {
                        return m.resourceVersion;
                    }
                }
            }
            return null;
        }

        /// Clone list items into individual arenas via deep copy.
        fn cloneItemsToArenas(self: *Self, items: []const T) ![]store_mod.Store(T).ReplaceItem {
            var result_list: std.ArrayList(store_mod.Store(T).ReplaceItem) = .empty;
            errdefer {
                for (result_list.items) |item| {
                    item.arena.deinit();
                    self.allocator.destroy(item.arena);
                }
                result_list.deinit(self.allocator);
            }

            for (items) |item| {
                const arena = try self.allocator.create(std.heap.ArenaAllocator);
                arena.* = std.heap.ArenaAllocator.init(self.allocator);
                errdefer {
                    arena.deinit();
                    self.allocator.destroy(arena);
                }

                const cloned = deepClone(T, arena.allocator(), item) catch return error.OutOfMemory;

                const key = ObjectKey.fromResource(T, cloned) orelse {
                    arena.deinit();
                    self.allocator.destroy(arena);
                    continue;
                };

                try result_list.append(self.allocator, .{
                    .key = key,
                    .object = cloned,
                    .arena = arena,
                });
            }

            return result_list.toOwnedSlice(self.allocator);
        }

        /// Record a transient error and return the appropriate event.
        /// If `max_consecutive_errors` is configured and the threshold is
        /// exceeded, transitions to `.failed` and returns `.persistent_error`.
        fn recordError(self: *Self, err: anyerror) ReflectorEvent(T) {
            self.consecutive_errors += 1;
            self.backoff_attempt += 1;
            if (self.options.max_consecutive_errors) |max| {
                if (self.consecutive_errors >= max) {
                    self.logger.err("list/watch failed", &.{
                        LogField.string("resource", meta.resource),
                        LogField.string("error", @errorName(err)),
                    });
                    self.transitionTo(.failed);
                    return .{ .persistent_error = err };
                }
            }
            return .{ .transient_error = err };
        }

        /// Reset the consecutive error counter on any successful operation.
        fn resetErrors(self: *Self) void {
            self.consecutive_errors = 0;
            self.backoff_attempt = 0;
        }

        /// Sleep for the current backoff duration. Returns `error.Canceled`
        /// if the context is already canceled (without logging) or if
        /// cancellation is detected during sleep.
        pub fn backoffSleep(self: *Self, ctx: Context) error{Canceled}!void {
            try ctx.check();
            const ns = self.retry_policy.sleepNs(self.backoff_attempt, null);
            self.logger.debug("backoff sleep", &.{
                LogField.string("resource", meta.resource),
                LogField.uint("duration_ms", ns / std.time.ns_per_ms),
            });
            try context_mod.interruptibleSleep(ctx, ns);
        }
    };
}
