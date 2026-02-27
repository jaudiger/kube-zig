//! Reconciler types and helpers for the controller runtime.
//!
//! Provides the `Reconciler` struct that pulls `ObjectKey` values from a
//! `WorkQueue`, invokes a user-defined `ReconcileFn`, and routes the result
//! back to the queue. Supports both single-threaded (`run()`) and
//! multi-threaded (`start()`/`stop()`) operation.

const std = @import("std");
const logging = @import("../util/logging.zig");
const Logger = logging.Logger;
const LogField = logging.Field;
const client_mod = @import("../client/Client.zig");
const Context = client_mod.Context;
const store_mod = @import("../cache/store.zig");
const ObjectKey = store_mod.ObjectKey;
const work_queue_mod = @import("work_queue.zig");
const WorkQueue = work_queue_mod.WorkQueue;
const metrics_mod = @import("../util/metrics.zig");
const ReconcilerMetrics = metrics_mod.ReconcilerMetrics;
const QueueMetrics = metrics_mod.QueueMetrics;
const testing = std.testing;

/// Result returned by a reconcile callback to indicate what action the
/// Reconciler should take on the processed key.
///
/// Interpretation (checked in priority order):
/// 1. `requeue_after_ns > 0`: forget backoff, enqueue again after a fixed delay.
/// 2. `requeue == true`:      rate-limited requeue (exponential backoff).
/// 3. Both false/zero:        success, forget backoff state.
pub const Result = struct {
    requeue: bool = false,
    requeue_after_ns: u64 = 0,
};

/// Type-erased reconcile callback.
///
/// Use `fromTypedCtx` to create one from a typed context pointer and a typed
/// function, or `fromFn` for a context-free function.
pub const ReconcileFn = struct {
    ctx: ?*anyopaque,
    call: *const fn (ctx: ?*anyopaque, key: ObjectKey, reconcile_ctx: Context) anyerror!Result,

    /// Create a `ReconcileFn` from a typed context pointer and a typed callback.
    pub fn fromTypedCtx(
        comptime Ctx: type,
        ctx_ptr: *Ctx,
        comptime func: *const fn (c: *Ctx, key: ObjectKey, reconcile_ctx: Context) anyerror!Result,
    ) ReconcileFn {
        const Wrapper = struct {
            fn call(raw: ?*anyopaque, key: ObjectKey, reconcile_ctx: Context) anyerror!Result {
                const typed: *Ctx = @ptrCast(@alignCast(raw.?));
                return func(typed, key, reconcile_ctx);
            }
        };
        return .{
            .ctx = @ptrCast(ctx_ptr),
            .call = Wrapper.call,
        };
    }

    /// Create a `ReconcileFn` from a plain function pointer (no context).
    pub fn fromFn(
        comptime func: *const fn (key: ObjectKey, reconcile_ctx: Context) anyerror!Result,
    ) ReconcileFn {
        const Wrapper = struct {
            fn call(_: ?*anyopaque, key: ObjectKey, reconcile_ctx: Context) anyerror!Result {
                return func(key, reconcile_ctx);
            }
        };
        return .{
            .ctx = null,
            .call = Wrapper.call,
        };
    }

    fn invoke(self: ReconcileFn, key: ObjectKey, reconcile_ctx: Context) anyerror!Result {
        return self.call(self.ctx, key, reconcile_ctx);
    }
};

/// Reconciler pulls `ObjectKey` values from a `WorkQueue`, invokes a
/// user-defined reconcile callback, and routes the result back to the queue
/// via `done(key, action)` (single atomic operation per key):
/// - success:       `done(key, .success)`
/// - error:         `done(key, .backoff)`
/// - requeue:       `done(key, .backoff)`
/// - requeue_after: `done(key, .{ .requeue_after = ns })`
///
/// Supports both single-threaded (`run()`) and multi-threaded (`start()`/`stop()`)
/// operation.
pub const Reconciler = struct {
    allocator: std.mem.Allocator,
    queue: *WorkQueue,
    reconcile_fn: ReconcileFn,
    base_context: Context,
    reconcile_timeout_ns: ?u64,
    workers: std.ArrayList(std.Thread),
    max_concurrent_reconciles: u32,
    started: bool,
    metrics: ReconcilerMetrics,
    queue_metrics: QueueMetrics,
    logger: Logger = Logger.noop,

    pub const Options = struct {
        reconcile_fn: ReconcileFn,
        max_concurrent_reconciles: u32 = 1,
        reconcile_timeout_ns: ?u64 = null,
        metrics: ReconcilerMetrics = ReconcilerMetrics.noop,
        queue_metrics: QueueMetrics = QueueMetrics.noop,
        logger: Logger = Logger.noop,
    };

    /// Create a new reconciler bound to the given work queue.
    pub fn init(allocator: std.mem.Allocator, queue: *WorkQueue, ctx: Context, opts: Options) Reconciler {
        return .{
            .allocator = allocator,
            .queue = queue,
            .reconcile_fn = opts.reconcile_fn,
            .base_context = ctx,
            .reconcile_timeout_ns = opts.reconcile_timeout_ns,
            .workers = .empty,
            .max_concurrent_reconciles = opts.max_concurrent_reconciles,
            .started = false,
            .metrics = opts.metrics,
            .queue_metrics = opts.queue_metrics,
            .logger = opts.logger.withScope("reconciler"),
        };
    }

    /// Release the worker thread list. Must not be called while workers are running.
    pub fn deinit(self: *Reconciler) void {
        std.debug.assert(!self.started);
        self.workers.deinit(self.allocator);
    }

    /// Spawn `max_concurrent_reconciles` worker threads.
    pub fn start(self: *Reconciler) !void {
        std.debug.assert(!self.started);
        self.started = true;

        for (0..self.max_concurrent_reconciles) |_| {
            const thread = try std.Thread.spawn(.{}, workerLoop, .{self});
            self.workers.append(self.allocator, thread) catch {
                self.queue.shutdown();
                thread.join();
                for (self.workers.items) |prev| {
                    prev.join();
                }
                self.workers.clearRetainingCapacity();
                self.started = false;
                return error.OutOfMemory;
            };
        }
    }

    /// Signal the reconciler to stop (non-blocking).
    pub fn cancel(self: *Reconciler) void {
        self.queue.shutdown();
    }

    /// Wait for all worker threads to exit (blocking).
    pub fn join(self: *Reconciler) void {
        for (self.workers.items) |thread| {
            thread.join();
        }
        self.workers.clearRetainingCapacity();
        self.started = false;
    }

    /// Convenience: cancel + join.
    pub fn stop(self: *Reconciler) void {
        self.cancel();
        self.join();
    }

    /// Single-threaded reconcile loop. Blocks until the queue is shut down.
    pub fn run(self: *Reconciler) void {
        workerLoop(self);
    }

    fn workerLoop(self: *Reconciler) void {
        while (true) {
            const key = self.queue.get() catch |err| {
                self.logger.warn("work queue get failed", &.{
                    LogField.string("error", @errorName(err)),
                });
                continue;
            } orelse return; // null = shutdown

            // Default to .backoff so that panics/early-returns still
            // trigger rate-limited requeue rather than losing the key.
            var done_action: WorkQueue.DoneAction = .backoff;
            defer self.queue.done(key, done_action);

            self.metrics.active_workers.inc();
            defer self.metrics.active_workers.dec();

            self.metrics.reconcile_total.inc();
            const reconcile_start = std.time.Instant.now() catch null;

            self.logger.debug("reconcile dequeued", &.{
                LogField.string("namespace", key.namespace),
                LogField.string("name", key.name),
            });

            // Create per-reconcile context with optional timeout.
            const reconcile_ctx = if (self.reconcile_timeout_ns) |timeout_ns|
                self.base_context.withTimeout(timeout_ns)
            else
                self.base_context;

            const reconcile_ok = self.reconcile_fn.invoke(key, reconcile_ctx);

            // Record duration for both success and error.
            if (reconcile_start) |s| {
                if (std.time.Instant.now() catch null) |end| {
                    const dur_ns: f64 = @floatFromInt(end.since(s));
                    const dur_s = dur_ns / @as(f64, std.time.ns_per_s);
                    self.metrics.reconcile_duration.observe(dur_s);
                    self.queue_metrics.work_duration.observe(dur_s);
                }
            }

            if (reconcile_ok) |result| {
                if (result.requeue_after_ns > 0) {
                    self.logger.debug("requeue_after", &.{
                        LogField.string("namespace", key.namespace),
                        LogField.string("name", key.name),
                        LogField.uint("delay_ms", result.requeue_after_ns / std.time.ns_per_ms),
                    });
                    done_action = .{ .requeue_after = result.requeue_after_ns };
                } else if (result.requeue) {
                    self.logger.debug("requeue", &.{
                        LogField.string("namespace", key.namespace),
                        LogField.string("name", key.name),
                    });
                    done_action = .backoff;
                } else {
                    self.logger.debug("reconcile success", &.{
                        LogField.string("namespace", key.namespace),
                        LogField.string("name", key.name),
                    });
                    done_action = .success;
                }
            } else |err| {
                self.logger.warn("reconcile error", &.{
                    LogField.string("namespace", key.namespace),
                    LogField.string("name", key.name),
                    LogField.string("error", @errorName(err)),
                });
                self.metrics.reconcile_errors_total.inc();
                done_action = .backoff;
            }
        }
    }
};

test "Reconciler: single reconcile success" {
    // Arrange
    var q = WorkQueue.init(testing.allocator, .{});
    defer q.deinit();

    var count = std.atomic.Value(u32).init(0);

    const Ctx = struct {
        counter: *std.atomic.Value(u32),

        fn reconcile(self: *@This(), _: ObjectKey, _: Context) anyerror!Result {
            _ = self.counter.fetchAdd(1, .seq_cst);
            return .{};
        }
    };
    var ctx = Ctx{ .counter = &count };

    var r = Reconciler.init(testing.allocator, &q, Context.background(), .{
        .reconcile_fn = ReconcileFn.fromTypedCtx(Ctx, &ctx, Ctx.reconcile),
    });
    defer r.deinit();

    try q.add(.{ .namespace = "ns", .name = "pod-1" }, .{});

    const thread = try std.Thread.spawn(.{}, struct {
        fn run(wq: *WorkQueue) void {
            std.Thread.sleep(50 * std.time.ns_per_ms);
            wq.shutdown();
        }
    }.run, .{&q});

    // Act
    r.run();
    thread.join();

    // Assert
    try testing.expectEqual(@as(u32, 1), count.load(.seq_cst));
}

test "Reconciler: error triggers rate-limited requeue" {
    // Arrange
    var q = WorkQueue.init(testing.allocator, .{
        .retry_policy = .{
            .max_retries = std.math.maxInt(u32),
            .initial_backoff_ns = 1, // tiny backoff for testing
            .max_backoff_ns = 10,
            .backoff_multiplier = 2,
            .jitter = false,
        },
    });
    defer q.deinit();

    var count = std.atomic.Value(u32).init(0);

    const Ctx = struct {
        counter: *std.atomic.Value(u32),

        fn reconcile(self: *@This(), _: ObjectKey, _: Context) anyerror!Result {
            const prev = self.counter.fetchAdd(1, .seq_cst);
            if (prev == 0) return error.TransientFailure;
            return .{};
        }
    };
    var ctx = Ctx{ .counter = &count };

    var r = Reconciler.init(testing.allocator, &q, Context.background(), .{
        .reconcile_fn = ReconcileFn.fromTypedCtx(Ctx, &ctx, Ctx.reconcile),
    });
    defer r.deinit();

    try q.add(.{ .namespace = "ns", .name = "pod-1" }, .{});

    const thread = try std.Thread.spawn(.{}, struct {
        fn run(wq: *WorkQueue) void {
            std.Thread.sleep(200 * std.time.ns_per_ms);
            wq.shutdown();
        }
    }.run, .{&q});

    // Act
    r.run();
    thread.join();

    // Assert
    try testing.expectEqual(@as(u32, 2), count.load(.seq_cst));
}

test "Reconciler: requeue triggers rate-limited requeue" {
    // Arrange
    var q = WorkQueue.init(testing.allocator, .{
        .retry_policy = .{
            .max_retries = std.math.maxInt(u32),
            .initial_backoff_ns = 1,
            .max_backoff_ns = 10,
            .backoff_multiplier = 2,
            .jitter = false,
        },
    });
    defer q.deinit();

    var count = std.atomic.Value(u32).init(0);

    const Ctx = struct {
        counter: *std.atomic.Value(u32),

        fn reconcile(self: *@This(), _: ObjectKey, _: Context) anyerror!Result {
            const prev = self.counter.fetchAdd(1, .seq_cst);
            if (prev == 0) return .{ .requeue = true };
            return .{};
        }
    };
    var ctx = Ctx{ .counter = &count };

    var r = Reconciler.init(testing.allocator, &q, Context.background(), .{
        .reconcile_fn = ReconcileFn.fromTypedCtx(Ctx, &ctx, Ctx.reconcile),
    });
    defer r.deinit();

    try q.add(.{ .namespace = "ns", .name = "pod-1" }, .{});

    const thread = try std.Thread.spawn(.{}, struct {
        fn run(wq: *WorkQueue) void {
            std.Thread.sleep(200 * std.time.ns_per_ms);
            wq.shutdown();
        }
    }.run, .{&q});

    // Act
    r.run();
    thread.join();

    // Assert
    try testing.expectEqual(@as(u32, 2), count.load(.seq_cst));
}

test "Reconciler: requeue_after_ns triggers delayed requeue" {
    // Arrange
    var q = WorkQueue.init(testing.allocator, .{});
    defer q.deinit();

    var count = std.atomic.Value(u32).init(0);

    const Ctx = struct {
        counter: *std.atomic.Value(u32),

        fn reconcile(self: *@This(), _: ObjectKey, _: Context) anyerror!Result {
            const prev = self.counter.fetchAdd(1, .seq_cst);
            if (prev == 0) return .{ .requeue_after_ns = 1 }; // 1ns delay
            return .{};
        }
    };
    var ctx = Ctx{ .counter = &count };

    var r = Reconciler.init(testing.allocator, &q, Context.background(), .{
        .reconcile_fn = ReconcileFn.fromTypedCtx(Ctx, &ctx, Ctx.reconcile),
    });
    defer r.deinit();

    try q.add(.{ .namespace = "ns", .name = "pod-1" }, .{});

    const thread = try std.Thread.spawn(.{}, struct {
        fn run(wq: *WorkQueue) void {
            std.Thread.sleep(200 * std.time.ns_per_ms);
            wq.shutdown();
        }
    }.run, .{&q});

    // Act
    r.run();
    thread.join();

    // Assert
    try testing.expectEqual(@as(u32, 2), count.load(.seq_cst));
}

test "Reconciler: multiple workers process concurrently" {
    // Arrange
    var q = WorkQueue.init(testing.allocator, .{});
    defer q.deinit();

    var processed_count = std.atomic.Value(u32).init(0);

    const Ctx = struct {
        counter: *std.atomic.Value(u32),

        fn reconcile(self: *@This(), _: ObjectKey, _: Context) anyerror!Result {
            _ = self.counter.fetchAdd(1, .seq_cst);
            return .{};
        }
    };
    var ctx = Ctx{ .counter = &processed_count };

    var r = Reconciler.init(testing.allocator, &q, Context.background(), .{
        .reconcile_fn = ReconcileFn.fromTypedCtx(Ctx, &ctx, Ctx.reconcile),
        .max_concurrent_reconciles = 4,
    });
    defer r.deinit();

    try q.add(.{ .namespace = "ns", .name = "a" }, .{});
    try q.add(.{ .namespace = "ns", .name = "b" }, .{});
    try q.add(.{ .namespace = "ns", .name = "c" }, .{});
    try q.add(.{ .namespace = "ns", .name = "d" }, .{});

    // Act
    try r.start();
    std.Thread.sleep(100 * std.time.ns_per_ms);
    r.stop();

    // Assert
    try testing.expectEqual(@as(u32, 4), processed_count.load(.seq_cst));
}

test "Reconciler: stop unblocks idle workers" {
    // Arrange
    var q = WorkQueue.init(testing.allocator, .{});
    defer q.deinit();

    const Ctx = struct {
        fn reconcile(_: ObjectKey, _: Context) anyerror!Result {
            return .{};
        }
    };

    var r = Reconciler.init(testing.allocator, &q, Context.background(), .{
        .reconcile_fn = ReconcileFn.fromFn(Ctx.reconcile),
        .max_concurrent_reconciles = 2,
    });
    defer r.deinit();

    // Act
    // Start with an empty queue so workers immediately block on get().
    try r.start();

    // Assert
    // Stopping should shut down the queue and unblock all workers.
    std.Thread.sleep(10 * std.time.ns_per_ms);
    r.stop();
}

test "Reconciler: run works single-threaded" {
    // Arrange
    var q = WorkQueue.init(testing.allocator, .{});
    defer q.deinit();

    var count = std.atomic.Value(u32).init(0);

    const Ctx = struct {
        counter: *std.atomic.Value(u32),

        fn reconcile(self: *@This(), _: ObjectKey, _: Context) anyerror!Result {
            _ = self.counter.fetchAdd(1, .seq_cst);
            return .{};
        }
    };
    var ctx = Ctx{ .counter = &count };

    var r = Reconciler.init(testing.allocator, &q, Context.background(), .{
        .reconcile_fn = ReconcileFn.fromTypedCtx(Ctx, &ctx, Ctx.reconcile),
    });
    defer r.deinit();

    try q.add(.{ .namespace = "ns", .name = "pod-1" }, .{});

    const thread = try std.Thread.spawn(.{}, struct {
        fn run(wq: *WorkQueue) void {
            std.Thread.sleep(50 * std.time.ns_per_ms);
            wq.shutdown();
        }
    }.run, .{&q});

    // Act
    r.run();
    thread.join();

    // Assert
    try testing.expectEqual(@as(u32, 1), count.load(.seq_cst));
}

test "Reconciler: ReconcileFn.fromFn works" {
    // Arrange
    var q = WorkQueue.init(testing.allocator, .{});
    defer q.deinit();

    var invoked = std.atomic.Value(u32).init(0);

    // We need to use a comptime-known function, so we use a struct with a global.
    const Helper = struct {
        var global_invoked: *std.atomic.Value(u32) = undefined;

        fn reconcile(_: ObjectKey, _: Context) anyerror!Result {
            _ = global_invoked.fetchAdd(1, .seq_cst);
            return .{};
        }
    };
    Helper.global_invoked = &invoked;

    var r = Reconciler.init(testing.allocator, &q, Context.background(), .{
        .reconcile_fn = ReconcileFn.fromFn(Helper.reconcile),
    });
    defer r.deinit();

    try q.add(.{ .namespace = "ns", .name = "pod-1" }, .{});

    const thread = try std.Thread.spawn(.{}, struct {
        fn run(wq: *WorkQueue) void {
            std.Thread.sleep(50 * std.time.ns_per_ms);
            wq.shutdown();
        }
    }.run, .{&q});

    // Act
    r.run();
    thread.join();

    // Assert
    try testing.expectEqual(@as(u32, 1), invoked.load(.seq_cst));
}

test "Reconciler: start joins all threads on partial failure" {
    // Arrange
    var fa = std.testing.FailingAllocator.init(testing.allocator, .{});
    var q = WorkQueue.init(testing.allocator, .{});
    defer {
        q.shutdown();
        q.deinit();
    }

    const Ctx = struct {
        fn reconcile(_: ObjectKey, _: Context) anyerror!Result {
            return .{};
        }
    };

    var r = Reconciler.init(fa.allocator(), &q, Context.background(), .{
        .reconcile_fn = ReconcileFn.fromFn(Ctx.reconcile),
        .max_concurrent_reconciles = 3,
    });
    defer r.deinit();

    // Pre-allocate 2 slots; the third append triggers growth which OOMs.
    try r.workers.ensureTotalCapacityPrecise(fa.allocator(), 2);
    fa.fail_index = fa.alloc_index;
    fa.resize_fail_index = fa.resize_index;

    // Act
    try testing.expectError(error.OutOfMemory, r.start());

    // Assert
    // All previously-spawned threads must have been joined and cleared.
    try testing.expect(!r.started);
    try testing.expectEqual(@as(usize, 0), r.workers.items.len);
}

test "Reconciler: persistent error keeps requeuing until shutdown" {
    // Arrange
    var q = WorkQueue.init(testing.allocator, .{
        .retry_policy = .{
            .max_retries = std.math.maxInt(u32),
            .initial_backoff_ns = 1,
            .max_backoff_ns = 10,
            .backoff_multiplier = 2,
            .jitter = false,
        },
    });
    defer q.deinit();

    var count = std.atomic.Value(u32).init(0);

    const Ctx = struct {
        counter: *std.atomic.Value(u32),

        fn reconcile(self: *@This(), _: ObjectKey, _: Context) anyerror!Result {
            _ = self.counter.fetchAdd(1, .seq_cst);
            return error.PersistentFailure;
        }
    };
    var ctx = Ctx{ .counter = &count };

    var r = Reconciler.init(testing.allocator, &q, Context.background(), .{
        .reconcile_fn = ReconcileFn.fromTypedCtx(Ctx, &ctx, Ctx.reconcile),
    });
    defer r.deinit();

    try q.add(.{ .namespace = "ns", .name = "pod-1" }, .{});

    const thread = try std.Thread.spawn(.{}, struct {
        fn run(wq: *WorkQueue) void {
            std.Thread.sleep(100 * std.time.ns_per_ms);
            wq.shutdown();
        }
    }.run, .{&q});

    // Act
    r.run();
    thread.join();

    // Assert
    try testing.expect(count.load(.seq_cst) >= 2);
}
