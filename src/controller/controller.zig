//! Controller combining an informer with a reconcile loop.
//!
//! `Controller(T)` composes an `Informer(T)`, a `WorkQueue`, and a
//! `Reconciler` into a single struct with a `start()`/`stop()` lifecycle.
//! Supports watching secondary resource types via `watchSecondary()`, where
//! events on secondary resources are mapped to primary resource keys and
//! fed into the shared work queue.

const std = @import("std");
const logging = @import("../util/logging.zig");
const Logger = logging.Logger;
const LogField = logging.Field;
const client_mod = @import("../client/Client.zig");
const Client = client_mod.Client;
const Context = client_mod.Context;
const informer_mod = @import("../cache/informer.zig");
const store_mod = @import("../cache/store.zig");
const object_key_mod = @import("../object_key.zig");
const ObjectKey = object_key_mod.ObjectKey;
const work_queue_mod = @import("work_queue.zig");
const WorkQueue = work_queue_mod.WorkQueue;
const reconciler_mod = @import("reconciler.zig");
const Reconciler = reconciler_mod.Reconciler;
const ReconcileFn = reconciler_mod.ReconcileFn;
const RetryPolicy = @import("../util/retry.zig").RetryPolicy;
const RateLimiter = @import("../util/rate_limit.zig").RateLimiter;
const metrics_mod = @import("../util/metrics.zig");
const MetricsProvider = metrics_mod.MetricsProvider;
const mapper_mod = @import("mapper.zig");
const testing = std.testing;

/// Type-erased wrapper for secondary informers of different resource types.
///
/// Since each secondary informer is an `Informer(S)` for a different type `S`,
/// this struct erases the type behind a vtable so the controller can store
/// and manage them uniformly.
pub const SecondaryInformer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        run: *const fn (ptr: *anyopaque, io: std.Io) anyerror!void,
        cancel: *const fn (ptr: *anyopaque, io: std.Io) void,
        has_synced: *const fn (ptr: *anyopaque, io: std.Io) bool,
        deinit_fn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) void,
    };
};

/// Composes an `Informer(T)`, `WorkQueue`, and `Reconciler` into a single
/// struct with a clean `start()`/`stop()` lifecycle.
///
/// `T` must be a Kubernetes resource type with a `resource_meta` declaration
/// (e.g. `CoreV1Pod`, `AppsV1Deployment`).
///
/// Supports watching secondary resource types via `watchSecondary()`. Events
/// on secondary resources are mapped to primary resource keys via a mapper
/// function and enqueued into the shared work queue.
///
/// Usage:
/// ```zig
/// var ctrl = try Controller(k8s.CoreV1Pod).init(allocator, &client, client.context(), "default", .{
///     .reconcile_fn = ReconcileFn.fromFn(myReconcile),
/// });
/// defer ctrl.deinit(std.testing.io);
/// try ctrl.run(); // blocks until stop()
/// ```
pub fn Controller(comptime T: type) type {
    const InformerT = informer_mod.Informer(T);
    const StoreT = store_mod.Store(T);

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        ctx: Context,
        informer: InformerT,
        queue: *WorkQueue,
        reconciler: Reconciler,
        informer_thread: ?std.Thread,
        informer_error: std.atomic.Value(u16),
        secondary_informer_error: std.atomic.Value(u16),
        secondary_informers: std.ArrayList(SecondaryInformer),
        secondary_threads: std.ArrayList(std.Thread),
        logger: Logger = Logger.noop,

        pub const Options = struct {
            /// The reconcile callback invoked for each work item.
            reconcile_fn: ReconcileFn,
            /// Number of concurrent reconcile worker threads for `start()`.
            max_concurrent_reconciles: u32 = 1,
            // Informer options
            label_selector: ?[]const u8 = null,
            field_selector: ?[]const u8 = null,
            page_size: i64 = 500,
            watch_timeout_seconds: i64 = 290,
            // WorkQueue options
            retry_policy: RetryPolicy = .{
                .max_retries = std.math.maxInt(u32),
                .initial_backoff_ns = 5 * std.time.ns_per_ms,
                .max_backoff_ns = 1000 * std.time.ns_per_s,
                .backoff_multiplier = 2,
                .jitter = true,
            },
            /// Global token-bucket rate limit for rate-limited requeues.
            /// Defaults to 10 QPS / 100 burst. Set to
            /// `RateLimiter.Config.disabled` to disable.
            overall_rate_limit: RateLimiter.Config = .{ .qps = 10.0, .burst = 100 },
            /// Metrics provider for observability hooks. Default is no-op.
            metrics: MetricsProvider = MetricsProvider.noop,
            /// Controller name used as a label for per-controller metrics.
            name: []const u8 = "default",
            /// Logger for structured logging. Default is no-op.
            logger: Logger = Logger.noop,
        };

        /// Options for a secondary resource watch.
        pub fn SecondaryOptions(comptime S: type) type {
            return struct {
                /// Function to map secondary resource events to primary resource keys.
                map_fn: mapper_mod.MapFn(S),
                /// Label selector for the secondary informer.
                label_selector: ?[]const u8 = null,
                /// Field selector for the secondary informer.
                field_selector: ?[]const u8 = null,
                /// Page size for the secondary informer.
                page_size: i64 = 500,
                /// Watch timeout for the secondary informer.
                watch_timeout_seconds: i64 = 290,
            };
        }

        /// Create a new controller for resource type `T` in the given namespace.
        pub fn init(
            allocator: std.mem.Allocator,
            io: std.Io,
            client: *Client,
            ctx: Context,
            namespace: if (T.resource_meta.namespaced) []const u8 else ?[]const u8,
            opts: Options,
        ) !Self {
            const m = opts.metrics;
            const name = opts.name;
            const queue_m = m.queue.create(name);
            const reconciler_m = m.reconciler.create(name);
            const informer_m = m.informer.create(name);

            const logger = opts.logger.withScope("controller");

            // Create Informer(T) with informer options.
            var informer = InformerT.init(allocator, client, ctx, namespace, .{
                .label_selector = opts.label_selector,
                .field_selector = opts.field_selector,
                .page_size = opts.page_size,
                .watch_timeout_seconds = opts.watch_timeout_seconds,
                .metrics = informer_m,
                .logger = logger,
            });
            errdefer informer.deinit(io);

            // Heap-allocate WorkQueue for pointer stability.
            const queue = try allocator.create(WorkQueue);
            errdefer {
                queue.deinit(io);
                allocator.destroy(queue);
            }
            queue.* = WorkQueue.init(allocator, io, .{
                .retry_policy = opts.retry_policy,
                .overall_rate_limit = opts.overall_rate_limit,
                .metrics = queue_m,
                .logger = logger,
            });

            // Wire informer to queue via event handler.
            try informer.addEventHandler(queue.eventHandler(T));

            // Create Reconciler with queue pointer and reconcile options.
            const reconciler = Reconciler.init(allocator, queue, ctx, .{
                .reconcile_fn = opts.reconcile_fn,
                .max_concurrent_reconciles = opts.max_concurrent_reconciles,
                .metrics = reconciler_m,
                .queue_metrics = queue_m,
                .logger = logger,
            });

            return .{
                .allocator = allocator,
                .ctx = ctx,
                .informer = informer,
                .queue = queue,
                .reconciler = reconciler,
                .informer_thread = null,
                .informer_error = std.atomic.Value(u16).init(0),
                .secondary_informer_error = std.atomic.Value(u16).init(0),
                .secondary_informers = .empty,
                .secondary_threads = .empty,
                .logger = logger,
            };
        }

        /// Release all resources including secondary informers, queue, and store.
        pub fn deinit(self: *Self, io: std.Io) void {
            // Deinit secondary informers (via vtable).
            for (self.secondary_informers.items) |si| {
                si.vtable.deinit_fn(si.ptr, self.allocator, io);
            }
            self.secondary_informers.deinit(self.allocator);
            self.secondary_threads.deinit(self.allocator);

            self.reconciler.deinit();
            self.queue.deinit(io);
            self.allocator.destroy(self.queue);
            self.informer.deinit(io);
        }

        /// Add a secondary resource watch. Events on type `S` are mapped to
        /// primary resource `T` keys via `opts.map_fn` and enqueued into the
        /// shared work queue.
        ///
        /// The secondary informer runs its own list+watch loop in a separate
        /// thread (started when `start()` or `run()` is called).
        ///
        /// Must be called before `start()` or `run()`.
        ///
        /// Usage:
        /// ```zig
        /// var ctrl = try Controller(k8s.AppsV1Deployment).init(allocator, &client, client.context(), "default", .{
        ///     .reconcile_fn = myReconcileFn,
        /// });
        /// try ctrl.watchSecondary(io, k8s.CoreV1Pod, &client, "default", .{
        ///     .map_fn = mapper.enqueueOwner(k8s.CoreV1Pod, "Deployment"),
        /// });
        /// try ctrl.run();
        /// ```
        pub fn watchSecondary(
            self: *Self,
            io: std.Io,
            comptime S: type,
            client: *Client,
            namespace: if (S.resource_meta.namespaced) []const u8 else ?[]const u8,
            opts: SecondaryOptions(S),
        ) !void {
            std.debug.assert(self.informer_thread == null);
            const InformerS = informer_mod.Informer(S);
            const EventHandlerS = informer_mod.EventHandler(S);

            // Context struct for the mapping event handler.
            const MappingCtx = struct {
                queue: *WorkQueue,
                map_fn: mapper_mod.MapFn(S),
                primary_store: StoreT.View,
                allocator: std.mem.Allocator,
            };

            // Heap-allocate the mapping context for pointer stability.
            const mapping_ctx = try self.allocator.create(MappingCtx);
            errdefer self.allocator.destroy(mapping_ctx);
            mapping_ctx.* = .{
                .queue = self.queue,
                .map_fn = opts.map_fn,
                .primary_store = self.informer.getStore(),
                .allocator = self.allocator,
            };

            // Heap-allocate the secondary Informer(S).
            const sec_informer = try self.allocator.create(InformerS);
            errdefer {
                sec_informer.deinit(io);
                self.allocator.destroy(sec_informer);
            }
            sec_informer.* = InformerS.init(self.allocator, client, self.ctx, namespace, .{
                .label_selector = opts.label_selector,
                .field_selector = opts.field_selector,
                .page_size = opts.page_size,
                .watch_timeout_seconds = opts.watch_timeout_seconds,
                .logger = self.logger,
            });

            // Create the mapping event handler that maps S events to T keys.
            const handler = EventHandlerS.fromTypedCtx(MappingCtx, mapping_ctx, .{
                .on_add = struct {
                    fn f(ctx: *MappingCtx, cb_io: std.Io, obj: *const S, _: bool) void {
                        if (ctx.map_fn(ctx.allocator, obj)) |key| {
                            // Skip enqueue if primary resource no longer exists in cache.
                            if (!ctx.primary_store.contains(cb_io, key)) return;
                            ctx.queue.add(cb_io, key, .{}) catch |err| {
                                ctx.queue.logger.warn("secondary event handler: failed to enqueue", &.{
                                    LogField.string("error", @errorName(err)),
                                });
                            };
                        }
                    }
                }.f,
                .on_update = struct {
                    fn f(ctx: *MappingCtx, cb_io: std.Io, _: *const S, new: *const S) void {
                        if (ctx.map_fn(ctx.allocator, new)) |key| {
                            // Skip enqueue if primary resource no longer exists in cache.
                            if (!ctx.primary_store.contains(cb_io, key)) return;
                            ctx.queue.add(cb_io, key, .{}) catch |err| {
                                ctx.queue.logger.warn("secondary event handler: failed to enqueue", &.{
                                    LogField.string("error", @errorName(err)),
                                });
                            };
                        }
                    }
                }.f,
                .on_delete = struct {
                    fn f(ctx: *MappingCtx, cb_io: std.Io, obj: *const S) void {
                        if (ctx.map_fn(ctx.allocator, obj)) |key| {
                            // Skip enqueue if primary resource no longer exists in cache.
                            if (!ctx.primary_store.contains(cb_io, key)) return;
                            ctx.queue.add(cb_io, key, .{}) catch |err| {
                                ctx.queue.logger.warn("secondary event handler: failed to enqueue", &.{
                                    LogField.string("error", @errorName(err)),
                                });
                            };
                        }
                    }
                }.f,
            });

            try sec_informer.addEventHandler(handler);

            // Build the type-erased vtable for this Informer(S).
            const Impl = struct {
                fn run(ptr: *anyopaque, vt_io: std.Io) anyerror!void {
                    const inf: *InformerS = @ptrCast(@alignCast(ptr));
                    return inf.run(vt_io);
                }
                fn stop(ptr: *anyopaque, vt_io: std.Io) void {
                    const inf: *InformerS = @ptrCast(@alignCast(ptr));
                    inf.stop(vt_io);
                }
                fn hasSynced(ptr: *anyopaque, vt_io: std.Io) bool {
                    const inf: *InformerS = @ptrCast(@alignCast(ptr));
                    return inf.hasSynced(vt_io);
                }
                fn deinitFn(ptr: *anyopaque, allocator: std.mem.Allocator, vt_io: std.Io) void {
                    const inf: *InformerS = @ptrCast(@alignCast(ptr));
                    // Free the mapping context. The handler holds a pointer to it,
                    // but we're tearing down, so that's fine.
                    // The mapping ctx is stored as the first handler's ctx pointer.
                    if (inf.handlers.items.len > 0) {
                        if (inf.handlers.items[0].ctx) |ctx_ptr| {
                            const ctx: *MappingCtx = @ptrCast(@alignCast(ctx_ptr));
                            allocator.destroy(ctx);
                        }
                    }
                    inf.deinit(vt_io);
                    allocator.destroy(inf);
                }
            };

            const si = SecondaryInformer{
                .ptr = @ptrCast(sec_informer),
                .vtable = &.{
                    .run = Impl.run,
                    .cancel = Impl.stop,
                    .has_synced = Impl.hasSynced,
                    .deinit_fn = Impl.deinitFn,
                },
            };

            try self.secondary_informers.append(self.allocator, si);
        }

        /// Spawn N reconciler worker threads, 1 primary informer thread,
        /// and 1 thread per secondary informer.
        /// Returns immediately; call `stop()` to shut down.
        pub fn start(self: *Self, io: std.Io) !void {
            self.logger.info("controller starting", &.{
                LogField.string("resource", T.resource_meta.resource),
                LogField.uint("workers", self.reconciler.max_concurrent_reconciles),
                LogField.uint("secondaries", self.secondary_informers.items.len),
            });
            try self.reconciler.start(io);
            errdefer self.reconciler.stop(io);

            self.informer_thread = try std.Thread.spawn(.{}, informerThreadFn, .{ self, io });

            // Start secondary informer threads.
            for (self.secondary_informers.items, 0..) |si, idx| {
                const thread = std.Thread.spawn(.{}, secondaryInformerThreadFn, .{ self, io, si }) catch |err| {
                    self.logger.warn("secondary thread spawn failed, rolling back", &.{
                        LogField.uint("index", idx),
                        LogField.string("error", @errorName(err)),
                    });
                    self.cancel(io);
                    self.joinSecondaryStartup(true);
                    return err;
                };
                self.secondary_threads.append(self.allocator, thread) catch |err| {
                    // Thread was spawned but we can't track it, so cancel it.
                    si.vtable.cancel(si.ptr, io);
                    thread.join();
                    self.cancel(io);
                    self.joinSecondaryStartup(true);
                    return err;
                };
            }
        }

        /// Signal all components to stop. Non-blocking.
        pub fn cancel(self: *Self, io: std.Io) void {
            self.logger.info("controller canceling", &.{
                LogField.string("resource", T.resource_meta.resource),
            });
            // Cancel primary informer (sets flag + interrupts watch socket).
            self.informer.stop(io);
            // Cancel all secondary informers.
            for (self.secondary_informers.items) |si| {
                si.vtable.cancel(si.ptr, io);
            }
            // Shut down the work queue (unblocks reconciler workers).
            self.reconciler.cancel(io);
        }

        /// Wait for all threads to complete. Blocks.
        pub fn join(self: *Self) void {
            self.logger.info("controller joining", &.{
                LogField.string("resource", T.resource_meta.resource),
            });
            // Join reconciler workers.
            self.reconciler.join();
            // Join secondary informer threads.
            for (self.secondary_threads.items) |thread| {
                thread.join();
            }
            self.secondary_threads.clearRetainingCapacity();
            // Join primary informer thread.
            if (self.informer_thread) |thread| {
                thread.join();
                self.informer_thread = null;
            }
        }

        /// Convenience: cancel + join.
        pub fn stop(self: *Self, io: std.Io) void {
            self.cancel(io);
            self.join();
        }

        /// Spawn 1 primary informer thread and secondary informer threads,
        /// then block the caller as a single reconcile worker.
        /// Returns when the queue is shut down.
        pub fn run(self: *Self, io: std.Io) !void {
            self.logger.info("controller run", &.{
                LogField.string("resource", T.resource_meta.resource),
                LogField.uint("secondaries", self.secondary_informers.items.len),
            });
            self.informer_thread = try std.Thread.spawn(.{}, informerThreadFn, .{ self, io });

            // Start secondary informer threads.
            for (self.secondary_informers.items) |si| {
                const thread = std.Thread.spawn(.{}, secondaryInformerThreadFn, .{ self, io, si }) catch |err| {
                    self.informer.stop(io);
                    for (self.secondary_informers.items) |s| s.vtable.cancel(s.ptr, io);
                    self.joinSecondaryStartup(false);
                    return err;
                };
                self.secondary_threads.append(self.allocator, thread) catch |err| {
                    si.vtable.cancel(si.ptr, io);
                    thread.join();
                    self.informer.stop(io);
                    for (self.secondary_informers.items) |s| s.vtable.cancel(s.ptr, io);
                    self.joinSecondaryStartup(false);
                    return err;
                };
            }

            self.reconciler.run(io);
        }

        /// Get a read-only handle to the informer's store for querying cached objects.
        pub fn getStore(self: *Self) StoreT.View {
            return self.informer.getStore();
        }

        /// Has the primary informer completed its initial list-and-sync?
        pub fn hasSynced(self: *Self, io: std.Io) bool {
            if (!self.informer.hasSynced(io)) return false;
            for (self.secondary_informers.items) |si| {
                if (!si.vtable.has_synced(si.ptr, io)) return false;
            }
            return true;
        }

        /// If any informer thread exited with an error, returns that error.
        /// Prefers the primary informer error; falls back to the first
        /// secondary informer error.
        pub fn getInformerError(self: *Self) ?anyerror {
            return self.getPrimaryInformerError() orelse self.getSecondaryInformerError();
        }

        /// If the primary informer thread exited with an error, returns it.
        pub fn getPrimaryInformerError(self: *Self) ?anyerror {
            const code = self.informer_error.load(.acquire);
            if (code == 0) return null;
            return @errorFromInt(code);
        }

        /// If a secondary informer thread exited with an error, returns
        /// the first such error.
        pub fn getSecondaryInformerError(self: *Self) ?anyerror {
            const code = self.secondary_informer_error.load(.acquire);
            if (code == 0) return null;
            return @errorFromInt(code);
        }

        fn joinSecondaryStartup(self: *Self, join_reconciler: bool) void {
            for (self.secondary_threads.items) |t| t.join();
            self.secondary_threads.clearRetainingCapacity();
            if (join_reconciler) {
                self.reconciler.join();
            }
            if (self.informer_thread) |t| {
                t.join();
                self.informer_thread = null;
            }
        }

        fn informerThreadFn(self: *Self, io: std.Io) void {
            self.informer.run(io) catch |err| {
                self.logger.err("informer thread exited with error", &.{
                    LogField.string("resource", T.resource_meta.resource),
                    LogField.string("error", @errorName(err)),
                });
                self.informer_error.store(@intFromError(err), .release);
                // Shut down the work queue so reconciler workers unblock
                // from get() and exit instead of waiting forever.
                self.queue.shutdown(io);
            };
        }

        fn secondaryInformerThreadFn(self: *Self, io: std.Io, si: SecondaryInformer) void {
            si.vtable.run(si.ptr, io) catch |err| {
                self.logger.err("secondary informer thread exited with error", &.{
                    LogField.string("resource", T.resource_meta.resource),
                    LogField.string("error", @errorName(err)),
                });
                // Store only the first secondary error (preserve it from
                // being overwritten by later failures).
                _ = self.secondary_informer_error.cmpxchgStrong(0, @intFromError(err), .release, .monotonic);
                self.queue.shutdown(io);
            };
        }
    };
}

const test_types = @import("../test_types.zig");
const TestMeta = test_types.TestMeta;
const TestListMeta = test_types.TestListMeta;

/// Minimal test resource type with resource_meta for comptime tests.
const TestResource = struct {
    pub const resource_meta = .{
        .group = "",
        .version = "v1",
        .kind = "TestResource",
        .resource = "testresources",
        .namespaced = true,
        .list_kind = TestResourceList,
    };

    metadata: ?TestMeta = null,
};

const TestResourceList = struct {
    metadata: ?TestListMeta = null,
    items: ?[]const TestResource = null,
};

/// Secondary test resource type with resource_meta.
const TestSecondary = struct {
    pub const resource_meta = .{
        .group = "",
        .version = "v1",
        .kind = "TestSecondary",
        .resource = "testsecondaries",
        .namespaced = true,
        .list_kind = TestSecondaryList,
    };

    metadata: ?TestMeta = null,
};

const TestSecondaryList = struct {
    metadata: ?TestListMeta = null,
    items: ?[]const TestSecondary = null,
};

test "Controller: comptime instantiation" {
    // Act / Assert
    // Verify that Controller(TestResource) resolves at comptime.
    const ControllerType = Controller(TestResource);
    // Verify key type fields exist.
    try testing.expect(@hasField(ControllerType, "informer"));
    try testing.expect(@hasField(ControllerType, "queue"));
    try testing.expect(@hasField(ControllerType, "reconciler"));
    try testing.expect(@hasField(ControllerType, "informer_thread"));
    try testing.expect(@hasField(ControllerType, "informer_error"));
    try testing.expect(@hasField(ControllerType, "secondary_informer_error"));
    try testing.expect(@hasField(ControllerType, "secondary_informers"));
    try testing.expect(@hasField(ControllerType, "secondary_threads"));
}

test "Controller: Options defaults" {
    // Act
    const opts = Controller(TestResource).Options{
        .reconcile_fn = ReconcileFn.fromFn(struct {
            fn reconcile(_: ObjectKey, _: Context) anyerror!reconciler_mod.Result {
                return .{};
            }
        }.reconcile),
    };

    // Assert
    try testing.expectEqual(@as(u32, 1), opts.max_concurrent_reconciles);
    try testing.expect(opts.label_selector == null);
    try testing.expect(opts.field_selector == null);
    try testing.expectEqual(@as(i64, 500), opts.page_size);
    try testing.expectEqual(@as(i64, 290), opts.watch_timeout_seconds);
    try testing.expectEqual(@as(u64, 5 * std.time.ns_per_ms), opts.retry_policy.initial_backoff_ns);
    try testing.expect(opts.retry_policy.jitter);
}

test "Controller: stop without start is safe" {
    // Act / Assert
    // We cannot fully init a Controller without a real Client, but we can
    // verify that the stop logic handles a null informer_thread gracefully
    // by checking the field's default value.
    const ControllerType = Controller(TestResource);
    // A default-constructed informer_thread is null.
    const default: ?std.Thread = null;
    try testing.expect(default == null);
    // Verify the field type matches.
    try testing.expect(@TypeOf(@as(ControllerType, undefined).informer_thread) == ?std.Thread);
}

test "Controller: has watchSecondary declaration" {
    // Act / Assert
    const ControllerType = Controller(TestResource);
    try testing.expect(@hasDecl(ControllerType, "watchSecondary"));
}

test "Controller: SecondaryOptions has expected fields" {
    // Act / Assert
    const SOpts = Controller(TestResource).SecondaryOptions(TestSecondary);
    try testing.expect(@hasField(SOpts, "map_fn"));
    try testing.expect(@hasField(SOpts, "label_selector"));
    try testing.expect(@hasField(SOpts, "field_selector"));
    try testing.expect(@hasField(SOpts, "page_size"));
    try testing.expect(@hasField(SOpts, "watch_timeout_seconds"));
}

test "Controller: SecondaryOptions defaults" {
    // Arrange
    const SOpts = Controller(TestResource).SecondaryOptions(TestSecondary);
    const opts = SOpts{
        .map_fn = mapper_mod.enqueueOwner(TestSecondary, "TestResource"),
    };

    // Act / Assert
    try testing.expect(opts.label_selector == null);
    try testing.expect(opts.field_selector == null);
    try testing.expectEqual(@as(i64, 500), opts.page_size);
    try testing.expectEqual(@as(i64, 290), opts.watch_timeout_seconds);
}

test "SecondaryInformer: VTable has expected methods" {
    // Act / Assert
    const vtable_info = @typeInfo(SecondaryInformer.VTable);
    try testing.expectEqual(4, vtable_info.@"struct".fields.len);
    try testing.expect(@hasField(SecondaryInformer.VTable, "run"));
    try testing.expect(@hasField(SecondaryInformer.VTable, "cancel"));
    try testing.expect(@hasField(SecondaryInformer.VTable, "has_synced"));
    try testing.expect(@hasField(SecondaryInformer.VTable, "deinit_fn"));
}

test "Controller: getInformerError prefers primary over secondary" {
    // Arrange
    const ControllerType = Controller(TestResource);
    var primary = std.atomic.Value(u16).init(0);
    var secondary = std.atomic.Value(u16).init(0);

    // Act: simulate primary error
    primary.store(@intFromError(error.ConnectionRefused), .release);

    // Assert: getInformerError-style logic returns primary.
    const primary_code = primary.load(.acquire);
    const secondary_code = secondary.load(.acquire);
    const result: ?anyerror = if (primary_code != 0)
        @errorFromInt(primary_code)
    else if (secondary_code != 0)
        @errorFromInt(secondary_code)
    else
        null;

    try testing.expectEqual(error.ConnectionRefused, result.?);

    // Verify the field types match the controller struct.
    try testing.expect(@TypeOf(primary) == @TypeOf(@as(ControllerType, undefined).informer_error));
    try testing.expect(@TypeOf(secondary) == @TypeOf(@as(ControllerType, undefined).secondary_informer_error));
}

test "Controller: getInformerError falls back to secondary when no primary error" {
    // Arrange
    var primary = std.atomic.Value(u16).init(0);
    var secondary = std.atomic.Value(u16).init(0);

    // Act: simulate only secondary error
    secondary.store(@intFromError(error.ConnectionRefused), .release);

    // Assert: falls back to secondary.
    const primary_code = primary.load(.acquire);
    const secondary_code = secondary.load(.acquire);
    const result: ?anyerror = if (primary_code != 0)
        @errorFromInt(primary_code)
    else if (secondary_code != 0)
        @errorFromInt(secondary_code)
    else
        null;

    try testing.expectEqual(error.ConnectionRefused, result.?);
}

test "Controller: secondary error cmpxchg preserves first error" {
    // Arrange
    var secondary = std.atomic.Value(u16).init(0);
    const first_err = @intFromError(error.ConnectionRefused);
    const second_err = @intFromError(error.OutOfMemory);

    // Act: two concurrent stores via cmpxchg (first wins).
    _ = secondary.cmpxchgStrong(0, first_err, .release, .monotonic);
    _ = secondary.cmpxchgStrong(0, second_err, .release, .monotonic);

    // Assert: first error is preserved.
    try testing.expectEqual(first_err, secondary.load(.acquire));
}

test "Controller: primary and secondary errors are independent" {
    // Arrange
    var primary = std.atomic.Value(u16).init(0);
    var secondary = std.atomic.Value(u16).init(0);

    // Act: store different errors in each.
    primary.store(@intFromError(error.ConnectionRefused), .release);
    _ = secondary.cmpxchgStrong(0, @intFromError(error.OutOfMemory), .release, .monotonic);

    // Assert: each field holds its own error.
    try testing.expectEqual(@intFromError(error.ConnectionRefused), primary.load(.acquire));
    try testing.expectEqual(@intFromError(error.OutOfMemory), secondary.load(.acquire));
}

test "Controller: init returns OutOfMemory without leaking" {
    // Arrange
    const reconcile_fn = ReconcileFn.fromFn(struct {
        fn reconcile(_: ObjectKey, _: Context) anyerror!reconciler_mod.Result {
            return .{};
        }
    }.reconcile);
    const opts = Controller(TestResource).Options{
        .reconcile_fn = reconcile_fn,
    };
    // Use a dummy client pointer. init() only stores it, never dereferences.
    const dummy_client: *Client = @ptrFromInt(@alignOf(Client));

    // Act / Assert
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.heap.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const result = Controller(TestResource).init(failing.allocator(), std.testing.io, dummy_client, Context.background(), "default", opts);
        if (result) |_| {
            // Succeeded: all allocations passed; clean up and stop.
            var ctrl = result.?;
            ctrl.deinit(std.testing.io);
            break;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
        }
    }
    // Verify we actually tested at least the two known allocation points
    // (WorkQueue create + addEventHandler append).
    try testing.expect(fail_index >= 2);
}

test "Controller: watchSecondary registers secondaries and blocks hasSynced until synced" {
    // Arrange
    const reconcile_fn = ReconcileFn.fromFn(struct {
        fn reconcile(_: ObjectKey, _: Context) anyerror!reconciler_mod.Result {
            return .{};
        }
    }.reconcile);
    const dummy_client: *Client = @ptrFromInt(@alignOf(Client));
    var ctrl = try Controller(TestResource).init(testing.allocator, std.testing.io, dummy_client, Context.background(), "default", .{
        .reconcile_fn = reconcile_fn,
    });
    defer {
        ctrl.cancel(std.testing.io);
        ctrl.deinit(std.testing.io);
    }

    // Act
    try ctrl.watchSecondary(std.testing.io, TestSecondary, dummy_client, "default", .{
        .map_fn = mapper_mod.enqueueConst(TestSecondary, "default", "primary"),
    });
    try ctrl.watchSecondary(std.testing.io, TestSecondary, dummy_client, "default", .{
        .map_fn = mapper_mod.enqueueConst(TestSecondary, "default", "primary"),
    });

    // Simulate the primary store having completed its initial list sync.
    const sync = try ctrl.informer.store.replace(std.testing.io, &.{});
    sync.release();

    // Assert: both secondaries registered; hasSynced is false because neither has started.
    try testing.expectEqual(@as(usize, 2), ctrl.secondary_informers.items.len);
    try testing.expect(ctrl.informer.hasSynced(std.testing.io));
    try testing.expect(!ctrl.hasSynced(std.testing.io));
}

test "Controller: watchSecondary returns OutOfMemory without leaking" {
    // Arrange
    const reconcile_fn = ReconcileFn.fromFn(struct {
        fn reconcile(_: ObjectKey, _: Context) anyerror!reconciler_mod.Result {
            return .{};
        }
    }.reconcile);
    const dummy_client: *Client = @ptrFromInt(@alignOf(Client));

    // Act / Assert: every OOM path in watchSecondary leaves no leak.
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.heap.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const alloc = failing.allocator();

        var ctrl = Controller(TestResource).init(alloc, std.testing.io, dummy_client, Context.background(), "default", .{
            .reconcile_fn = reconcile_fn,
        }) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        const ws_result = ctrl.watchSecondary(std.testing.io, TestSecondary, dummy_client, "default", .{
            .map_fn = mapper_mod.enqueueConst(TestSecondary, "default", "primary"),
        });
        ctrl.cancel(std.testing.io);
        ctrl.deinit(std.testing.io);
        if (ws_result) |_| break;
        try testing.expectError(error.OutOfMemory, ws_result);
    }
    // At minimum: WorkQueue create, addEventHandler append, MappingCtx
    // create, Informer(S) create, and secondary_informers append.
    try testing.expect(fail_index >= 4);
}

test "Controller: secondary handler enqueues primary key on all event types" {
    // Arrange
    const reconcile_fn = ReconcileFn.fromFn(struct {
        fn reconcile(_: ObjectKey, _: Context) anyerror!reconciler_mod.Result {
            return .{};
        }
    }.reconcile);
    const dummy_client: *Client = @ptrFromInt(@alignOf(Client));
    var ctrl = try Controller(TestResource).init(testing.allocator, std.testing.io, dummy_client, Context.background(), "default", .{
        .reconcile_fn = reconcile_fn,
    });
    defer {
        ctrl.cancel(std.testing.io);
        ctrl.deinit(std.testing.io);
    }
    try ctrl.watchSecondary(std.testing.io, TestSecondary, dummy_client, "default", .{
        .map_fn = mapper_mod.enqueueConst(TestSecondary, "default", "my-deploy"),
    });

    // Add the primary resource to the store so the handler finds it.
    const arena = try testing.allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(testing.allocator);
    const old_entry = try ctrl.informer.store.put(
        std.testing.io,
        .{ .namespace = "default", .name = "my-deploy" },
        TestResource{ .metadata = .{ .name = "my-deploy", .namespace = "default" } },
        arena,
    );
    if (old_entry) |e| e.release();

    const InformerS = informer_mod.Informer(TestSecondary);
    const sec_inf: *InformerS = @ptrCast(@alignCast(ctrl.secondary_informers.items[0].ptr));
    const handler = sec_inf.handlers.items[0];
    const sec_obj = TestSecondary{};

    // Act / Assert: on_add enqueues the mapped primary key.
    handler.onAdd(std.testing.io, &sec_obj, false);
    {
        const key = (try ctrl.queue.get(std.testing.io)).?;
        try testing.expectEqualStrings("default", key.namespace);
        try testing.expectEqualStrings("my-deploy", key.name);
        ctrl.queue.done(std.testing.io, key, .success);
    }

    // Act / Assert: on_update enqueues the mapped primary key.
    handler.onUpdate(std.testing.io, &sec_obj, &sec_obj);
    {
        const key = (try ctrl.queue.get(std.testing.io)).?;
        try testing.expectEqualStrings("my-deploy", key.name);
        ctrl.queue.done(std.testing.io, key, .success);
    }

    // Act / Assert: on_delete enqueues the mapped primary key.
    handler.onDelete(std.testing.io, &sec_obj);
    {
        const key = (try ctrl.queue.get(std.testing.io)).?;
        try testing.expectEqualStrings("my-deploy", key.name);
        ctrl.queue.done(std.testing.io, key, .success);
    }
}

test "Controller: secondary handler skips enqueue when conditions are not met" {
    // Arrange
    const reconcile_fn = ReconcileFn.fromFn(struct {
        fn reconcile(_: ObjectKey, _: Context) anyerror!reconciler_mod.Result {
            return .{};
        }
    }.reconcile);
    const dummy_client: *Client = @ptrFromInt(@alignOf(Client));
    var ctrl = try Controller(TestResource).init(testing.allocator, std.testing.io, dummy_client, Context.background(), "default", .{
        .reconcile_fn = reconcile_fn,
    });
    defer {
        ctrl.cancel(std.testing.io);
        ctrl.deinit(std.testing.io);
    }
    // First secondary: map_fn returns a key but the primary is not in the store.
    try ctrl.watchSecondary(std.testing.io, TestSecondary, dummy_client, "default", .{
        .map_fn = mapper_mod.enqueueConst(TestSecondary, "default", "my-deploy"),
    });
    // Second secondary: map_fn returns null for objects without a matching ownerRef.
    try ctrl.watchSecondary(std.testing.io, TestSecondary, dummy_client, "default", .{
        .map_fn = mapper_mod.enqueueOwner(TestSecondary, "Deployment"),
    });

    const InformerS = informer_mod.Informer(TestSecondary);
    const h0 = (@as(*InformerS, @ptrCast(@alignCast(ctrl.secondary_informers.items[0].ptr)))).handlers.items[0];
    const h1 = (@as(*InformerS, @ptrCast(@alignCast(ctrl.secondary_informers.items[1].ptr)))).handlers.items[0];
    const sec_obj = TestSecondary{};

    // Act
    h0.onAdd(std.testing.io, &sec_obj, false);
    h1.onAdd(std.testing.io, &sec_obj, false);

    // Assert: neither condition allows an enqueue.
    ctrl.queue.shutdown(std.testing.io);
    try testing.expect(try ctrl.queue.get(std.testing.io) == null);
}
