//! Rate-limited work queue for reconcile keys.
//!
//! Sits between an `Informer` and a `Reconciler`, deduplicating `ObjectKey`
//! values, tracking processing state via the dirty/processing/queue three-set
//! model, and providing rate-limited re-enqueue with exponential backoff.
//! Thread-safe: all public methods are guarded by a mutex with condition
//! variable signaling for blocking `get()`.

const std = @import("std");
const logging = @import("../util/logging.zig");
const Logger = logging.Logger;
const LogField = logging.Field;
const object_key_mod = @import("../object_key.zig");
const ObjectKey = object_key_mod.ObjectKey;
const ObjectKeyContext = object_key_mod.ObjectKeyContext;
const informer_mod = @import("../cache/informer.zig");
const EventHandler = informer_mod.EventHandler;
const RetryPolicy = @import("../util/retry.zig").RetryPolicy;
const time_util = @import("../util/time.zig");
const RingQueue = @import("../util/ring_queue.zig").RingQueue;
const QueueMetrics = @import("../util/metrics.zig").QueueMetrics;
const rate_limit_mod = @import("../util/rate_limit.zig");
const RateLimiter = rate_limit_mod.RateLimiter;
const predicates_mod = @import("../cache/predicates.zig");
const backoff_mod = @import("backoff_scheduler.zig");
const BackoffScheduler = backoff_mod.BackoffScheduler;
const testing = std.testing;

/// Deduplicating, rate-limited work queue following the three-set model.
///
/// Sits between an Informer and a Reconciler. Receives `ObjectKey` values from
/// informer event handlers, deduplicates them, tracks processing state, and
/// provides rate-limited re-enqueue for failed reconciliations.
///
/// Thread-safe: all public methods are guarded by a mutex. `get()` blocks via
/// a condition variable when the queue is empty and wakes when items arrive or
/// the queue shuts down.
///
/// Memory ownership: the queue clones all `ObjectKey` strings into its own
/// allocator on `add()` and frees them on removal, preventing use-after-free
/// when informer arenas are recycled.
pub const WorkQueue = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    shut_down: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// FIFO of keys waiting to be processed (array-backed ring buffer for O(1) push/pop
    /// with amortized growth and cache-friendly layout).
    queue: RingQueue(ObjectKey) = .{},
    /// All keys that need processing (superset of queue; includes processing).
    dirty: KeySet = .empty,
    /// Keys currently being worked on by a consumer.
    processing: KeySet = .empty,
    /// Backoff scheduling subsystem: manages waiting heap, failure counts,
    /// rate limiter, and deferred item tracking.
    scheduler: BackoffScheduler,

    epoch: std.time.Instant,
    metrics: QueueMetrics,
    logger: Logger = Logger.noop,
    /// Enqueue timestamps for queue latency measurement.
    enqueue_times: EnqueueTimeMap = .empty,

    const EnqueueTimeMap = std.HashMapUnmanaged(
        ObjectKey,
        std.time.Instant,
        ObjectKeyContext,
        std.hash_map.default_max_load_percentage,
    );

    const KeySet = std.HashMapUnmanaged(
        ObjectKey,
        void,
        ObjectKeyContext,
        std.hash_map.default_max_load_percentage,
    );

    /// Captures pending metrics operations so they can be flushed after
    /// releasing the mutex. This prevents deadlocks when a custom metrics
    /// provider acquires its own lock.
    const MetricsAction = struct {
        set_depth: ?f64 = null,
        inc_adds: bool = false,
        inc_retries: bool = false,
        observe_latency: ?f64 = null,

        fn apply(self: MetricsAction, m: QueueMetrics) void {
            if (self.inc_adds) m.adds_total.inc();
            if (self.inc_retries) m.retries_total.inc();
            if (self.set_depth) |d| m.depth.set(d);
            if (self.observe_latency) |l| m.queue_latency.observe(l);
        }
    };

    /// Error type for fallible queue operations.
    pub const Error = error{ OutOfMemory, Overflow };

    /// Action to take when completing a key via `done()`.
    ///
    /// Folding the requeue intent into `done()` makes the decision atomic
    /// (single lock acquisition), preventing races where watch events set
    /// the dirty flag between separate `addAfter()`/`addRateLimited()` and
    /// `done()` calls.
    pub const DoneAction = union(enum) {
        /// Success: clears backoff state. If dirty, re-enqueues immediately.
        success,
        /// Fixed delay: clears backoff state. Dirty flag is absorbed by the delay.
        requeue_after: u64,
        /// Exponential backoff: increments the failure counter. Dirty flag is absorbed.
        backoff,
    };

    /// Options for `add()`.
    pub const AddOptions = struct {
        /// When true, skip enqueue if the key is already in the waiting
        /// heap (from `done(.requeue_after)`, `addAfter`, or `addRateLimited`).
        /// The dirty flag is still set so the key will be processed when
        /// the waiting entry expires. This prevents echo events from
        /// bypassing intended delays.
        defer_to_waiting: bool = false,
    };

    pub const Options = struct {
        /// Maximum number of items the ring queue can hold. Prevents
        /// unbounded memory growth under adversarial workloads.
        max_queue_size: usize = 65_536,
        /// Maximum number of items in the waiting heap (rate-limited and
        /// delayed items). Prevents unbounded growth when many unique keys
        /// are rate-limited simultaneously.
        max_waiting_size: usize = 65_536,
        retry_policy: RetryPolicy = .{
            .max_retries = std.math.maxInt(u32),
            .initial_backoff_ns = 5 * std.time.ns_per_ms,
            .max_backoff_ns = 1000 * std.time.ns_per_s,
            .backoff_multiplier = 2,
            .jitter = true,
        },
        /// Global token-bucket rate limit applied to rate-limited requeues
        /// (addRateLimited / done(.backoff)). The actual delay is
        /// max(per_key_backoff, bucket_delay). Defaults to 10 QPS / 100 burst,
        /// Defaults to 10 QPS / 100 burst. Set to
        /// `RateLimiter.Config.disabled` to disable.
        overall_rate_limit: RateLimiter.Config = .{ .qps = 10.0, .burst = 100 },
        metrics: QueueMetrics = QueueMetrics.noop,
        logger: Logger = Logger.noop,
    };

    /// Create a new work queue with the given options.
    pub fn init(allocator: std.mem.Allocator, opts: Options) WorkQueue {
        const epoch = std.time.Instant.now() catch @panic("monotonic clock required");
        return .{
            .allocator = allocator,
            .queue = .{ .max_capacity = opts.max_queue_size },
            .scheduler = BackoffScheduler.init(allocator, epoch, .{
                .max_size = opts.max_waiting_size,
                .retry_policy = opts.retry_policy,
                .overall_rate_limit = opts.overall_rate_limit,
                .logger = opts.logger.withScope("work_queue"),
            }),
            .epoch = epoch,
            .metrics = opts.metrics,
            .logger = opts.logger.withScope("work_queue"),
        };
    }

    /// Release all resources owned by the queue.
    ///
    /// **Contract:** the caller MUST call `shutdown()` and join all consumer
    /// threads before calling `deinit()`. Failure to do so causes a panic
    /// in all build modes: consumers would access freed memory otherwise.
    pub fn deinit(self: *WorkQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Callers must call shutdown() and join consumer threads before
        // deinit(). Blocked consumers would access freed memory otherwise.
        // Use an unconditional check instead of std.debug.assert, which
        // is elided in ReleaseFast/ReleaseSmall builds.
        if (!self.shut_down.raw) @panic("WorkQueue.deinit() called without shutdown()");

        // Free enqueue_times map first because its keys are aliases to keys
        // in queue/dirty (not independently owned). Releasing the map
        // storage before freeing those keys avoids dangling references.
        self.enqueue_times.deinit(self.allocator);

        // Free keys in processing (always disjoint from dirty).
        var proc_it = self.processing.iterator();
        while (proc_it.next()) |entry| {
            self.freeKey(entry.key_ptr.*);
        }
        self.processing.deinit(self.allocator);

        // Free keys from queue, removing each from dirty as we go.
        // If dirty held a different allocation for the same logical key
        // (e.g. after done() re-queued), free that separately.
        for (0..self.queue.count) |i| {
            const key = self.queue.items[(self.queue.head + i) % self.queue.items.len];
            const removed = self.dirty.fetchRemove(key);
            if (removed) |kv| {
                if (kv.key.namespace.ptr != key.namespace.ptr or kv.key.name.ptr != key.name.ptr) {
                    self.freeKey(kv.key);
                }
            }
            self.freeKey(key);
        }
        self.queue.deinit(self.allocator);

        // Free any remaining dirty keys not covered above (e.g. a key
        // re-added while processing that hasn't been moved to queue yet).
        var dirty_it = self.dirty.iterator();
        while (dirty_it.next()) |entry| {
            self.freeKey(entry.key_ptr.*);
        }
        self.dirty.deinit(self.allocator);

        self.scheduler.deinit();
    }

    // Core operations
    /// Enqueue a key for processing. Deduplicates: if the key is already
    /// queued or being processed, this is a no-op (but marks it dirty so
    /// it will be re-queued after `done()`).
    ///
    /// With `.defer_to_waiting = true`, the key is not pushed to the
    /// active queue when it is already in the waiting heap; the dirty
    /// flag is set so it will be processed when the delay expires. Use
    /// this to prevent echo events from bypassing intended delays.
    pub fn add(self: *WorkQueue, key: ObjectKey, opts: AddOptions) Error!void {
        var ma: MetricsAction = .{};
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            try self.addLocked(key, opts.defer_to_waiting, &ma);
        }
        ma.apply(self.metrics);
    }

    /// Blocking dequeue. Returns the next key to process, or null if the
    /// queue has been shut down. Moves expired waiting items into the active
    /// queue when the main queue is empty.
    pub fn get(self: *WorkQueue) Error!?ObjectKey {
        var ma: MetricsAction = .{};
        const key = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            break :blk try self.getLocked(&ma);
        };
        ma.apply(self.metrics);
        return key;
    }

    fn getLocked(self: *WorkQueue, ma: *MetricsAction) Error!?ObjectKey {
        while (true) {
            if (self.shut_down.raw) return null;

            if (self.queue.count > 0) {
                // Ensure processing has capacity before popping. If this fails,
                // the key stays in the queue and OOM propagates without data loss.
                try self.processing.ensureUnusedCapacity(self.allocator, 1);
                const key = self.queuePop();
                const removed = self.dirty.fetchRemove(key);
                if (removed) |kv| {
                    // dirty may hold a different allocation than queue for
                    // the same logical key (e.g. after done() re-queues).
                    // If the pointers differ, free the dirty copy.
                    if (kv.key.namespace.ptr != key.namespace.ptr or kv.key.name.ptr != key.name.ptr) {
                        self.freeKey(kv.key);
                    }
                }
                self.processing.putAssumeCapacity(key, {});
                // Measure queue latency (time from add to get).
                if (self.enqueue_times.fetchRemove(key)) |kv| {
                    if (std.time.Instant.now() catch null) |now| {
                        const wait_ns: f64 = @floatFromInt(now.since(kv.value));
                        ma.observe_latency = wait_ns / @as(f64, std.time.ns_per_s);
                    }
                }
                ma.set_depth = @floatFromInt(self.queue.count);
                return key;
            }

            // Queue is empty, so promote any expired waiting items.
            self.promoteExpiredWaiting();
            if (self.queue.count > 0) continue;

            if (self.shut_down.raw) return null;

            // If there are waiting items, sleep until the earliest one expires.
            if (self.scheduler.heap.peek()) |earliest| {
                const now = time_util.monotonicNowNs(self.epoch) catch {
                    // Clock unavailable: use a short polling interval instead.
                    self.cond.timedWait(&self.mutex, 10 * std.time.ns_per_ms) catch {};
                    continue;
                };
                if (earliest.not_before > now) {
                    self.cond.timedWait(&self.mutex, earliest.not_before - now) catch {};
                }
                continue;
            }

            // Nothing to do; wait for add() or shutdown().
            self.cond.wait(&self.mutex);
        }
    }

    /// Mark a key as done processing. The `action` parameter controls what
    /// happens next, all in a single lock acquisition to prevent races
    /// between watch events setting the dirty flag and requeue logic:
    ///
    /// - `.success`: if dirty, immediate re-enqueue; otherwise clean up.
    /// - `.{ .requeue_after = ns }`: absorb dirty flag, delay re-enqueue.
    /// - `.backoff`: absorb dirty flag, exponential backoff re-enqueue.
    ///
    /// The key is always consumed: callers must not use it after this call.
    pub fn done(self: *WorkQueue, key: ObjectKey, action: DoneAction) void {
        var ma: MetricsAction = .{};
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.doneLocked(key, action, &ma);
        }
        ma.apply(self.metrics);
    }

    fn doneLocked(self: *WorkQueue, key: ObjectKey, action: DoneAction, ma: *MetricsAction) void {
        // done() must only be called once per get(). A second call reads
        // freed memory during hash lookup. The runtime guard below fires
        // in all build modes, logging the bug and returning safely.
        const was_processing = self.processing.remove(key);
        if (!was_processing) {
            self.logger.err("done() called on key not in processing set (double-done bug)", &.{});
            return;
        }

        switch (action) {
            .success => self.doneSuccess(key, ma),
            .requeue_after => |delay_ns| self.doneRequeueAfter(key, delay_ns, ma),
            .backoff => self.doneBackoff(key, ma),
        }
    }

    /// `.success`: if dirty, re-enqueue immediately (external change during
    /// processing); otherwise clean up failures and free key.
    fn doneSuccess(self: *WorkQueue, key: ObjectKey, ma: *MetricsAction) void {
        if (self.dirty.contains(key)) {
            // Key was re-added while processing; move it back to queue.
            self.queuePush(key) catch {
                // OOM on re-queue: clean up both allocations and drop the
                // item. The informer will re-deliver the key if needed.
                const removed = self.dirty.fetchRemove(key);
                if (removed) |kv| {
                    if (kv.key.namespace.ptr != key.namespace.ptr or kv.key.name.ptr != key.name.ptr) {
                        self.freeKey(kv.key);
                    }
                }
                self.scheduler.cleanupOrphan(key);
                self.freeKey(key);
                ma.set_depth = @floatFromInt(self.queue.count);
                self.logger.warn("done: OOM re-queuing dirty key, item dropped", &.{});
                return;
            };
            ma.set_depth = @floatFromInt(self.queue.count);
            self.cond.signal();
        } else {
            self.scheduler.cleanupOrphan(key);
            self.freeKey(key);
            ma.set_depth = @floatFromInt(self.queue.count);
        }
    }

    /// `.requeue_after`: absorb dirty flag, clear failures, delay re-enqueue.
    /// If delay_ns == 0, push to active queue immediately.
    fn doneRequeueAfter(self: *WorkQueue, key: ObjectKey, delay_ns: u64, ma: *MetricsAction) void {
        // Clear dirty flag; the explicit requeue absorbs any pending changes.
        self.clearDirtyClone(key);

        // Clear failures entry (requeue_after resets backoff state).
        self.scheduler.clearFailures(key);

        if (delay_ns == 0) {
            // Immediate requeue: push to active queue.
            self.queuePush(key) catch {
                self.freeKey(key);
                ma.set_depth = @floatFromInt(self.queue.count);
                self.logger.warn("done(.requeue_after(0)): OOM on queue push, item dropped", &.{});
                return;
            };
            // Re-add to dirty set so get() can consume it.
            self.dirty.put(self.allocator, key, {}) catch {
                self.logger.warn("done(.requeue_after(0)): OOM on dirty.put, proceeding", &.{});
            };
            ma.set_depth = @floatFromInt(self.queue.count);
            ma.inc_retries = true;
            self.cond.signal();
            return;
        }

        // Non-zero delay: delegate to scheduler.
        switch (self.scheduler.scheduleRequeueAfter(key, delay_ns)) {
            .scheduled => {
                ma.set_depth = @floatFromInt(self.queue.count);
                ma.inc_retries = true;
                self.cond.signal();
            },
            .already_waiting => {
                self.freeKey(key);
                ma.set_depth = @floatFromInt(self.queue.count);
            },
            .full, .oom, .clock_unavailable => {
                // Fall back to active queue push.
                self.queuePush(key) catch {
                    self.freeKey(key);
                    ma.set_depth = @floatFromInt(self.queue.count);
                    self.logger.warn("done(.requeue_after): fallback queue push failed, item dropped", &.{});
                    return;
                };
                self.dirty.put(self.allocator, key, {}) catch {
                    self.logger.warn("done(.requeue_after): OOM on dirty.put fallback, proceeding", &.{});
                };
                ma.set_depth = @floatFromInt(self.queue.count);
                ma.inc_retries = true;
                self.cond.signal();
            },
        }
    }

    /// `.backoff`: absorb dirty flag, calculate exponential backoff,
    /// add to waiting heap. Increments failure counter only after all
    /// fallible operations succeed.
    fn doneBackoff(self: *WorkQueue, key: ObjectKey, ma: *MetricsAction) void {
        // Clear dirty flag; the backoff requeue absorbs any pending changes.
        self.clearDirtyClone(key);

        switch (self.scheduler.scheduleBackoff(key)) {
            .scheduled => {
                ma.inc_retries = true;
                ma.set_depth = @floatFromInt(self.queue.count);
                self.freeKey(key);
                self.cond.signal();
            },
            .already_waiting => {
                self.freeKey(key);
                ma.set_depth = @floatFromInt(self.queue.count);
            },
            .full => {
                self.freeKey(key);
                ma.set_depth = @floatFromInt(self.queue.count);
                self.logger.warn("done(.backoff): waiting heap full, item dropped", &.{});
            },
            .oom => {
                self.freeKey(key);
                ma.set_depth = @floatFromInt(self.queue.count);
                self.logger.warn("done(.backoff): OOM, item dropped", &.{});
            },
            .clock_unavailable => {
                self.freeKey(key);
                ma.set_depth = @floatFromInt(self.queue.count);
                self.logger.warn("done(.backoff): clock unavailable, item dropped", &.{});
            },
        }
    }

    /// Remove the key from the dirty set and free the dirty clone if it
    /// is a separate allocation from the processing key.
    fn clearDirtyClone(self: *WorkQueue, key: ObjectKey) void {
        const removed = self.dirty.fetchRemove(key);
        if (removed) |kv| {
            if (kv.key.namespace.ptr != key.namespace.ptr or kv.key.name.ptr != key.name.ptr) {
                self.freeKey(kv.key);
            }
        }
    }

    // Rate-limited operations
    /// Re-enqueue a key with exponential backoff. Increments the failure
    /// counter and delays the re-enqueue based on the retry policy.
    pub fn addRateLimited(self: *WorkQueue, key: ObjectKey) Error!void {
        var ma: MetricsAction = .{};
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.shut_down.raw) return;
            self.scheduler.scheduleRateLimited(key) catch |err| switch (err) {
                error.ClockUnavailable => {
                    self.logger.warn("addRateLimited: clock unavailable, falling back to immediate add", &.{});
                    try self.addLocked(key, false, &ma);
                    return;
                },
                error.OutOfMemory => return error.OutOfMemory,
                error.Overflow => return error.Overflow,
            };
            ma.inc_retries = true;
            self.cond.signal();
        }
        ma.apply(self.metrics);
    }

    /// Enqueue a key after a fixed delay without touching the failure counter.
    /// Use for "requeue after X" semantics (fixed delay, no backoff accumulation).
    /// If delay_ns is 0, adds immediately (equivalent to add()).
    pub fn addAfter(self: *WorkQueue, key: ObjectKey, delay_ns: u64) Error!void {
        var ma: MetricsAction = .{};
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.shut_down.raw) return;
            if (delay_ns == 0) {
                try self.addLocked(key, false, &ma);
                return;
            }
            self.scheduler.scheduleAfter(key, delay_ns) catch |err| switch (err) {
                error.ClockUnavailable => {
                    self.logger.warn("addAfter: clock unavailable, falling back to immediate add", &.{});
                    try self.addLocked(key, false, &ma);
                    return;
                },
                error.OutOfMemory => return error.OutOfMemory,
                error.Overflow => return error.Overflow,
            };
            self.cond.signal();
        }
        ma.apply(self.metrics);
    }

    /// Reset the failure counter for a key. Call this after a successful
    /// reconciliation to clear the backoff state.
    pub fn forget(self: *WorkQueue, key: ObjectKey) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.scheduler.forget(key);
    }

    /// Get the number of times a key has been re-queued via `addRateLimited`.
    pub fn numRequeues(self: *WorkQueue, key: ObjectKey) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.scheduler.numRequeues(key);
    }

    // Inspection & control
    /// Number of items waiting in the queue (excludes items being processed
    /// and rate-limited items waiting for their backoff).
    pub fn len(self: *WorkQueue) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.queue.count;
    }

    /// Signal shutdown. Unblocks all `get()` callers (they return null).
    /// Items added after shutdown are silently dropped.
    pub fn shutdown(self: *WorkQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.shut_down.store(true, .release);
        self.cond.broadcast();
    }

    /// Returns true if `shutdown()` has been called.
    pub fn isShutdown(self: *WorkQueue) bool {
        return self.shut_down.load(.acquire);
    }

    // Informer integration
    /// Returns an `EventHandler(T)` that extracts `ObjectKey` from each
    /// event and enqueues it with `defer_to_waiting = true`.
    ///
    /// Update events are filtered through `generationChanged`: status-only
    /// updates (which don't bump `.metadata.generation`) are suppressed,
    /// preventing reconcile storms caused by the reconciler's own mutations
    /// echoing back as watch events. If `T` has no `metadata.generation`
    /// field, all updates pass through (safe default).
    ///
    /// Use `rawEventHandler` when you need every event without filtering.
    ///
    /// Usage:
    /// ```zig
    /// try informer.addEventHandler(queue.eventHandler(k8s.CoreV1Pod));
    /// ```
    pub fn eventHandler(self: *WorkQueue, comptime T: type) EventHandler(T) {
        const gen_pred = comptime predicates_mod.generationChanged(T);
        return EventHandler(T).fromTypedCtx(WorkQueue, self, .{
            .on_add = struct {
                fn f(q: *WorkQueue, obj: *const T, _: bool) void {
                    const key = ObjectKey.fromResource(T, obj.*) orelse return;
                    q.add(key, .{ .defer_to_waiting = true }) catch |err| {
                        q.logger.warn("eventHandler on_add: failed to enqueue", &.{
                            LogField.string("error", @errorName(err)),
                        });
                    };
                }
            }.f,
            .on_update = struct {
                fn f(q: *WorkQueue, old: *const T, new: *const T) void {
                    if (!gen_pred(old, new)) return;
                    const key = ObjectKey.fromResource(T, new.*) orelse return;
                    q.add(key, .{ .defer_to_waiting = true }) catch |err| {
                        q.logger.warn("eventHandler on_update: failed to enqueue", &.{
                            LogField.string("error", @errorName(err)),
                        });
                    };
                }
            }.f,
            .on_delete = struct {
                fn f(q: *WorkQueue, obj: *const T) void {
                    const key = ObjectKey.fromResource(T, obj.*) orelse return;
                    q.add(key, .{ .defer_to_waiting = true }) catch |err| {
                        q.logger.warn("eventHandler on_delete: failed to enqueue", &.{
                            LogField.string("error", @errorName(err)),
                        });
                    };
                }
            }.f,
        });
    }

    /// Returns an unfiltered `EventHandler(T)` that enqueues every event
    /// immediately. No predicate filtering, no deference to the waiting
    /// heap. Use when you need full control or supply your own predicates
    /// via `predicates.FilteredState`.
    pub fn rawEventHandler(self: *WorkQueue, comptime T: type) EventHandler(T) {
        return EventHandler(T).fromTypedCtx(WorkQueue, self, .{
            .on_add = struct {
                fn f(q: *WorkQueue, obj: *const T, _: bool) void {
                    const key = ObjectKey.fromResource(T, obj.*) orelse return;
                    q.add(key, .{}) catch |err| {
                        q.logger.warn("rawEventHandler on_add: failed to enqueue", &.{
                            LogField.string("error", @errorName(err)),
                        });
                    };
                }
            }.f,
            .on_update = struct {
                fn f(q: *WorkQueue, _: *const T, new: *const T) void {
                    const key = ObjectKey.fromResource(T, new.*) orelse return;
                    q.add(key, .{}) catch |err| {
                        q.logger.warn("rawEventHandler on_update: failed to enqueue", &.{
                            LogField.string("error", @errorName(err)),
                        });
                    };
                }
            }.f,
            .on_delete = struct {
                fn f(q: *WorkQueue, obj: *const T) void {
                    const key = ObjectKey.fromResource(T, obj.*) orelse return;
                    q.add(key, .{}) catch |err| {
                        q.logger.warn("rawEventHandler on_delete: failed to enqueue", &.{
                            LogField.string("error", @errorName(err)),
                        });
                    };
                }
            }.f,
        });
    }

    fn addLocked(self: *WorkQueue, key: ObjectKey, defer_to_waiting: bool, ma: *MetricsAction) Error!void {
        if (self.shut_down.raw) return;

        // Already dirty: either queued or being processed. If processing,
        // done() will re-queue it.
        if (self.dirty.contains(key)) return;

        // Check waiting_keys BEFORE cloning/setting dirty. When the key
        // is waiting for a scheduled delay and is not being processed,
        // skip entirely. The waiting entry will promote it via
        // addLockedFromWaiting() when the delay expires. This avoids
        // allocating a clone only to undo it, and keeps dirty free of
        // orphaned entries that addLockedFromWaiting() would have to
        // handle specially.
        if (defer_to_waiting and self.scheduler.containsKey(key) and !self.processing.contains(key)) {
            return;
        }

        const owned_key = self.cloneKey(key) catch return error.OutOfMemory;

        self.dirty.put(self.allocator, owned_key, {}) catch {
            self.freeKey(owned_key);
            return error.OutOfMemory;
        };

        if (self.processing.contains(key)) {
            // Currently being processed; dirty flag ensures re-queue on done().
            return;
        }

        self.queuePush(owned_key) catch |err| {
            _ = self.dirty.remove(owned_key);
            self.freeKey(owned_key);
            return err;
        };
        ma.inc_adds = true;
        ma.set_depth = @floatFromInt(self.queue.count);
        // Record enqueue time for latency tracking.
        if (std.time.Instant.now() catch null) |now| {
            self.enqueue_times.put(self.allocator, owned_key, now) catch {
                self.logger.warn("addLocked: OOM recording enqueue time, latency metric may be inaccurate", &.{});
            };
        }
        self.cond.signal();
    }

    /// Move waiting items whose deadline has passed into the active queue.
    /// Processes at most `batch_limit` items per call to bound lock hold time;
    /// the caller re-invokes if the queue is still empty. A larger batch
    /// reduces lock churn at the cost of slightly longer lock hold times.
    fn promoteExpiredWaiting(self: *WorkQueue) void {
        const batch_limit: usize = 256;
        const now = time_util.monotonicNowNs(self.epoch) catch {
            self.logger.warn("promoteExpiredWaiting: clock unavailable, skipping promotion cycle", &.{});
            return;
        };
        var buf: [256]BackoffScheduler.WaitingItem = undefined;
        const expired = self.scheduler.drainExpired(now, buf[0..batch_limit]);
        for (expired) |item| {
            if (item.owned) {
                // Key is independently owned (from addAfter); reuse directly.
                self.addLockedFromWaiting(item.key);
            } else {
                // Key is owned by the failures map; clone for addLockedFromWaiting.
                const owned_key = BackoffScheduler.cloneKey(self.allocator, item.key) catch {
                    // OOM: re-insert into waiting with a short retry delay.
                    const retry_delay = 10 * std.time.ns_per_ms;
                    self.scheduler.reinsertWithDelay(item, retry_delay);
                    continue;
                };
                self.addLockedFromWaiting(owned_key);
            }
        }
    }

    /// Add a key from the waiting list. The key is already owned; if
    /// deduplication means we don't need it, free it.
    fn addLockedFromWaiting(self: *WorkQueue, owned_key: ObjectKey) void {
        if (self.shut_down.raw) {
            self.freeKey(owned_key);
            return;
        }

        if (self.dirty.contains(owned_key)) {
            // Already queued or being processed; free the waiting copy.
            self.freeKey(owned_key);
            return;
        }

        // Use the owned_key directly (no extra clone needed).
        self.dirty.put(self.allocator, owned_key, {}) catch {
            self.logger.warn("addLockedFromWaiting: OOM adding key to dirty set, item dropped", &.{});
            self.scheduler.cleanupOrphan(owned_key);
            self.freeKey(owned_key);
            return;
        };

        if (self.processing.contains(owned_key)) {
            return;
        }

        self.queuePush(owned_key) catch {
            self.logger.warn("addLockedFromWaiting: failed to push to queue, item dropped", &.{});
            _ = self.dirty.remove(owned_key);
            self.scheduler.cleanupOrphan(owned_key);
            self.freeKey(owned_key);
            return;
        };
        self.cond.signal();
    }

    fn queuePush(self: *WorkQueue, key: ObjectKey) error{ OutOfMemory, Overflow }!void {
        self.queue.push(self.allocator, key) catch |err| {
            if (err == error.Overflow) {
                self.logger.warn("queue capacity limit reached", &.{
                    LogField.uint("max_capacity", @intCast(self.queue.max_capacity)),
                });
            }
            return err;
        };
    }

    fn queuePop(self: *WorkQueue) ObjectKey {
        return self.queue.pop().?;
    }

    fn cloneKey(self: *WorkQueue, key: ObjectKey) error{OutOfMemory}!ObjectKey {
        return BackoffScheduler.cloneKey(self.allocator, key);
    }

    fn freeKey(self: *WorkQueue, key: ObjectKey) void {
        BackoffScheduler.freeKey(self.allocator, key);
    }
};

test "WorkQueue: add and get single item" {
    // Arrange
    var q = WorkQueue.init(testing.allocator, .{});
    defer {
        q.shutdown();
        q.deinit();
    }

    // Act
    try q.add(.{ .namespace = "default", .name = "pod-1" }, .{});
    const key = (try q.get()).?;

    // Assert
    try testing.expectEqualStrings("default", key.namespace);
    try testing.expectEqualStrings("pod-1", key.name);
    q.done(key, .success);
}

test "WorkQueue: FIFO ordering" {
    // Arrange
    var q = WorkQueue.init(testing.allocator, .{});
    defer {
        q.shutdown();
        q.deinit();
    }

    // Act
    try q.add(.{ .namespace = "ns", .name = "a" }, .{});
    try q.add(.{ .namespace = "ns", .name = "b" }, .{});
    try q.add(.{ .namespace = "ns", .name = "c" }, .{});

    // Assert
    const k1 = (try q.get()).?;
    try testing.expectEqualStrings("a", k1.name);
    q.done(k1, .success);

    const k2 = (try q.get()).?;
    try testing.expectEqualStrings("b", k2.name);
    q.done(k2, .success);

    const k3 = (try q.get()).?;
    try testing.expectEqualStrings("c", k3.name);
    q.done(k3, .success);
}

test "WorkQueue: deduplication" {
    // Arrange
    var q = WorkQueue.init(testing.allocator, .{});
    defer {
        q.shutdown();
        q.deinit();
    }

    // Act
    try q.add(.{ .namespace = "ns", .name = "pod-1" }, .{});
    try q.add(.{ .namespace = "ns", .name = "pod-1" }, .{}); // duplicate
    try q.add(.{ .namespace = "ns", .name = "pod-1" }, .{}); // duplicate

    // Assert
    try testing.expectEqual(@as(usize, 1), q.len());

    const key = (try q.get()).?;
    try testing.expectEqualStrings("pod-1", key.name);
    q.done(key, .success);
}

test "WorkQueue: done allows re-add" {
    // Arrange
    var q = WorkQueue.init(testing.allocator, .{});
    defer {
        q.shutdown();
        q.deinit();
    }

    // Act
    try q.add(.{ .namespace = "ns", .name = "pod-1" }, .{});
    const k1 = (try q.get()).?;
    q.done(k1, .success);

    // Assert
    try q.add(.{ .namespace = "ns", .name = "pod-1" }, .{});

    try testing.expectEqual(@as(usize, 1), q.len());
    const k2 = (try q.get()).?;
    try testing.expectEqualStrings("pod-1", k2.name);
    q.done(k2, .success);
}

test "WorkQueue: add during processing re-queues on done" {
    // Arrange
    var q = WorkQueue.init(testing.allocator, .{});
    defer {
        q.shutdown();
        q.deinit();
    }

    // Act
    try q.add(.{ .namespace = "ns", .name = "pod-1" }, .{});
    const key = (try q.get()).?;

    // Assert
    try q.add(.{ .namespace = "ns", .name = "pod-1" }, .{});

    try testing.expectEqual(@as(usize, 0), q.len());

    q.done(key, .success);

    try testing.expectEqual(@as(usize, 1), q.len());

    const k2 = (try q.get()).?;
    try testing.expectEqualStrings("pod-1", k2.name);
    q.done(k2, .success);
}

test "WorkQueue: shutdown causes get to return null" {
    // Arrange
    var q = WorkQueue.init(testing.allocator, .{});
    defer {
        q.shutdown();
        q.deinit();
    }

    // Act
    q.shutdown();

    // Assert
    try testing.expect((try q.get()) == null);
}

test "WorkQueue: add after shutdown is no-op" {
    // Arrange
    var q = WorkQueue.init(testing.allocator, .{});
    defer {
        q.shutdown();
        q.deinit();
    }

    // Act
    q.shutdown();

    // Assert
    try q.add(.{ .namespace = "ns", .name = "pod-1" }, .{});

    try testing.expectEqual(@as(usize, 0), q.len());
}

test "WorkQueue: isShutdown" {
    // Arrange
    var q = WorkQueue.init(testing.allocator, .{});
    defer {
        q.shutdown();
        q.deinit();
    }

    // Act / Assert
    try testing.expect(!q.isShutdown());
    q.shutdown();
    try testing.expect(q.isShutdown());
}

test "WorkQueue: len returns queued count" {
    // Arrange
    var q = WorkQueue.init(testing.allocator, .{});
    defer {
        q.shutdown();
        q.deinit();
    }

    // Act
    try testing.expectEqual(@as(usize, 0), q.len());

    // Assert
    try q.add(.{ .namespace = "ns", .name = "a" }, .{});
    try q.add(.{ .namespace = "ns", .name = "b" }, .{});

    try testing.expectEqual(@as(usize, 2), q.len());
}

test "WorkQueue: len excludes processing items" {
    // Arrange
    var q = WorkQueue.init(testing.allocator, .{});
    defer {
        q.shutdown();
        q.deinit();
    }

    // Act
    try q.add(.{ .namespace = "ns", .name = "a" }, .{});
    try q.add(.{ .namespace = "ns", .name = "b" }, .{});
    try testing.expectEqual(@as(usize, 2), q.len());

    // Assert
    const key = (try q.get()).?;

    try testing.expectEqual(@as(usize, 1), q.len());
    q.done(key, .success);
}

test "WorkQueue: get blocks until add (multi-threaded)" {
    // Arrange
    var q = WorkQueue.init(testing.allocator, .{});
    defer {
        q.shutdown();
        q.deinit();
    }

    // Act
    const producer = struct {
        fn run(wq: *WorkQueue) void {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            wq.add(.{ .namespace = "ns", .name = "async-pod" }, .{}) catch return;
        }
    };

    // Assert
    const thread = try std.Thread.spawn(.{}, producer.run, .{&q});
    const key = (try q.get()).?;

    try testing.expectEqualStrings("async-pod", key.name);
    q.done(key, .success);
    thread.join();
}

test "WorkQueue: shutdown unblocks waiting get" {
    // Arrange
    var q = WorkQueue.init(testing.allocator, .{});
    defer {
        q.shutdown();
        q.deinit();
    }

    // Act
    const shutdowner = struct {
        fn run(wq: *WorkQueue) void {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            wq.shutdown();
        }
    };

    // Assert
    const thread = try std.Thread.spawn(.{}, shutdowner.run, .{&q});
    const result = try q.get();

    try testing.expect(result == null);
    thread.join();
}

test "WorkQueue: addRateLimited delays re-enqueue" {
    // Arrange
    var q = WorkQueue.init(testing.allocator, .{ .retry_policy = .{
        .max_retries = std.math.maxInt(u32),
        .initial_backoff_ns = 50 * std.time.ns_per_ms,
        .max_backoff_ns = 1 * std.time.ns_per_s,
        .backoff_multiplier = 2,
        .jitter = false,
    } });
    defer {
        q.shutdown();
        q.deinit();
    }

    // Act
    try q.addRateLimited(.{ .namespace = "ns", .name = "slow-pod" });

    // Assert
    try testing.expectEqual(@as(usize, 0), q.len());

    const getter = struct {
        fn run(wq: *WorkQueue) void {
            if (wq.get() catch null) |k| wq.done(k, .success);
        }
    };
    const thread = try std.Thread.spawn(.{}, getter.run, .{&q});

    std.Thread.sleep(200 * std.time.ns_per_ms);
    q.shutdown();
    thread.join();
}

test "WorkQueue: multiple items interleaved processing" {
    // Arrange
    var q = WorkQueue.init(testing.allocator, .{});
    defer {
        q.shutdown();
        q.deinit();
    }

    // Act
    try q.add(.{ .namespace = "ns", .name = "a" }, .{});
    try q.add(.{ .namespace = "ns", .name = "b" }, .{});

    // Assert
    const k1 = (try q.get()).?;
    try testing.expectEqualStrings("a", k1.name);

    // Add a new item while 'a' is processing.
    try q.add(.{ .namespace = "ns", .name = "c" }, .{});

    const k2 = (try q.get()).?;
    try testing.expectEqualStrings("b", k2.name);

    q.done(k1, .success);
    q.done(k2, .success);

    const k3 = (try q.get()).?;
    try testing.expectEqualStrings("c", k3.name);
    q.done(k3, .success);
}

test "WorkQueue: cluster-scoped key (empty namespace)" {
    // Arrange
    var q = WorkQueue.init(testing.allocator, .{});
    defer {
        q.shutdown();
        q.deinit();
    }

    // Act
    try q.add(.{ .namespace = "", .name = "my-node" }, .{});
    const key = (try q.get()).?;

    // Assert
    try testing.expectEqualStrings("", key.namespace);
    try testing.expectEqualStrings("my-node", key.name);
    q.done(key, .success);
}

test "WorkQueue: addAfter with delay" {
    // Arrange
    var q = WorkQueue.init(testing.allocator, .{});
    defer {
        q.shutdown();
        q.deinit();
    }

    // Act
    try q.addAfter(.{ .namespace = "ns", .name = "delayed-pod" }, 50 * std.time.ns_per_ms);

    // Assert
    try testing.expectEqual(@as(usize, 0), q.len());

    const getter = struct {
        fn run(wq: *WorkQueue) void {
            if (wq.get() catch null) |k| wq.done(k, .success);
        }
    };
    const thread = try std.Thread.spawn(.{}, getter.run, .{&q});

    std.Thread.sleep(200 * std.time.ns_per_ms);
    q.shutdown();
    thread.join();
}

test "WorkQueue: addAfter with zero delay is immediate" {
    // Arrange
    var q = WorkQueue.init(testing.allocator, .{});
    defer {
        q.shutdown();
        q.deinit();
    }

    // Act
    try q.addAfter(.{ .namespace = "ns", .name = "immediate-pod" }, 0);

    // Assert
    try testing.expectEqual(@as(usize, 1), q.len());

    const key = (try q.get()).?;
    try testing.expectEqualStrings("ns", key.namespace);
    try testing.expectEqualStrings("immediate-pod", key.name);
    q.done(key, .success);
}

test "WorkQueue: deinit frees dirty keys re-added during processing" {
    // Arrange
    // separate allocation in dirty. If deinit() runs before done(), that
    // allocation must still be freed.
    var q = WorkQueue.init(testing.allocator, .{});

    // Act
    try q.add(.{ .namespace = "ns", .name = "pod-1" }, .{});
    const key = (try q.get()).?;

    // Assert
    try q.add(.{ .namespace = "ns", .name = "pod-1" }, .{});

    // teardown during active processing. testing.allocator will detect any leak.
    _ = key;
    q.shutdown();
    q.deinit();
}

// OOM resilience tests
//
// These tests verify that OOM errors during internal data-structure
// mutations do not leak key memory. The testing.allocator (GPA with
// safety) will fail the test if any allocation is not freed.

test "WorkQueue: done() OOM on re-queue does not leak" {
    // Arrange
    var fa = std.testing.FailingAllocator.init(testing.allocator, .{});
    var q = WorkQueue.init(fa.allocator(), .{});
    defer {
        q.shutdown();
        q.deinit();
    }

    // Act
    // processing (creates a second clone in dirty only).
    try q.add(.{ .namespace = "ns", .name = "pod-1" }, .{});
    const key = (try q.get()).?;
    try q.add(.{ .namespace = "ns", .name = "pod-1" }, .{});

    // Assert
    // The first add above grew the ring buffer to capacity 8 (now empty
    // after get). Adding 8 unique items fills it completely.
    const fill = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h" };
    for (fill) |name| {
        try q.add(.{ .namespace = "ns", .name = name }, .{});
    }

    // so queuePush must resize, which will fail.
    fa.fail_index = fa.alloc_index;
    fa.resize_fail_index = fa.resize_index;

    // done() sees the key in dirty and tries to re-queue via
    // queuePush, which hits OOM on ring buffer resize. Both the
    // processing key and the dirty clone must be freed (no leak).
    // done() is infallible: it logs and drops the item on OOM.
    q.done(key, .success);

    fa.fail_index = std.math.maxInt(usize);
    fa.resize_fail_index = std.math.maxInt(usize);
    for (fill) |_| {
        const k = (try q.get()).?;
        q.done(k, .success);
    }

    // Verify the key is not stuck in dirty.
    try q.add(.{ .namespace = "ns", .name = "pod-1" }, .{});
    try testing.expectEqual(@as(usize, 1), q.len());
    const k = (try q.get()).?;
    q.done(k, .success);
}

test "WorkQueue: get() OOM on processing.ensureCapacity preserves key" {
    // Arrange
    var fa = std.testing.FailingAllocator.init(testing.allocator, .{});
    var q = WorkQueue.init(fa.allocator(), .{});
    defer {
        q.shutdown();
        q.deinit();
    }

    try q.add(.{ .namespace = "ns", .name = "pod-1" }, .{});

    // Act
    fa.fail_index = fa.alloc_index;
    fa.resize_fail_index = fa.resize_index;

    // Assert
    // OOM is returned immediately; the key must still be in the queue.
    try testing.expectError(error.OutOfMemory, q.get());

    fa.fail_index = std.math.maxInt(usize);
    fa.resize_fail_index = std.math.maxInt(usize);

    // Key survives: the next get() must return it.
    const key = (try q.get()).?;
    try testing.expectEqualStrings("pod-1", key.name);
    q.done(key, .success);
}

test "WorkQueue: add() OOM on queue push resize does not leak" {
    // Arrange
    var fa = std.testing.FailingAllocator.init(testing.allocator, .{});
    var q = WorkQueue.init(fa.allocator(), .{});
    defer {
        q.shutdown();
        q.deinit();
    }

    // Act
    // This also grows dirty's hash map so it has spare capacity.
    const fill = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h" };
    for (fill) |name| {
        try q.add(.{ .namespace = "ns", .name = name }, .{});
    }

    // Assert
    // dirty: 8 entries, capacity >= 16 (has room without resize).
    // cloneKey does 2 allocs (ns + name), dirty.put reuses existing
    // capacity. The 3rd alloc is queuePush (ring buffer resize); make it fail.
    fa.fail_index = fa.alloc_index + 2;
    fa.resize_fail_index = fa.resize_index;

    // add() should return an error and clean up: remove from dirty and free the clone.
    try testing.expectError(error.OutOfMemory, q.add(.{ .namespace = "ns", .name = "pod-1" }, .{}));

    fa.fail_index = std.math.maxInt(usize);
    fa.resize_fail_index = std.math.maxInt(usize);
    for (fill) |_| {
        const k = (try q.get()).?;
        q.done(k, .success);
    }

    // Verify the key is not stuck in dirty.
    try q.add(.{ .namespace = "ns", .name = "pod-1" }, .{});
    try testing.expectEqual(@as(usize, 1), q.len());
    const k = (try q.get()).?;
    q.done(k, .success);
}

test "WorkQueue: addLockedFromWaiting() OOM on dirty.put does not leak" {
    // Arrange
    var fa = std.testing.FailingAllocator.init(testing.allocator, .{});
    var q = WorkQueue.init(fa.allocator(), .{
        .retry_policy = .{
            .max_retries = std.math.maxInt(u32),
            .initial_backoff_ns = 1,
            .max_backoff_ns = 10,
            .backoff_multiplier = 2,
            .jitter = false,
        },
    });
    defer {
        q.shutdown();
        q.deinit();
    }

    // Act
    // into waiting/waiting_keys/failures but never touches dirty.
    try q.addRateLimited(.{ .namespace = "ns", .name = "pod-1" });

    // Assert
    std.Thread.sleep(50 * std.time.ns_per_ms);

    // so dirty.put must allocate, which will fail.
    fa.fail_index = fa.alloc_index;
    fa.resize_fail_index = fa.resize_index;

    // get() calls promoteExpiredWaiting, which calls addLockedFromWaiting.
    // dirty.put needs to allocate (capacity 0) and hits OOM.
    // The owned key from the waiting heap must be freed.
    // get() then blocks until shutdown.
    const shutdowner = struct {
        fn run(wq: *WorkQueue) void {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            wq.shutdown();
        }
    };
    const thread = try std.Thread.spawn(.{}, shutdowner.run, .{&q});

    const result = q.get() catch null;

    try testing.expect(result == null);

    thread.join();
}

test "WorkQueue: done clears failure entries after successful processing" {
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
    defer {
        q.shutdown();
        q.deinit();
    }

    // Act
    const key = ObjectKey{ .namespace = "ns", .name = "pod-1" };

    // Assert
    try q.addRateLimited(key);
    try testing.expectEqual(@as(u32, 1), q.numRequeues(key));

    std.Thread.sleep(100 * std.time.ns_per_ms);

    const k1 = (try q.get()).?;
    try testing.expectEqualStrings("pod-1", k1.name);

    // Failure entry still exists while processing.
    try testing.expectEqual(@as(u32, 1), q.numRequeues(key));

    q.done(k1, .success);

    try testing.expectEqual(@as(u32, 0), q.numRequeues(key));
}

test "WorkQueue: done preserves failure entries when key is awaiting rate-limited requeue" {
    // Arrange
    var q = WorkQueue.init(testing.allocator, .{
        .retry_policy = .{
            .max_retries = std.math.maxInt(u32),
            .initial_backoff_ns = 50 * std.time.ns_per_ms,
            .max_backoff_ns = 1 * std.time.ns_per_s,
            .backoff_multiplier = 2,
            .jitter = false,
        },
    });
    defer {
        q.shutdown();
        q.deinit();
    }

    // Act
    const key = ObjectKey{ .namespace = "ns", .name = "pod-1" };

    // Assert
    try q.add(key, .{});
    const k1 = (try q.get()).?;

    try q.addRateLimited(k1);
    try testing.expectEqual(@as(u32, 1), q.numRequeues(key));

    // in waiting_keys (awaiting rate-limited requeue)
    q.done(k1, .success);
    try testing.expectEqual(@as(u32, 1), q.numRequeues(key));

    std.Thread.sleep(200 * std.time.ns_per_ms);
    const k2 = (try q.get()).?;
    try testing.expectEqualStrings("pod-1", k2.name);

    q.done(k2, .success);

    try testing.expectEqual(@as(u32, 0), q.numRequeues(key));
}

test "WorkQueue: addLockedFromWaiting cleans up failures on dirty.put OOM" {
    // Arrange
    // promoteExpiredWaiting clones it for addLockedFromWaiting, but
    // dirty.put fails, the failures entry must be cleaned up.
    var fa = std.testing.FailingAllocator.init(testing.allocator, .{});
    var q = WorkQueue.init(fa.allocator(), .{
        .retry_policy = .{
            .max_retries = std.math.maxInt(u32),
            .initial_backoff_ns = 1,
            .max_backoff_ns = 10,
            .backoff_multiplier = 2,
            .jitter = false,
        },
    });
    defer {
        q.shutdown();
        q.deinit();
    }

    // Act
    const key = ObjectKey{ .namespace = "ns", .name = "pod-1" };
    try q.addRateLimited(key);
    try testing.expectEqual(@as(u32, 1), q.numRequeues(key));

    // Assert
    // Wait for the tiny backoff to expire.
    std.Thread.sleep(50 * std.time.ns_per_ms);

    // Allow cloneKey (2 allocs: ns dupe + name dupe) to succeed but
    // fail the third allocation (dirty.put hash map growth).
    fa.fail_index = fa.alloc_index + 2;
    fa.resize_fail_index = fa.resize_index;

    const shutdowner = struct {
        fn run(wq: *WorkQueue) void {
            std.Thread.sleep(20 * std.time.ns_per_ms);
            wq.shutdown();
        }
    };
    const thread = try std.Thread.spawn(.{}, shutdowner.run, .{&q});
    const result = q.get() catch null;
    try testing.expect(result == null);
    thread.join();

    // Restore allocator.
    fa.fail_index = std.math.maxInt(usize);
    fa.resize_fail_index = std.math.maxInt(usize);

    try testing.expectEqual(@as(u32, 0), q.numRequeues(key));
}

// DoneAction tests
test "WorkQueue: done(.requeue_after) absorbs dirty flag and delays re-enqueue" {
    // Arrange
    var q = WorkQueue.init(testing.allocator, .{});
    defer {
        q.shutdown();
        q.deinit();
    }

    // Act
    try q.add(.{ .namespace = "ns", .name = "pod-1" }, .{});
    const key = (try q.get()).?;

    // Simulate a watch event arriving during processing.
    try q.add(.{ .namespace = "ns", .name = "pod-1" }, .{});

    q.done(key, .{ .requeue_after = 50 * std.time.ns_per_ms });

    // Assert
    // Key should NOT be in the active queue (dirty absorbed by delay).
    try testing.expectEqual(@as(usize, 0), q.len());

    // Wait for the delay to expire, then verify the key appears.
    std.Thread.sleep(200 * std.time.ns_per_ms);
    const k2 = (try q.get()).?;
    try testing.expectEqualStrings("pod-1", k2.name);
    q.done(k2, .success);
}

test "WorkQueue: done(.requeue_after) with zero delay enqueues immediately" {
    // Arrange
    var q = WorkQueue.init(testing.allocator, .{});
    defer {
        q.shutdown();
        q.deinit();
    }

    // Act
    try q.add(.{ .namespace = "ns", .name = "pod-1" }, .{});
    const key = (try q.get()).?;

    q.done(key, .{ .requeue_after = 0 });

    // Assert
    try testing.expectEqual(@as(usize, 1), q.len());

    const k2 = (try q.get()).?;
    try testing.expectEqualStrings("pod-1", k2.name);
    q.done(k2, .success);
}

test "WorkQueue: done(.requeue_after) clears failure counter" {
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
    defer {
        q.shutdown();
        q.deinit();
    }

    // Act
    const key_template = ObjectKey{ .namespace = "ns", .name = "pod-1" };

    // Build up some failure state via addRateLimited.
    try q.addRateLimited(key_template);
    try q.addRateLimited(key_template);
    try testing.expectEqual(@as(u32, 2), q.numRequeues(key_template));

    // Drain the waiting item.
    std.Thread.sleep(100 * std.time.ns_per_ms);
    const k1 = (try q.get()).?;

    // done(.requeue_after) should clear failures.
    q.done(k1, .{ .requeue_after = 1 });

    // Assert
    try testing.expectEqual(@as(u32, 0), q.numRequeues(key_template));

    // Clean up the waiting item.
    std.Thread.sleep(100 * std.time.ns_per_ms);
    q.shutdown();
    while (true) {
        if (q.get() catch null) |k| q.done(k, .success) else break;
    }
}

test "WorkQueue: done(.requeue_after) deduplicates against existing waiting entry" {
    // Arrange
    var q = WorkQueue.init(testing.allocator, .{});
    defer {
        q.shutdown();
        q.deinit();
    }

    // Act
    try q.add(.{ .namespace = "ns", .name = "pod-1" }, .{});
    const key = (try q.get()).?;

    // Add to waiting heap while processing.
    try q.addAfter(.{ .namespace = "ns", .name = "pod-1" }, 50 * std.time.ns_per_ms);

    q.done(key, .{ .requeue_after = 50 * std.time.ns_per_ms });

    // Assert
    q.mutex.lock();
    const waiting_count = q.scheduler.count();
    q.mutex.unlock();
    try testing.expectEqual(@as(usize, 1), waiting_count);

    // Drain.
    std.Thread.sleep(200 * std.time.ns_per_ms);
    q.shutdown();
    while (true) {
        if (q.get() catch null) |k| q.done(k, .success) else break;
    }
}

test "WorkQueue: done(.backoff) absorbs dirty flag and uses exponential backoff" {
    // Arrange
    var q = WorkQueue.init(testing.allocator, .{
        .retry_policy = .{
            .max_retries = std.math.maxInt(u32),
            .initial_backoff_ns = 50 * std.time.ns_per_ms,
            .max_backoff_ns = 1 * std.time.ns_per_s,
            .backoff_multiplier = 2,
            .jitter = false,
        },
    });
    defer {
        q.shutdown();
        q.deinit();
    }

    // Act
    try q.add(.{ .namespace = "ns", .name = "pod-1" }, .{});
    const key = (try q.get()).?;

    // Simulate a watch event arriving during processing.
    try q.add(.{ .namespace = "ns", .name = "pod-1" }, .{});

    q.done(key, .backoff);

    // Assert
    // Key should NOT be in the active queue (dirty absorbed by backoff).
    try testing.expectEqual(@as(usize, 0), q.len());

    // Failure counter should be incremented.
    try testing.expectEqual(@as(u32, 1), q.numRequeues(.{ .namespace = "ns", .name = "pod-1" }));

    // Drain.
    std.Thread.sleep(200 * std.time.ns_per_ms);
    q.shutdown();
    while (true) {
        if (q.get() catch null) |k| q.done(k, .success) else break;
    }
}

test "WorkQueue: done(.backoff) increments failure counter across calls" {
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
    defer {
        q.shutdown();
        q.deinit();
    }

    // Act
    const key_template = ObjectKey{ .namespace = "ns", .name = "pod-1" };

    // First cycle: add, get, done(.backoff)
    try q.add(key_template, .{});
    const k1 = (try q.get()).?;
    q.done(k1, .backoff);
    try testing.expectEqual(@as(u32, 1), q.numRequeues(key_template));

    // Wait for backoff to expire, get the re-enqueued item.
    std.Thread.sleep(50 * std.time.ns_per_ms);
    const k2 = (try q.get()).?;

    // Second cycle: done(.backoff) again.
    q.done(k2, .backoff);

    // Assert
    try testing.expectEqual(@as(u32, 2), q.numRequeues(key_template));

    // Drain.
    std.Thread.sleep(100 * std.time.ns_per_ms);
    q.shutdown();
    while (true) {
        if (q.get() catch null) |k| q.done(k, .success) else break;
    }
}

test "WorkQueue: done(.success) re-enqueues immediately when dirty" {
    // Arrange
    var q = WorkQueue.init(testing.allocator, .{});
    defer {
        q.shutdown();
        q.deinit();
    }

    // Act
    try q.add(.{ .namespace = "ns", .name = "pod-1" }, .{});
    const key = (try q.get()).?;

    // Simulate external change during processing.
    try q.add(.{ .namespace = "ns", .name = "pod-1" }, .{});
    try testing.expectEqual(@as(usize, 0), q.len());

    q.done(key, .success);

    // Assert
    try testing.expectEqual(@as(usize, 1), q.len());

    const k2 = (try q.get()).?;
    try testing.expectEqualStrings("pod-1", k2.name);
    q.done(k2, .success);
}

// defer_to_waiting tests
test "WorkQueue: add(defer_to_waiting) defers to waiting heap after done(.requeue_after)" {
    // Arrange
    // When defer_to_waiting is true, add() must not bypass a pending
    // requeue_after delay. The dirty flag is set so the key is processed
    // once the waiting entry expires.
    var q = WorkQueue.init(testing.allocator, .{});
    defer {
        q.shutdown();
        q.deinit();
    }

    // Act
    try q.add(.{ .namespace = "ns", .name = "pod-1" }, .{});
    const key = (try q.get()).?;

    q.done(key, .{ .requeue_after = 50 * std.time.ns_per_ms });

    // Simulate watch event arriving after done() has released the lock.
    try q.add(.{ .namespace = "ns", .name = "pod-1" }, .{ .defer_to_waiting = true });

    // Assert
    // Key must NOT be in the active queue. add() should defer to the
    // existing waiting entry.
    try testing.expectEqual(@as(usize, 0), q.len());

    // Wait for the delay to expire; key should then be promoted.
    std.Thread.sleep(200 * std.time.ns_per_ms);
    const k2 = (try q.get()).?;
    try testing.expectEqualStrings("pod-1", k2.name);
    q.done(k2, .success);
}

test "WorkQueue: add(defer_to_waiting) defers to waiting heap from addAfter" {
    // Arrange
    var q = WorkQueue.init(testing.allocator, .{});
    defer {
        q.shutdown();
        q.deinit();
    }

    // Act
    try q.addAfter(.{ .namespace = "ns", .name = "pod-1" }, 50 * std.time.ns_per_ms);
    try q.add(.{ .namespace = "ns", .name = "pod-1" }, .{ .defer_to_waiting = true });

    // Assert
    try testing.expectEqual(@as(usize, 0), q.len());

    // Wait for the delay to expire.
    std.Thread.sleep(200 * std.time.ns_per_ms);
    const key = (try q.get()).?;
    try testing.expectEqualStrings("pod-1", key.name);
    q.done(key, .success);
}

test "WorkQueue: add(defer_to_waiting) defers to waiting heap from addRateLimited" {
    // Arrange
    var q = WorkQueue.init(testing.allocator, .{
        .retry_policy = .{
            .max_retries = std.math.maxInt(u32),
            .initial_backoff_ns = 50 * std.time.ns_per_ms,
            .max_backoff_ns = 1 * std.time.ns_per_s,
            .backoff_multiplier = 2,
            .jitter = false,
        },
    });
    defer {
        q.shutdown();
        q.deinit();
    }

    // Act
    try q.addRateLimited(.{ .namespace = "ns", .name = "pod-1" });
    try q.add(.{ .namespace = "ns", .name = "pod-1" }, .{ .defer_to_waiting = true });

    // Assert
    try testing.expectEqual(@as(usize, 0), q.len());

    // Wait for the backoff to expire.
    std.Thread.sleep(200 * std.time.ns_per_ms);
    const key = (try q.get()).?;
    try testing.expectEqualStrings("pod-1", key.name);
    q.done(key, .success);
}

test "WorkQueue: multiple add(defer_to_waiting) calls while key is waiting coalesce" {
    // Arrange
    var q = WorkQueue.init(testing.allocator, .{});
    defer {
        q.shutdown();
        q.deinit();
    }

    // Act
    try q.add(.{ .namespace = "ns", .name = "pod-1" }, .{});
    const key = (try q.get()).?;
    q.done(key, .{ .requeue_after = 50 * std.time.ns_per_ms });

    // Simulate many watch events arriving after done().
    try q.add(.{ .namespace = "ns", .name = "pod-1" }, .{ .defer_to_waiting = true });
    try q.add(.{ .namespace = "ns", .name = "pod-1" }, .{ .defer_to_waiting = true });
    try q.add(.{ .namespace = "ns", .name = "pod-1" }, .{ .defer_to_waiting = true });

    // Assert
    // All add() calls should be deduplicated, leaving no items in the active queue.
    try testing.expectEqual(@as(usize, 0), q.len());

    // Only one processing after delay expires.
    std.Thread.sleep(200 * std.time.ns_per_ms);
    const k2 = (try q.get()).?;
    try testing.expectEqualStrings("pod-1", k2.name);
    q.done(k2, .success);

    // No more items.
    q.shutdown();
    try testing.expect((try q.get()) == null);
}

test "WorkQueue: overall limiter adds delay to rate-limited requeues" {
    // Arrange
    var q = WorkQueue.init(testing.allocator, .{
        .retry_policy = .{
            .max_retries = std.math.maxInt(u32),
            .initial_backoff_ns = 1, // near-zero per-key backoff
            .max_backoff_ns = 10,
            .backoff_multiplier = 2,
            .jitter = false,
        },
        .overall_rate_limit = .{ .qps = 10.0, .burst = 1 },
    });
    defer {
        q.shutdown();
        q.deinit();
    }

    // Act
    const key1 = ObjectKey{ .namespace = "ns", .name = "a" };
    const key2 = ObjectKey{ .namespace = "ns", .name = "b" };

    // First addRateLimited consumes the one burst token (zero bucket delay).
    try q.addRateLimited(key1);

    // Second addRateLimited goes into debt, so bucket delay > 0.
    // With 10 QPS, the delay is ~100ms. Per-key backoff is ~1ns,
    // so the max(backoff, bucket_delay) is dominated by the bucket.
    try q.addRateLimited(key2);

    // Assert
    // The first key should become available almost immediately.
    std.Thread.sleep(20 * std.time.ns_per_ms);
    const k1 = (try q.get()).?;
    try testing.expectEqualStrings("a", k1.name);
    q.done(k1, .success);

    // The second key should still be waiting (bucket delay ~100ms).
    try testing.expectEqual(@as(usize, 0), q.len());

    // After enough time, the second key becomes available.
    std.Thread.sleep(200 * std.time.ns_per_ms);
    const k2 = (try q.get()).?;
    try testing.expectEqualStrings("b", k2.name);
    q.done(k2, .success);
}

test "WorkQueue: overall limiter disabled when qps is 0" {
    // Arrange
    var q = WorkQueue.init(testing.allocator, .{
        .retry_policy = .{
            .max_retries = std.math.maxInt(u32),
            .initial_backoff_ns = 1,
            .max_backoff_ns = 10,
            .backoff_multiplier = 2,
            .jitter = false,
        },
        .overall_rate_limit = RateLimiter.Config.disabled,
    });
    defer {
        q.shutdown();
        q.deinit();
    }

    // Act / Assert
    try testing.expect(q.scheduler.overall_limiter == null);

    const key = ObjectKey{ .namespace = "ns", .name = "pod-1" };
    try q.addRateLimited(key);

    // With disabled limiter and tiny backoff, key should be available quickly.
    std.Thread.sleep(50 * std.time.ns_per_ms);
    const k = (try q.get()).?;
    try testing.expectEqualStrings("pod-1", k.name);
    q.done(k, .success);
}

test "WorkQueue: overall limiter defaults are 10 QPS / 100 burst" {
    // Arrange
    const opts = WorkQueue.Options{};

    // Act / Assert
    try testing.expectEqual(@as(f64, 10.0), opts.overall_rate_limit.qps);
    try testing.expectEqual(@as(u32, 100), opts.overall_rate_limit.burst);
}

test "WorkQueue: done(.backoff) uses overall limiter" {
    // Arrange
    var q = WorkQueue.init(testing.allocator, .{
        .retry_policy = .{
            .max_retries = std.math.maxInt(u32),
            .initial_backoff_ns = 1,
            .max_backoff_ns = 10,
            .backoff_multiplier = 2,
            .jitter = false,
        },
        .overall_rate_limit = .{ .qps = 10.0, .burst = 1 },
    });
    defer {
        q.shutdown();
        q.deinit();
    }

    // Act
    try q.add(.{ .namespace = "ns", .name = "a" }, .{});
    const k1 = (try q.get()).?;

    // First done(.backoff) consumes the one burst token.
    q.done(k1, .backoff);

    try q.add(.{ .namespace = "ns", .name = "b" }, .{});
    const k2 = (try q.get()).?;

    // Second done(.backoff) goes into bucket debt (~100ms).
    q.done(k2, .backoff);

    // Assert
    // Wait for key "a" to be promoted (near-zero per-key backoff, burst token).
    std.Thread.sleep(20 * std.time.ns_per_ms);
    const ka = (try q.get()).?;
    try testing.expectEqualStrings("a", ka.name);
    q.done(ka, .success);

    // Key "b" should still be waiting (bucket delay ~100ms).
    try testing.expectEqual(@as(usize, 0), q.len());

    // After enough time, key "b" becomes available.
    std.Thread.sleep(200 * std.time.ns_per_ms);
    const kb = (try q.get()).?;
    try testing.expectEqualStrings("b", kb.name);
    q.done(kb, .success);
}
