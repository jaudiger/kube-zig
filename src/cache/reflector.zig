//! List-watch reflector that syncs Kubernetes API server state to a local store.
//!
//! Drives the initial paginated list and ongoing watch stream as a state
//! machine, producing `ReflectorEvent` values for the owning `Informer`
//! to process. Handles 410 Gone re-listing and exponential backoff on
//! transient errors.

const std = @import("std");
const client_mod = @import("../client/Client.zig");
const Client = client_mod.Client;
const Context = client_mod.Context;
const watch_mod = @import("../api/watch.zig");
const store_mod = @import("store.zig");
const ObjectKey = @import("../object_key.zig").ObjectKey;
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
const ResourceVersion = @import("../util/resource_version.zig").ResourceVersion;

/// Typed error set for reflector errors.
pub const ReflectorError = error{
    Unauthorized,
    Forbidden,
    HttpFailed,
    NetworkFailed,
    StreamCorrupt,
    ParseFailed,
    LineTooLong,
    OutOfMemory,
    Canceled,
    Other,
};

fn classifyError(err: anyerror) ReflectorError {
    return switch (err) {
        error.HttpUnauthorized => error.Unauthorized,
        error.HttpForbidden => error.Forbidden,
        error.HttpGone,
        error.HttpNotFound,
        error.HttpServerError,
        error.HttpRequestFailed,
        error.HttpConflict,
        error.HttpUnprocessable,
        error.HttpServiceUnavailable,
        => error.HttpFailed,
        error.ConnectionResetByPeer,
        error.ConnectionTimedOut,
        error.TlsFailure,
        error.DnsResolveFailed,
        error.IoFailed,
        => error.NetworkFailed,
        error.JsonParseFailed, error.UnknownEventType => error.ParseFailed,
        error.ResourceVersionTooLong => error.StreamCorrupt,
        error.LineTooLong => error.LineTooLong,
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        else => error.Other,
    };
}

/// Events produced by the Reflector for the Informer to process.
pub fn ReflectorEvent(comptime T: type) type {
    return union(enum) {
        /// A batch of objects from the initial list.
        /// Ownership of arenas transfers to the receiver.
        init_page: InitPage,

        /// The watch stream ended cleanly (server timeout). Reflector will reconnect.
        watch_ended: void,

        /// A 410 Gone error occurred. The store should prepare for a full re-list.
        gone: void,

        /// A transient error occurred. The reflector will backoff and retry.
        transient_error: ReflectorError,

        /// Consecutive errors have exceeded the configured threshold.
        /// The reflector has entered the `.failed` state and will not retry.
        persistent_error: ReflectorError,

        pub const InitPage = struct {
            items: []store_mod.Store(T).ReplaceItem,
            is_last: bool,
            resource_version: ResourceVersion,

            /// Free the items slice. Each item's arena must be freed first via
            /// `item.deinit()` or transferred to the store via `replace()`.
            pub fn deinitMeta(self: *InitPage, allocator: std.mem.Allocator) void {
                allocator.free(self.items);
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

/// List+watch lifecycle manager. Drives the initial list via `step()` and
/// delivers the ongoing watch through `runWatch()`.
pub fn Reflector(comptime T: type) type {
    const meta = T.resource_meta;
    const ListT = meta.list_kind;
    comptime {
        if (ListT == void) @compileError("Reflector requires list+watch; '" ++ @typeName(T) ++ "' is a POST-only resource with no list_kind");
    }
    const ApiT = Api_mod.Api(T);

    return struct {
        const Self = @This();

        pub const State = ReflectorState;

        allocator: std.mem.Allocator,
        client: *Client,
        ctx: Context,
        namespace: if (meta.namespaced) []const u8 else ?[]const u8,
        state: State,
        resource_version: ResourceVersion,
        continue_token: ?[]const u8,
        options: ReflectorOptions,
        metrics: InformerMetrics,
        logger: Logger,
        retry_policy: RetryPolicy,
        backoff_attempt: u32,
        consecutive_errors: u32,

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
                .resource_version = .{},
                .continue_token = null,
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
            if (self.continue_token) |ct| self.allocator.free(ct);
        }

        /// Run the current watch until it ends or fails, delivering events to `sink`.
        /// The call owns the stream connection and closes it before returning.
        /// Run it in an `std.Io.Future` when the watch must be canceled externally.
        pub fn runWatch(self: *Self, io: std.Io, sink: watch_mod.EventSink(T)) anyerror!void {
            std.debug.assert(self.state == .watching);
            const timeout = self.randomizedWatchTimeout(io);
            const api = ApiT.init(self.client, self.ctx, self.namespace);
            var stream = api.watch(.{
                .label_selector = self.options.label_selector,
                .field_selector = self.options.field_selector,
                .resource_version = self.resource_version.slice(),
                .timeout_seconds = timeout,
                .allow_bookmarks = true,
            }) catch |err| {
                if (err == error.HttpGone) {
                    self.transitionTo(.gone);
                    return;
                }
                return self.handleWatchError(err);
            };
            defer stream.deinit();

            const RunSink = struct {
                reflector: *Self,
                downstream: watch_mod.EventSink(T),

                fn receive(raw: *@This(), callback_io: std.Io, event: *const watch_mod.ParsedEvent(T)) anyerror!void {
                    switch (event.event) {
                        .bookmark => |bookmark| try raw.reflector.updateResourceVersion(bookmark.resource_version),
                        .api_error => |api_error| {
                            if (api_error.code) |code| {
                                if (code == 410) return error.HttpGone;
                                if (code == 401) return error.HttpUnauthorized;
                                if (code == 403) return error.HttpForbidden;
                            }
                            return error.HttpRequestFailed;
                        },
                        .added, .modified, .deleted => {
                            if (raw.reflector.extractEventRV(event.event)) |resource_version| {
                                try raw.reflector.updateResourceVersion(resource_version);
                            }
                        },
                    }
                    try raw.downstream.emit(callback_io, event);
                }
            };
            var run_sink = RunSink{ .reflector = self, .downstream = sink };
            const reflector_sink = watch_mod.EventSink(T).fromTypedCtx(RunSink, &run_sink, RunSink.receive);

            self.resetErrors();
            stream.run(io, reflector_sink) catch |err| {
                if (err == error.HttpGone) {
                    self.transitionTo(.gone);
                    return;
                }
                if (err == error.WatchRelist and self.state == .initial) return;
                if (err == error.Canceled) return error.Canceled;
                return self.handleWatchError(err);
            };
            if (self.state == .initial or self.state == .gone) return;
            self.transitionTo(.watch_ended);
        }

        /// Run one non-watch step of the reflector lifecycle.
        /// Call `runWatch()` while the reflector is in the `.watching` state;
        /// calling `step()` there returns `error.WatchRequiresRun`.
        pub fn step(self: *Self, io: std.Io) !?ReflectorEvent(T) {
            self.ctx.check(io) catch return error.Canceled;

            return switch (self.state) {
                .initial => self.stepInitial(io),
                .listing => self.stepListing(io),
                .watching => return error.WatchRequiresRun,
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
        fn stepInitial(self: *Self, io: std.Io) !?ReflectorEvent(T) {
            if (self.continue_token) |ct| {
                self.allocator.free(ct);
                self.continue_token = null;
            }
            // First list: rv="0" (serve from watch cache).
            // After 410: rv="" (quorum read).
            if (!self.resource_version.isSet()) {
                self.resource_version.assign("0") catch unreachable;
            }
            self.logger.info("initial list starting", &.{
                LogField.string("resource", meta.resource),
            });
            self.transitionTo(.listing);
            return self.stepListing(io);
        }

        fn stepListing(self: *Self, io: std.Io) !?ReflectorEvent(T) {
            const list_start: std.Io.Clock.Timestamp = .now(io, .awake);
            const api = ApiT.init(self.client, self.ctx, self.namespace);

            const rv = self.resource_version.slice();

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

            const result = api.list(io, list_opts) catch |err| {
                return self.recordError(err);
            };

            // Record list duration.
            const dur_ns_i: i96 = list_start.untilNow(io).raw.nanoseconds;
            if (dur_ns_i >= 0) {
                const dur_ns: f64 = @floatFromInt(dur_ns_i);
                self.metrics.list_duration.observe(dur_ns / @as(f64, std.time.ns_per_s));
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
                        return self.recordError(err);
                    };

                    const is_last = new_continue == null;

                    // Save resource version from the last page.
                    if (new_rv) |rv_str| {
                        self.updateResourceVersion(rv_str) catch |err| {
                            for (replace_items) |item| item.deinit();
                            self.allocator.free(replace_items);
                            return self.recordError(err);
                        };
                    }

                    // Save continue token.
                    if (new_continue) |ct| {
                        const owned_ct = self.allocator.dupe(u8, ct) catch |err| {
                            for (replace_items) |item| item.deinit();
                            self.allocator.free(replace_items);
                            return self.recordError(err);
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
                            LogField.string("resource_version", self.resource_version.slice() orelse ""),
                        });
                        self.transitionTo(.watching);
                    }

                    return .{
                        .init_page = .{
                            .items = replace_items,
                            .is_last = is_last,
                            .resource_version = self.resource_version,
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

        fn stepWatchEnded(self: *Self) !?ReflectorEvent(T) {
            // Reconnect from last known resource version.
            self.transitionTo(.watching);
            return null;
        }

        fn stepGone(self: *Self) !?ReflectorEvent(T) {
            // Reset for a fresh list with quorum read.
            self.logger.warn("re-listing after 410 Gone", &.{
                LogField.string("resource", meta.resource),
                LogField.string("old_resource_version", self.resource_version.slice() orelse ""),
            });
            self.resource_version.assign("") catch unreachable;
            self.transitionTo(.initial);
            return null;
        }

        /// Force a re-list by resetting to initial state with a quorum read.
        /// Called by the informer when a watch event cannot be applied
        /// (e.g. OOM on store.put), to ensure the cache is eventually consistent.
        pub fn forceRelist(self: *Self) void {
            self.logger.warn("forcing re-list", &.{
                LogField.string("resource", meta.resource),
            });
            self.resource_version.assign("") catch unreachable;
            std.debug.assert(self.state != .failed);
            self.state = .initial;
        }

        // Helpers
        fn randomizedWatchTimeout(self: *Self, io: std.Io) i64 {
            const base = self.options.watch_timeout_seconds;
            if (base <= 0) return 300;
            // Clamp so that base + jitter (up to 2*base) cannot overflow i64.
            const clamped: u64 = std.math.cast(u64, @min(base, std.math.maxInt(i64) / 2)) orelse return 300;
            // Randomize between base and 2*base to avoid thundering herd.
            var raw: [8]u8 = undefined;
            io.random(&raw);
            const r: u64 = std.mem.readInt(u64, &raw, .little);
            const jitter = r % (clamped +| 1);
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
                    // no more pages. Normalize to null so callers can simply check
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

        pub fn extractEventRV(_: *Self, event: watch_mod.WatchEvent(T)) ?[]const u8 {
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
                for (result_list.items) |item| item.deinit();
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

        pub fn updateResourceVersion(self: *Self, new_rv: []const u8) error{ResourceVersionTooLong}!void {
            try self.resource_version.assign(new_rv);
        }

        fn handleWatchError(self: *Self, err: anyerror) anyerror {
            return switch (self.recordError(err)) {
                .transient_error => err,
                .persistent_error => error.ReflectorFailed,
                else => unreachable,
            };
        }

        /// Record a transient error and return the appropriate event.
        /// If `max_consecutive_errors` is configured and the threshold is
        /// exceeded, transitions to `.failed` and returns `.persistent_error`.
        fn recordError(self: *Self, err: anyerror) ReflectorEvent(T) {
            self.consecutive_errors += 1;
            self.backoff_attempt += 1;
            const classified = classifyError(err);
            if (self.options.max_consecutive_errors) |max| {
                if (self.consecutive_errors >= max) {
                    self.logger.err("list/watch failed", &.{
                        LogField.string("resource", meta.resource),
                        LogField.string("error", @errorName(err)),
                    });
                    self.transitionTo(.failed);
                    return .{ .persistent_error = classified };
                }
            }
            return .{ .transient_error = classified };
        }

        /// Reset the consecutive error counter on any successful operation.
        fn resetErrors(self: *Self) void {
            self.consecutive_errors = 0;
            self.backoff_attempt = 0;
        }

        /// Sleep for the current backoff duration. Returns `error.Canceled`
        /// if the context is already canceled (without logging) or if
        /// cancellation is detected during sleep.
        pub fn backoffSleep(self: *Self, io: std.Io, ctx: Context) error{Canceled}!void {
            try ctx.check(io);
            const ns = self.retry_policy.sleepNs(io, self.backoff_attempt, null);
            self.logger.debug("backoff sleep", &.{
                LogField.string("resource", meta.resource),
                LogField.uint("duration_ms", ns / std.time.ns_per_ms),
            });
            try context_mod.interruptibleSleep(io, ctx, ns);
        }
    };
}
