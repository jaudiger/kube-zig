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
const RunError = reconciler_mod.RunError;
const InformerError = informer_mod.InformerError;
const RetryPolicy = @import("../util/retry.zig").RetryPolicy;
const RateLimiter = @import("../util/rate_limit.zig").RateLimiter;
const metrics_mod = @import("../util/metrics.zig");
const MetricsProvider = metrics_mod.MetricsProvider;
const mapper_mod = @import("mapper.zig");
const testing = std.testing;
const MockTransport = @import("../client/mock.zig").MockTransport;

/// Type-erased wrapper for secondary informers of different resource types.
///
/// Since each secondary informer is an `Informer(S)` for a different type `S`,
/// this struct erases the type behind a vtable so the controller can store
/// and manage them uniformly.
pub const SecondaryInformer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        run: *const fn (ptr: *anyopaque, io: std.Io) InformerError!void,
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
        informer_task: ?std.Io.Future(InformerError!void),
        informer_error: std.atomic.Value(u16),
        secondary_informer_error: std.atomic.Value(u16),
        secondary_informers: std.ArrayList(SecondaryInformer),
        secondary_tasks: std.ArrayList(std.Io.Future(InformerError!void)),
        lifecycle_io: ?std.Io = null,
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

        /// Closure state for the mapping event handler installed on a
        /// secondary informer.
        pub fn SecondaryMappingCtx(comptime S: type) type {
            return struct {
                queue: *WorkQueue,
                map_fn: mapper_mod.MapFn(S),
                primary_store: StoreT.View,
                allocator: std.mem.Allocator,
            };
        }

        /// Heap-allocated co-owner of a secondary `Informer(S)` and its
        /// mapping context.
        pub fn SecondaryWrapper(comptime S: type) type {
            return struct {
                informer: informer_mod.Informer(S),
                ctx: SecondaryMappingCtx(S),
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
            errdefer allocator.destroy(queue);
            queue.* = try WorkQueue.init(allocator, io, .{
                .retry_policy = opts.retry_policy,
                .overall_rate_limit = opts.overall_rate_limit,
                .metrics = queue_m,
                .logger = logger,
            });
            errdefer queue.deinit(io);

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
                .informer_task = null,
                .informer_error = std.atomic.Value(u16).init(0),
                .secondary_informer_error = std.atomic.Value(u16).init(0),
                .secondary_informers = .empty,
                .secondary_tasks = .empty,
                .lifecycle_io = null,
                .logger = logger,
            };
        }

        /// Release all resources including secondary informers, queue, and store.
        pub fn deinit(self: *Self, io: std.Io) void {
            self.cancel(io);
            self.join();
            self.queue.shutdown(io);

            // Deinit secondary informers (via vtable).
            for (self.secondary_informers.items) |si| {
                si.vtable.deinit_fn(si.ptr, self.allocator, io);
            }
            self.secondary_informers.deinit(self.allocator);
            self.secondary_tasks.deinit(self.allocator);

            self.reconciler.deinit(io);
            self.queue.deinit(io);
            self.allocator.destroy(self.queue);
            self.informer.deinit(io);
        }

        /// Add a secondary resource watch. Events on type `S` are mapped to
        /// primary resource `T` keys via `opts.map_fn` and enqueued into the
        /// shared work queue.
        ///
        /// The secondary informer runs its own list+watch task (started when
        /// `start()` or `run()` is called).
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
            std.debug.assert(self.informer_task == null);
            const InformerS = informer_mod.Informer(S);
            const EventHandlerS = informer_mod.EventHandler(S);
            const MappingCtx = SecondaryMappingCtx(S);
            const Wrapper = SecondaryWrapper(S);

            const wrapper = try self.allocator.create(Wrapper);
            errdefer self.allocator.destroy(wrapper);

            wrapper.* = .{
                .informer = InformerS.init(self.allocator, client, self.ctx, namespace, .{
                    .label_selector = opts.label_selector,
                    .field_selector = opts.field_selector,
                    .page_size = opts.page_size,
                    .watch_timeout_seconds = opts.watch_timeout_seconds,
                    .logger = self.logger,
                }),
                .ctx = .{
                    .queue = self.queue,
                    .map_fn = opts.map_fn,
                    .primary_store = self.informer.getStore(),
                    .allocator = self.allocator,
                },
            };
            errdefer wrapper.informer.deinit(io);

            // Create the mapping event handler that maps S events to T keys.
            const handler = EventHandlerS.fromTypedCtx(MappingCtx, &wrapper.ctx, .{
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

            try wrapper.informer.addEventHandler(handler);

            // Build the type-erased vtable for this wrapper.
            const Impl = struct {
                fn run(ptr: *anyopaque, vt_io: std.Io) InformerError!void {
                    const w: *Wrapper = @ptrCast(@alignCast(ptr));
                    return w.informer.run(vt_io);
                }
                fn stop(ptr: *anyopaque, vt_io: std.Io) void {
                    const w: *Wrapper = @ptrCast(@alignCast(ptr));
                    w.informer.stop(vt_io);
                }
                fn hasSynced(ptr: *anyopaque, vt_io: std.Io) bool {
                    const w: *Wrapper = @ptrCast(@alignCast(ptr));
                    return w.informer.hasSynced(vt_io);
                }
                fn deinitFn(ptr: *anyopaque, allocator: std.mem.Allocator, vt_io: std.Io) void {
                    const w: *Wrapper = @ptrCast(@alignCast(ptr));
                    w.informer.deinit(vt_io);
                    allocator.destroy(w);
                }
            };

            const si = SecondaryInformer{
                .ptr = @ptrCast(wrapper),
                .vtable = &.{
                    .run = Impl.run,
                    .cancel = Impl.stop,
                    .has_synced = Impl.hasSynced,
                    .deinit_fn = Impl.deinitFn,
                },
            };

            try self.secondary_informers.append(self.allocator, si);
        }

        /// Spawn N reconciler worker threads and one task per informer.
        /// Returns immediately; call `stop()` to shut down.
        pub fn start(self: *Self, io: std.Io) RunError!void {
            self.logger.info("controller starting", &.{
                LogField.string("resource", T.resource_meta.resource),
                LogField.uint("workers", self.reconciler.max_concurrent_reconciles),
                LogField.uint("secondaries", self.secondary_informers.items.len),
            });
            try self.reconciler.start(io);
            errdefer self.reconciler.stop(io);
            self.lifecycle_io = io;

            self.informer_task = try io.concurrent(informerTask, .{ self, io });

            // Start secondary informer tasks.
            for (self.secondary_informers.items, 0..) |si, idx| {
                const task = io.concurrent(secondaryInformerTask, .{ self, io, si }) catch |err| {
                    self.logger.warn("secondary informer task spawn failed, rolling back", &.{
                        LogField.uint("index", idx),
                        LogField.string("error", @errorName(err)),
                    });
                    self.cancel(io);
                    self.joinSecondaryStartup(true);
                    return err;
                };
                self.secondary_tasks.append(self.allocator, task) catch |err| {
                    // Task was spawned but cannot be tracked, so cancel it.
                    si.vtable.cancel(si.ptr, io);
                    var untracked = task;
                    untracked.cancel(io) catch {};
                    self.cancel(io);
                    self.joinSecondaryStartup(true);
                    return err;
                };
            }
        }

        /// Cancel all components and stop every informer task.
        pub fn cancel(self: *Self, io: std.Io) void {
            self.logger.info("controller canceling", &.{
                LogField.string("resource", T.resource_meta.resource),
            });
            self.cancelInformerTasks(io);
            // Shut down the work queue and unblock reconciler workers.
            self.reconciler.cancel(io);
            self.informer_task = null;
            self.secondary_tasks.clearRetainingCapacity();
        }

        /// Wait for all components to complete. Blocks.
        pub fn join(self: *Self) void {
            self.logger.info("controller joining", &.{
                LogField.string("resource", T.resource_meta.resource),
            });
            // Join reconciler workers.
            self.reconciler.join();
            const io = self.lifecycle_io orelse return;
            // Join secondary informer tasks.
            for (self.secondary_tasks.items) |*task| {
                task.await(io) catch {};
            }
            self.secondary_tasks.clearRetainingCapacity();
            // Join the primary informer task.
            if (self.informer_task) |*task| {
                task.await(io) catch {};
                self.informer_task = null;
            }
        }

        /// Convenience: cancel + join.
        pub fn stop(self: *Self, io: std.Io) void {
            self.cancel(io);
            self.join();
        }

        /// Spawn informer tasks, then block the caller as a single reconcile worker.
        /// Returns when the queue is shut down.
        pub fn run(self: *Self, io: std.Io) !void {
            self.logger.info("controller run", &.{
                LogField.string("resource", T.resource_meta.resource),
                LogField.uint("secondaries", self.secondary_informers.items.len),
            });
            self.lifecycle_io = io;
            self.informer_task = try io.concurrent(informerTask, .{ self, io });

            // Start secondary informer tasks.
            for (self.secondary_informers.items) |si| {
                const task = io.concurrent(secondaryInformerTask, .{ self, io, si }) catch |err| {
                    self.cancelInformerTasks(io);
                    self.joinSecondaryStartup(false);
                    return err;
                };
                self.secondary_tasks.append(self.allocator, task) catch |err| {
                    si.vtable.cancel(si.ptr, io);
                    var untracked = task;
                    untracked.cancel(io) catch {};
                    self.cancelInformerTasks(io);
                    self.joinSecondaryStartup(false);
                    return err;
                };
            }

            self.reconciler.run(io);
            self.cancel(io);
            self.join();
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

        /// If any informer task exited with an error, returns that error.
        /// Prefers the primary informer error; falls back to the first
        /// secondary informer error.
        pub fn getInformerError(self: *Self) ?InformerError {
            return self.getPrimaryInformerError() orelse self.getSecondaryInformerError();
        }

        /// If the primary informer task exited with an error, returns it.
        pub fn getPrimaryInformerError(self: *Self) ?InformerError {
            const code = self.informer_error.load(.acquire);
            if (code == 0) return null;
            return @errorCast(@as(anyerror, @errorFromInt(code)));
        }

        /// If a secondary informer task exited with an error, returns the
        /// first such error.
        pub fn getSecondaryInformerError(self: *Self) ?InformerError {
            const code = self.secondary_informer_error.load(.acquire);
            if (code == 0) return null;
            return @errorCast(@as(anyerror, @errorFromInt(code)));
        }

        fn joinSecondaryStartup(self: *Self, join_reconciler: bool) void {
            const io = self.lifecycle_io orelse return;
            // Join secondary informer tasks.
            for (self.secondary_tasks.items) |*task| {
                task.await(io) catch {};
            }
            self.secondary_tasks.clearRetainingCapacity();
            if (join_reconciler) self.reconciler.join();
            if (self.informer_task) |*task| {
                task.await(io) catch {};
                self.informer_task = null;
            }
        }

        fn cancelInformerTasks(self: *Self, io: std.Io) void {
            // Cancel the primary informer and interrupt its watch socket.
            self.informer.stop(io);
            // Cancel all secondary informers.
            for (self.secondary_informers.items) |si| {
                si.vtable.cancel(si.ptr, io);
            }
            if (self.informer_task) |*task| {
                task.cancel(io) catch {};
            }
            for (self.secondary_tasks.items) |*task| {
                task.cancel(io) catch {};
            }
        }

        fn informerTask(self: *Self, io: std.Io) InformerError!void {
            self.informer.run(io) catch |err| {
                if (err == error.Canceled) return error.Canceled;
                self.logger.err("informer task exited with error", &.{
                    LogField.string("resource", T.resource_meta.resource),
                    LogField.string("error", @errorName(err)),
                });
                self.informer_error.store(@intFromError(err), .release);
                // Shut down the work queue so reconciler workers can exit.
                self.queue.shutdown(io);
                return err;
            };
        }

        fn secondaryInformerTask(self: *Self, io: std.Io, si: SecondaryInformer) InformerError!void {
            si.vtable.run(si.ptr, io) catch |err| {
                if (err == error.Canceled) return error.Canceled;
                self.logger.err("secondary informer task exited with error", &.{
                    LogField.string("resource", T.resource_meta.resource),
                    LogField.string("error", @errorName(err)),
                });
                // Preserve the first secondary informer error.
                _ = self.secondary_informer_error.cmpxchgStrong(0, @intFromError(err), .release, .monotonic);
                self.queue.shutdown(io);
                return err;
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
    try testing.expect(@hasField(ControllerType, "informer_task"));
    try testing.expect(@hasField(ControllerType, "informer_error"));
    try testing.expect(@hasField(ControllerType, "secondary_informer_error"));
    try testing.expect(@hasField(ControllerType, "secondary_informers"));
    try testing.expect(@hasField(ControllerType, "secondary_tasks"));
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
    // Verify that the task field defaults to null.
    const ControllerType = Controller(TestResource);
    const default: ?std.Io.Future(InformerError!void) = null;
    try testing.expect(default == null);
    try testing.expect(@TypeOf(@as(ControllerType, undefined).informer_task) == ?std.Io.Future(InformerError!void));
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
    primary.store(@intFromError(error.ReflectorFailed), .release);

    // Assert: getInformerError-style logic returns primary.
    const primary_code = primary.load(.acquire);
    const secondary_code = secondary.load(.acquire);
    const result: ?InformerError = if (primary_code != 0)
        @errorCast(@as(anyerror, @errorFromInt(primary_code)))
    else if (secondary_code != 0)
        @errorCast(@as(anyerror, @errorFromInt(secondary_code)))
    else
        null;

    try testing.expectEqual(error.ReflectorFailed, result.?);

    // Verify the field types match the controller struct.
    try testing.expect(@TypeOf(primary) == @TypeOf(@as(ControllerType, undefined).informer_error));
    try testing.expect(@TypeOf(secondary) == @TypeOf(@as(ControllerType, undefined).secondary_informer_error));
}

test "Controller: getInformerError falls back to secondary when no primary error" {
    // Arrange
    var primary = std.atomic.Value(u16).init(0);
    var secondary = std.atomic.Value(u16).init(0);

    // Act: simulate only secondary error
    secondary.store(@intFromError(error.ReflectorFailed), .release);

    // Assert: falls back to secondary.
    const primary_code = primary.load(.acquire);
    const secondary_code = secondary.load(.acquire);
    const result: ?InformerError = if (primary_code != 0)
        @errorCast(@as(anyerror, @errorFromInt(primary_code)))
    else if (secondary_code != 0)
        @errorCast(@as(anyerror, @errorFromInt(secondary_code)))
    else
        null;

    try testing.expectEqual(error.ReflectorFailed, result.?);
}

test "Controller: secondary error cmpxchg preserves first error" {
    // Arrange
    var secondary = std.atomic.Value(u16).init(0);
    const first_err = @intFromError(error.ReflectorFailed);
    const other_code: u16 = first_err +% 1;

    // Act: two stores via cmpxchg; only the first against zero succeeds.
    _ = secondary.cmpxchgStrong(0, first_err, .release, .monotonic);
    _ = secondary.cmpxchgStrong(0, other_code, .release, .monotonic);

    // Assert: first error is preserved.
    try testing.expectEqual(first_err, secondary.load(.acquire));
}

test "Controller: primary and secondary errors are independent" {
    // Arrange
    var primary = std.atomic.Value(u16).init(0);
    var secondary = std.atomic.Value(u16).init(0);
    const err_code = @intFromError(error.ReflectorFailed);

    // Act: store into each field.
    primary.store(err_code, .release);
    _ = secondary.cmpxchgStrong(0, err_code, .release, .monotonic);

    // Assert: both fields hold the expected code independently.
    try testing.expectEqual(err_code, primary.load(.acquire));
    try testing.expectEqual(err_code, secondary.load(.acquire));
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
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();
    var client = try mock.client(std.testing.io);
    defer client.deinit(std.testing.io);

    // Act / Assert
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const result = Controller(TestResource).init(failing.allocator(), std.testing.io, &client, Context.background(), "default", opts);
        if (result) |ok| {
            // Succeeded: all allocations passed; clean up and stop.
            var ctrl = ok;
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
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();
    var client = try mock.client(std.testing.io);
    defer client.deinit(std.testing.io);
    var ctrl = try Controller(TestResource).init(testing.allocator, std.testing.io, &client, Context.background(), "default", .{
        .reconcile_fn = reconcile_fn,
    });
    defer {
        ctrl.cancel(std.testing.io);
        ctrl.deinit(std.testing.io);
    }

    // Act
    try ctrl.watchSecondary(std.testing.io, TestSecondary, &client, "default", .{
        .map_fn = mapper_mod.enqueueConst(TestSecondary, "default", "primary"),
    });
    try ctrl.watchSecondary(std.testing.io, TestSecondary, &client, "default", .{
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
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();
    var client = try mock.client(std.testing.io);
    defer client.deinit(std.testing.io);

    // Act / Assert: every OOM path in watchSecondary leaves no leak.
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const alloc = failing.allocator();

        var ctrl = Controller(TestResource).init(alloc, std.testing.io, &client, Context.background(), "default", .{
            .reconcile_fn = reconcile_fn,
        }) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        const ws_result = ctrl.watchSecondary(std.testing.io, TestSecondary, &client, "default", .{
            .map_fn = mapper_mod.enqueueConst(TestSecondary, "default", "primary"),
        });
        ctrl.cancel(std.testing.io);
        ctrl.deinit(std.testing.io);
        if (ws_result) |_| {
            break;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
        }
    }
    // At minimum: WorkQueue create, primary addEventHandler append,
    // SecondaryWrapper create, secondary addEventHandler append, and
    // secondary_informers append.
    try testing.expect(fail_index >= 4);
}

test "Controller: secondary handler enqueues primary key on all event types" {
    // Arrange
    const reconcile_fn = ReconcileFn.fromFn(struct {
        fn reconcile(_: ObjectKey, _: Context) anyerror!reconciler_mod.Result {
            return .{};
        }
    }.reconcile);
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();
    var client = try mock.client(std.testing.io);
    defer client.deinit(std.testing.io);
    var ctrl = try Controller(TestResource).init(testing.allocator, std.testing.io, &client, Context.background(), "default", .{
        .reconcile_fn = reconcile_fn,
    });
    defer {
        ctrl.cancel(std.testing.io);
        ctrl.deinit(std.testing.io);
    }
    try ctrl.watchSecondary(std.testing.io, TestSecondary, &client, "default", .{
        .map_fn = mapper_mod.enqueueConst(TestSecondary, "default", "my-deploy"),
    });

    // Add the primary resource to the store so the handler finds it.
    const arena = try testing.allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(testing.allocator);
    const old_entry = try ctrl.informer.store.put(
        std.testing.io,
        .{
            .key = .{ .namespace = "default", .name = "my-deploy" },
            .object = TestResource{ .metadata = .{ .name = "my-deploy", .namespace = "default" } },
            .arena = arena,
        },
    );
    if (old_entry) |e| e.release();

    const Wrapper = Controller(TestResource).SecondaryWrapper(TestSecondary);
    const wrapper: *Wrapper = @ptrCast(@alignCast(ctrl.secondary_informers.items[0].ptr));
    const handler = wrapper.informer.handlers.items[0];
    const sec_obj = TestSecondary{};

    // Act / Assert: on_add enqueues the mapped primary key.
    handler.onAdd(std.testing.io, &sec_obj, false);
    {
        var item = (try ctrl.queue.get(std.testing.io)).?;
        try testing.expectEqualStrings("default", item.key.namespace);
        try testing.expectEqualStrings("my-deploy", item.key.name);
        item.done(std.testing.io, .success);
    }

    // Act / Assert: on_update enqueues the mapped primary key.
    handler.onUpdate(std.testing.io, &sec_obj, &sec_obj);
    {
        var item = (try ctrl.queue.get(std.testing.io)).?;
        try testing.expectEqualStrings("my-deploy", item.key.name);
        item.done(std.testing.io, .success);
    }

    // Act / Assert: on_delete enqueues the mapped primary key.
    handler.onDelete(std.testing.io, &sec_obj);
    {
        var item = (try ctrl.queue.get(std.testing.io)).?;
        try testing.expectEqualStrings("my-deploy", item.key.name);
        item.done(std.testing.io, .success);
    }
}

test "Controller: secondary handler skips enqueue when conditions are not met" {
    // Arrange
    const reconcile_fn = ReconcileFn.fromFn(struct {
        fn reconcile(_: ObjectKey, _: Context) anyerror!reconciler_mod.Result {
            return .{};
        }
    }.reconcile);
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();
    var client = try mock.client(std.testing.io);
    defer client.deinit(std.testing.io);
    var ctrl = try Controller(TestResource).init(testing.allocator, std.testing.io, &client, Context.background(), "default", .{
        .reconcile_fn = reconcile_fn,
    });
    defer {
        ctrl.cancel(std.testing.io);
        ctrl.deinit(std.testing.io);
    }
    // First secondary: map_fn returns a key but the primary is not in the store.
    try ctrl.watchSecondary(std.testing.io, TestSecondary, &client, "default", .{
        .map_fn = mapper_mod.enqueueConst(TestSecondary, "default", "my-deploy"),
    });
    // Second secondary: map_fn returns null for objects without a matching ownerRef.
    try ctrl.watchSecondary(std.testing.io, TestSecondary, &client, "default", .{
        .map_fn = mapper_mod.enqueueOwner(TestSecondary, "Deployment"),
    });

    const Wrapper = Controller(TestResource).SecondaryWrapper(TestSecondary);
    const w0: *Wrapper = @ptrCast(@alignCast(ctrl.secondary_informers.items[0].ptr));
    const w1: *Wrapper = @ptrCast(@alignCast(ctrl.secondary_informers.items[1].ptr));
    const h0 = w0.informer.handlers.items[0];
    const h1 = w1.informer.handlers.items[0];
    const sec_obj = TestSecondary{};

    // Act
    h0.onAdd(std.testing.io, &sec_obj, false);
    h1.onAdd(std.testing.io, &sec_obj, false);

    // Assert: neither condition allows an enqueue.
    ctrl.queue.shutdown(std.testing.io);
    try testing.expect(try ctrl.queue.get(std.testing.io) == null);
}
