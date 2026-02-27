const std = @import("std");
const logging = @import("../util/logging.zig");
const Logger = logging.Logger;
const LogField = logging.Field;
const store_mod = @import("../cache/store.zig");
const ObjectKey = store_mod.ObjectKey;
const ObjectKeyContext = store_mod.ObjectKeyContext;
const RetryPolicy = @import("../util/retry.zig").RetryPolicy;
const rate_limit_mod = @import("../util/rate_limit.zig");
const RateLimiter = rate_limit_mod.RateLimiter;
const testing = std.testing;

/// Backoff scheduling subsystem for rate-limited and delayed requeues.
///
/// Manages a min-heap of deferred items (sorted by expiry), per-key failure
/// counts for exponential backoff, and an optional global token-bucket rate
/// limiter. Designed to be embedded inside a WorkQueue, which provides the
/// mutex, condition variable, and core queue/dirty/processing sets.
///
/// Thread safety: the caller is responsible for holding a mutex around all
/// method calls. BackoffScheduler itself does not acquire any locks.
pub const BackoffScheduler = struct {
    allocator: std.mem.Allocator,
    failures: FailureMap = .empty,
    heap: WaitingQueue,
    waiting_keys: KeySet = .empty,
    max_size: usize,
    retry_policy: RetryPolicy,
    overall_limiter: ?RateLimiter,
    epoch: std.time.Instant,
    logger: Logger = Logger.noop,

    pub const FailureMap = std.HashMapUnmanaged(
        ObjectKey,
        u32,
        ObjectKeyContext,
        std.hash_map.default_max_load_percentage,
    );

    pub const KeySet = std.HashMapUnmanaged(
        ObjectKey,
        void,
        ObjectKeyContext,
        std.hash_map.default_max_load_percentage,
    );

    pub const WaitingItem = struct {
        key: ObjectKey,
        not_before: u64, // monotonic nanos since queue epoch (from std.time.Instant)
        owned: bool, // true = independently owned (addAfter); false = owned by failures map
    };

    fn waitingItemCompare(_: void, a: WaitingItem, b: WaitingItem) std.math.Order {
        return std.math.order(a.not_before, b.not_before);
    }

    pub const WaitingQueue = std.PriorityQueue(WaitingItem, void, waitingItemCompare);

    /// Result of a scheduling attempt. Tells the caller (WorkQueue) what
    /// happened so it can handle key ownership and fallbacks.
    pub const ScheduleResult = enum {
        /// Item was successfully scheduled in the waiting heap.
        scheduled,
        /// Key is already in the waiting heap; caller should free its key copy.
        already_waiting,
        /// Waiting heap is at capacity; caller should fall back.
        full,
        /// Out of memory; caller should handle the error.
        oom,
        /// Monotonic clock unavailable; caller should fall back.
        clock_unavailable,
    };

    pub const Options = struct {
        max_size: usize = 65_536,
        retry_policy: RetryPolicy = .{
            .max_retries = std.math.maxInt(u32),
            .initial_backoff_ns = 5 * std.time.ns_per_ms,
            .max_backoff_ns = 1000 * std.time.ns_per_s,
            .backoff_multiplier = 2,
            .jitter = true,
        },
        overall_rate_limit: RateLimiter.Config = .{ .qps = 10.0, .burst = 100 },
        logger: Logger = Logger.noop,
    };

    /// Create a scheduler with the given retry policy and rate limiter.
    ///
    /// `epoch` is the monotonic time origin used to compute `not_before`
    /// timestamps in the waiting heap.
    pub fn init(allocator: std.mem.Allocator, epoch: std.time.Instant, opts: Options) BackoffScheduler {
        return .{
            .allocator = allocator,
            .heap = WaitingQueue.init(allocator, {}),
            .max_size = opts.max_size,
            .retry_policy = opts.retry_policy,
            .overall_limiter = RateLimiter.init(opts.overall_rate_limit) catch null,
            .epoch = epoch,
            .logger = opts.logger,
        };
    }

    /// Free all owned keys in the waiting heap and failures map.
    pub fn deinit(self: *BackoffScheduler) void {
        // Free independently-owned waiting keys (from addAfter/scheduleAfter).
        // Keys from scheduleRateLimited are owned by the failures map and freed below.
        while (self.heap.count() > 0) {
            const item = self.heap.remove();
            if (item.owned) {
                freeKey(self.allocator, item.key);
            }
        }
        self.heap.deinit();
        self.waiting_keys.deinit(self.allocator);

        // Free keys in failures map.
        var fail_it = self.failures.iterator();
        while (fail_it.next()) |entry| {
            freeKey(self.allocator, entry.key_ptr.*);
        }
        self.failures.deinit(self.allocator);
    }

    // Scheduling methods
    /// Schedule a key with exponential backoff. Gets or creates a failure
    /// entry, checks dedup in waiting_keys, calculates backoff using
    /// retry_policy + overall_limiter, adds to heap + waiting_keys.
    /// Increments counter only after all fallible ops succeed. Rolls back
    /// on OOM.
    pub fn scheduleRateLimited(self: *BackoffScheduler, key: ObjectKey) error{ OutOfMemory, Overflow, ClockUnavailable }!void {
        // Look up (or create) the failure counter entry, but don't
        // increment yet; we only bump the counter after all fallible
        // operations below succeed, so OOM can't leave it inflated.
        const gop = self.failures.getOrPut(self.allocator, key) catch return error.OutOfMemory;
        const is_new_entry = !gop.found_existing;
        if (is_new_entry) {
            gop.key_ptr.* = cloneKey(self.allocator, key) catch {
                self.failures.removeByPtr(gop.key_ptr);
                return error.OutOfMemory;
            };
            gop.value_ptr.* = 0;
        }

        // If the key is already in the waiting heap, just bump the failure
        // counter so the next backoff is longer, but don't add a duplicate entry.
        if (self.waiting_keys.contains(key)) {
            gop.value_ptr.* +|= 1;
            return;
        }

        // Reject new waiting entries when the heap is at capacity.
        if (self.heap.count() >= self.max_size) {
            if (is_new_entry) {
                freeKey(self.allocator, gop.key_ptr.*);
                self.failures.removeByPtr(gop.key_ptr);
            }
            return error.Overflow;
        }

        const attempt = gop.value_ptr.*;
        const backoff_ns = self.retry_policy.backoffWithJitterNs(attempt);
        const bucket_delay_ns: u64 = if (self.overall_limiter) |*limiter| limiter.reserve() else 0;
        const delay_ns = @max(backoff_ns, bucket_delay_ns);
        const now = self.monotonicNowNs() catch {
            if (is_new_entry) {
                freeKey(self.allocator, gop.key_ptr.*);
                self.failures.removeByPtr(gop.key_ptr);
            }
            return error.ClockUnavailable;
        };
        const not_before = now +| delay_ns;

        // Use the failures-owned key directly; no second clone needed.
        const failures_key = gop.key_ptr.*;

        // Track the key for duplicate detection. On OOM, clean up the
        // failures entry if we just created it to avoid an orphaned entry.
        self.waiting_keys.put(self.allocator, failures_key, {}) catch {
            if (is_new_entry) {
                freeKey(self.allocator, gop.key_ptr.*);
                self.failures.removeByPtr(gop.key_ptr);
            }
            return error.OutOfMemory;
        };

        // Insert into waiting heap (min-heap by not_before).
        self.heap.add(.{
            .key = failures_key,
            .not_before = not_before,
            .owned = false,
        }) catch {
            _ = self.waiting_keys.remove(failures_key);
            if (is_new_entry) {
                freeKey(self.allocator, gop.key_ptr.*);
                self.failures.removeByPtr(gop.key_ptr);
            }
            return error.OutOfMemory;
        };

        // All fallible operations succeeded, so now increment the counter.
        gop.value_ptr.* +|= 1;
    }

    /// Schedule a key after a fixed delay without touching the failure
    /// counter. Clones key (owned=true), checks dedup, checks capacity,
    /// adds to heap + waiting_keys atomically.
    pub fn scheduleAfter(self: *BackoffScheduler, key: ObjectKey, delay_ns: u64) error{ OutOfMemory, Overflow, ClockUnavailable }!void {
        // Skip if already waiting to avoid duplicate heap entries.
        if (self.waiting_keys.contains(key)) return;

        // Reject new waiting entries when the heap is at capacity.
        if (self.heap.count() >= self.max_size) return error.Overflow;

        const owned_key = cloneKey(self.allocator, key) catch return error.OutOfMemory;
        const now = self.monotonicNowNs() catch {
            freeKey(self.allocator, owned_key);
            return error.ClockUnavailable;
        };
        const not_before = now +| delay_ns;

        self.waiting_keys.put(self.allocator, owned_key, {}) catch {
            freeKey(self.allocator, owned_key);
            return error.OutOfMemory;
        };

        self.heap.add(.{ .key = owned_key, .not_before = not_before, .owned = true }) catch {
            _ = self.waiting_keys.remove(owned_key);
            freeKey(self.allocator, owned_key);
            return error.OutOfMemory;
        };
    }

    /// Scheduling logic for done(.backoff). Gets/creates failure entry,
    /// checks dedup, calculates backoff, adds to heap. Returns a result
    /// so WorkQueue can handle the key ownership.
    pub fn scheduleBackoff(self: *BackoffScheduler, key: ObjectKey) ScheduleResult {
        // Get or create the failure counter entry.
        const gop = self.failures.getOrPut(self.allocator, key) catch return .oom;
        const is_new_entry = !gop.found_existing;
        if (is_new_entry) {
            gop.key_ptr.* = cloneKey(self.allocator, key) catch {
                self.failures.removeByPtr(gop.key_ptr);
                return .oom;
            };
            gop.value_ptr.* = 0;
        }

        // If already in the waiting heap, just bump the failure counter.
        if (self.waiting_keys.contains(key)) {
            gop.value_ptr.* +|= 1;
            return .already_waiting;
        }

        // Reject when heap is at capacity.
        if (self.heap.count() >= self.max_size) {
            if (is_new_entry) {
                freeKey(self.allocator, gop.key_ptr.*);
                self.failures.removeByPtr(gop.key_ptr);
            }
            return .full;
        }

        const attempt = gop.value_ptr.*;
        const backoff_ns = self.retry_policy.backoffWithJitterNs(attempt);
        const bucket_delay_ns: u64 = if (self.overall_limiter) |*limiter| limiter.reserve() else 0;
        const delay_ns = @max(backoff_ns, bucket_delay_ns);
        const now = self.monotonicNowNs() catch {
            if (is_new_entry) {
                freeKey(self.allocator, gop.key_ptr.*);
                self.failures.removeByPtr(gop.key_ptr);
            }
            return .clock_unavailable;
        };
        const not_before = now +| delay_ns;

        const failures_key = gop.key_ptr.*;

        self.waiting_keys.put(self.allocator, failures_key, {}) catch {
            if (is_new_entry) {
                freeKey(self.allocator, gop.key_ptr.*);
                self.failures.removeByPtr(gop.key_ptr);
            }
            return .oom;
        };

        self.heap.add(.{
            .key = failures_key,
            .not_before = not_before,
            .owned = false,
        }) catch {
            _ = self.waiting_keys.remove(failures_key);
            if (is_new_entry) {
                freeKey(self.allocator, gop.key_ptr.*);
                self.failures.removeByPtr(gop.key_ptr);
            }
            return .oom;
        };

        // All fallible operations succeeded, so now increment the counter.
        gop.value_ptr.* +|= 1;
        return .scheduled;
    }

    /// Scheduling logic for done(.requeue_after) with delay > 0. Adds key
    /// to heap with owned=true. Returns result for WorkQueue to handle.
    pub fn scheduleRequeueAfter(self: *BackoffScheduler, key: ObjectKey, delay_ns: u64) ScheduleResult {
        if (self.waiting_keys.contains(key)) return .already_waiting;

        if (self.heap.count() >= self.max_size) return .full;

        const now = self.monotonicNowNs() catch return .clock_unavailable;
        const not_before = now +| delay_ns;

        self.waiting_keys.put(self.allocator, key, {}) catch return .oom;

        self.heap.add(.{ .key = key, .not_before = not_before, .owned = true }) catch {
            _ = self.waiting_keys.remove(key);
            return .oom;
        };

        return .scheduled;
    }

    // Failure tracking methods
    /// Reset the failure counter for a key. If the key is in the waiting
    /// heap, just reset the count (the failures entry must stay alive
    /// until promotion consumes the waiting entry). Otherwise remove and
    /// free the failures entry entirely.
    pub fn forget(self: *BackoffScheduler, key: ObjectKey) void {
        if (self.waiting_keys.contains(key)) {
            if (self.failures.getPtr(key)) |count_ptr| {
                count_ptr.* = 0;
            }
        } else {
            if (self.failures.fetchRemove(key)) |kv| {
                freeKey(self.allocator, kv.key);
            }
        }
    }

    /// Return the failure count for a key.
    pub fn numRequeues(self: *const BackoffScheduler, key: ObjectKey) u32 {
        return self.failures.get(key) orelse 0;
    }

    /// Clear failures for done(.requeue_after): if the key is in waiting,
    /// reset count; else remove and free the entry.
    pub fn clearFailures(self: *BackoffScheduler, key: ObjectKey) void {
        if (!self.waiting_keys.contains(key)) {
            if (self.failures.fetchRemove(key)) |fkv| {
                freeKey(self.allocator, fkv.key);
            }
        } else {
            if (self.failures.getPtr(key)) |count_ptr| {
                count_ptr.* = 0;
            }
        }
    }

    /// Remove orphaned failures entry for a key that is not in waiting_keys.
    /// Used by doneSuccess and addLockedFromWaiting after dropping a key.
    pub fn cleanupOrphan(self: *BackoffScheduler, key: ObjectKey) void {
        if (!self.waiting_keys.contains(key)) {
            if (self.failures.fetchRemove(key)) |fkv| {
                freeKey(self.allocator, fkv.key);
            }
        }
    }

    // Drain/query methods
    /// Pop expired items from heap up to buf.len, remove from waiting_keys.
    /// Returns slice of expired items for WorkQueue to process.
    pub fn drainExpired(self: *BackoffScheduler, now: u64, buf: []WaitingItem) []WaitingItem {
        var drained: usize = 0;
        while (drained < buf.len) {
            const earliest = self.heap.peek() orelse break;
            if (earliest.not_before > now) break;
            const item = self.heap.remove();
            _ = self.waiting_keys.remove(item.key);
            buf[drained] = item;
            drained += 1;
        }
        return buf[0..drained];
    }

    /// Re-insert an item into the waiting heap with a short retry delay.
    /// Used by WorkQueue.promoteExpiredWaiting on clone OOM.
    pub fn reinsertWithDelay(self: *BackoffScheduler, item: WaitingItem, delay_ns: u64) void {
        const now = self.monotonicNowNs() catch {
            self.logger.warn("reinsertWithDelay: clock unavailable, item dropped", &.{});
            if (self.failures.fetchRemove(item.key)) |fkv| {
                freeKey(self.allocator, fkv.key);
            }
            return;
        };
        self.waiting_keys.put(self.allocator, item.key, {}) catch {
            self.logger.warn("reinsertWithDelay: OOM re-inserting key, item dropped", &.{});
            if (self.failures.fetchRemove(item.key)) |fkv| {
                freeKey(self.allocator, fkv.key);
            }
            return;
        };
        self.heap.add(.{
            .key = item.key,
            .not_before = now +| delay_ns,
            .owned = false,
        }) catch {
            _ = self.waiting_keys.remove(item.key);
            self.logger.warn("reinsertWithDelay: OOM re-inserting key, item dropped", &.{});
            if (self.failures.fetchRemove(item.key)) |fkv| {
                freeKey(self.allocator, fkv.key);
            }
            return;
        };
    }

    /// Check if a key is in the waiting_keys set.
    pub fn containsKey(self: *const BackoffScheduler, key: ObjectKey) bool {
        return self.waiting_keys.contains(key);
    }

    /// Check if the waiting heap is at capacity.
    pub fn isFull(self: *const BackoffScheduler) bool {
        return self.heap.count() >= self.max_size;
    }

    /// Number of items in the waiting heap.
    pub fn count(self: *const BackoffScheduler) usize {
        return self.heap.count();
    }

    // Internal helpers
    /// Return the current monotonic time in nanoseconds relative to `epoch`.
    fn monotonicNowNs(self: *const BackoffScheduler) error{ClockUnavailable}!u64 {
        return (std.time.Instant.now() catch return error.ClockUnavailable).since(self.epoch);
    }

    // Key memory helpers (pub for use by work_queue.zig)
    /// Duplicate an `ObjectKey`'s namespace and name strings onto the heap.
    /// Returns `error.OutOfMemory` if either allocation fails (the first
    /// allocation is rolled back before returning).
    pub fn cloneKey(allocator: std.mem.Allocator, key: ObjectKey) error{OutOfMemory}!ObjectKey {
        const ns = if (key.namespace.len == 0)
            @as([]const u8, "")
        else
            try allocator.dupe(u8, key.namespace);
        const name = if (key.name.len == 0)
            @as([]const u8, "")
        else
            allocator.dupe(u8, key.name) catch {
                if (ns.len > 0) allocator.free(ns);
                return error.OutOfMemory;
            };
        return .{ .namespace = ns, .name = name };
    }

    /// Free a heap-allocated `ObjectKey`'s namespace and name strings.
    /// Skips zero-length slices (which are never heap-allocated).
    pub fn freeKey(allocator: std.mem.Allocator, key: ObjectKey) void {
        if (key.namespace.len > 0) allocator.free(key.namespace);
        if (key.name.len > 0) allocator.free(key.name);
    }
};

fn makeScheduler(allocator: std.mem.Allocator, opts: struct {
    max_size: usize = 65_536,
    retry_policy: @import("../util/retry.zig").RetryPolicy = .{
        .max_retries = std.math.maxInt(u32),
        .initial_backoff_ns = 1,
        .max_backoff_ns = 10,
        .backoff_multiplier = 2,
        .jitter = false,
    },
    overall_rate_limit: RateLimiter.Config = RateLimiter.Config.disabled,
}) BackoffScheduler {
    const epoch = std.time.Instant.now() catch @panic("monotonic clock required");
    return BackoffScheduler.init(allocator, epoch, .{
        .max_size = opts.max_size,
        .retry_policy = opts.retry_policy,
        .overall_rate_limit = opts.overall_rate_limit,
    });
}

test "BackoffScheduler: scheduleRateLimited increments failure count" {
    // Arrange
    var s = makeScheduler(testing.allocator, .{});
    defer s.deinit();

    // Act
    const key = ObjectKey{ .namespace = "ns", .name = "pod-1" };

    // Assert
    try testing.expectEqual(@as(u32, 0), s.numRequeues(key));
    try s.scheduleRateLimited(key);
    try testing.expectEqual(@as(u32, 1), s.numRequeues(key));
    try s.scheduleRateLimited(key);
    try testing.expectEqual(@as(u32, 2), s.numRequeues(key));
}

test "BackoffScheduler: forget resets failure count" {
    // Arrange
    var s = makeScheduler(testing.allocator, .{});
    defer s.deinit();

    // Act
    const key = ObjectKey{ .namespace = "ns", .name = "pod-1" };
    try s.scheduleRateLimited(key);
    try s.scheduleRateLimited(key);
    try testing.expectEqual(@as(u32, 2), s.numRequeues(key));

    // Assert
    s.forget(key);
    try testing.expectEqual(@as(u32, 0), s.numRequeues(key));
}

test "BackoffScheduler: scheduleRateLimited deduplicates waiting entries" {
    // Arrange
    var s = makeScheduler(testing.allocator, .{});
    defer s.deinit();

    // Act
    const key = ObjectKey{ .namespace = "ns", .name = "pod-1" };
    try s.scheduleRateLimited(key);
    try s.scheduleRateLimited(key);
    try s.scheduleRateLimited(key);

    // Assert
    try testing.expectEqual(@as(u32, 3), s.numRequeues(key));
    try testing.expectEqual(@as(usize, 1), s.count());
}

test "BackoffScheduler: scheduleAfter deduplicates waiting entries" {
    // Arrange
    var s = makeScheduler(testing.allocator, .{});
    defer s.deinit();

    // Act
    const key = ObjectKey{ .namespace = "ns", .name = "pod-1" };
    try s.scheduleAfter(key, 50 * std.time.ns_per_ms);
    try s.scheduleAfter(key, 50 * std.time.ns_per_ms);
    try s.scheduleAfter(key, 50 * std.time.ns_per_ms);

    // Assert
    try testing.expectEqual(@as(usize, 1), s.count());
}

test "BackoffScheduler: scheduleRateLimited respects max_size" {
    // Arrange
    var s = makeScheduler(testing.allocator, .{ .max_size = 2 });
    defer s.deinit();

    // Act
    try s.scheduleRateLimited(.{ .namespace = "ns", .name = "a" });
    try s.scheduleRateLimited(.{ .namespace = "ns", .name = "b" });

    // Assert
    try testing.expectError(error.Overflow, s.scheduleRateLimited(.{ .namespace = "ns", .name = "c" }));

    try testing.expectEqual(@as(u32, 1), s.numRequeues(.{ .namespace = "ns", .name = "a" }));
    try testing.expectEqual(@as(u32, 1), s.numRequeues(.{ .namespace = "ns", .name = "b" }));
    // "c" should not have a failures entry (rolled back on Overflow).
    try testing.expectEqual(@as(u32, 0), s.numRequeues(.{ .namespace = "ns", .name = "c" }));
}

test "BackoffScheduler: scheduleAfter respects max_size" {
    // Arrange
    var s = makeScheduler(testing.allocator, .{ .max_size = 1 });
    defer s.deinit();

    // Act
    try s.scheduleAfter(.{ .namespace = "ns", .name = "a" }, 50 * std.time.ns_per_ms);

    // Assert
    try testing.expectError(error.Overflow, s.scheduleAfter(.{ .namespace = "ns", .name = "b" }, 50 * std.time.ns_per_ms));
}

test "BackoffScheduler: scheduleAfter does not touch failure counter" {
    // Arrange
    var s = makeScheduler(testing.allocator, .{});
    defer s.deinit();

    // Act
    const key = ObjectKey{ .namespace = "ns", .name = "pod-1" };
    try s.scheduleRateLimited(key);
    try testing.expectEqual(@as(u32, 1), s.numRequeues(key));

    // Assert
    try s.scheduleAfter(key, 1);
    try testing.expectEqual(@as(u32, 1), s.numRequeues(key));
}

test "BackoffScheduler: overall limiter max semantics with backoff" {
    // Arrange
    var s = makeScheduler(testing.allocator, .{
        .retry_policy = .{
            .max_retries = std.math.maxInt(u32),
            .initial_backoff_ns = 500 * std.time.ns_per_ms,
            .max_backoff_ns = 500 * std.time.ns_per_ms,
            .backoff_multiplier = 1,
            .jitter = false,
        },
        .overall_rate_limit = .{ .qps = 1000.0, .burst = 10 },
    });
    defer s.deinit();

    // Act
    const key = ObjectKey{ .namespace = "ns", .name = "pod-1" };
    try s.scheduleRateLimited(key);

    // Assert
    // Bucket delay is ~0 (burst available), but per-key backoff is 500ms.
    // The item should be in the heap but not yet expired.
    try testing.expectEqual(@as(usize, 1), s.count());
    var buf: [1]BackoffScheduler.WaitingItem = undefined;
    const now = try s.monotonicNowNs();
    const expired = s.drainExpired(now, &buf);
    try testing.expectEqual(@as(usize, 0), expired.len);
}

test "BackoffScheduler: drainExpired returns expired items in order" {
    // Arrange
    var s = makeScheduler(testing.allocator, .{});
    defer s.deinit();

    // Act
    // Schedule items with increasing delays.
    try s.scheduleAfter(.{ .namespace = "ns", .name = "a" }, 1);
    try s.scheduleAfter(.{ .namespace = "ns", .name = "b" }, 2);
    try s.scheduleAfter(.{ .namespace = "ns", .name = "c" }, 3);

    // Wait long enough for all to expire.
    std.Thread.sleep(10 * std.time.ns_per_ms);

    // Assert
    var buf: [10]BackoffScheduler.WaitingItem = undefined;
    const now = try s.monotonicNowNs();
    const expired = s.drainExpired(now, &buf);
    try testing.expectEqual(@as(usize, 3), expired.len);
    try testing.expectEqualStrings("a", expired[0].key.name);
    try testing.expectEqualStrings("b", expired[1].key.name);
    try testing.expectEqualStrings("c", expired[2].key.name);

    // Clean up owned keys.
    for (expired) |item| {
        BackoffScheduler.freeKey(testing.allocator, item.key);
    }
}

test "BackoffScheduler: drainExpired respects batch limit" {
    // Arrange
    var s = makeScheduler(testing.allocator, .{});
    defer s.deinit();

    // Act
    try s.scheduleAfter(.{ .namespace = "ns", .name = "a" }, 1);
    try s.scheduleAfter(.{ .namespace = "ns", .name = "b" }, 2);
    try s.scheduleAfter(.{ .namespace = "ns", .name = "c" }, 3);

    std.Thread.sleep(10 * std.time.ns_per_ms);

    // Assert
    var buf: [2]BackoffScheduler.WaitingItem = undefined;
    const now = try s.monotonicNowNs();
    const expired = s.drainExpired(now, &buf);
    try testing.expectEqual(@as(usize, 2), expired.len);

    // One item should remain.
    try testing.expectEqual(@as(usize, 1), s.count());

    // Clean up owned keys.
    for (expired) |item| {
        BackoffScheduler.freeKey(testing.allocator, item.key);
    }
}

test "BackoffScheduler: OOM rollback in scheduleRateLimited" {
    // Arrange
    var fa = std.testing.FailingAllocator.init(testing.allocator, .{});
    var s = makeScheduler(fa.allocator(), .{});
    defer s.deinit();

    // Act
    // First call succeeds (allocates failures entry + waiting_keys + heap).
    try s.scheduleRateLimited(.{ .namespace = "ns", .name = "a" });
    try testing.expectEqual(@as(u32, 1), s.numRequeues(.{ .namespace = "ns", .name = "a" }));

    // Assert
    // Force all subsequent allocations to fail.
    fa.fail_index = fa.alloc_index;
    fa.resize_fail_index = fa.resize_index;

    try testing.expectError(error.OutOfMemory, s.scheduleRateLimited(.{ .namespace = "ns", .name = "new-key" }));

    // Restore allocator.
    fa.fail_index = std.math.maxInt(usize);
    fa.resize_fail_index = std.math.maxInt(usize);

    // "new-key" should not have a failures entry.
    try testing.expectEqual(@as(u32, 0), s.numRequeues(.{ .namespace = "ns", .name = "new-key" }));
}

test "BackoffScheduler: OOM rollback in scheduleAfter" {
    // Arrange
    var fa = std.testing.FailingAllocator.init(testing.allocator, .{});
    var s = makeScheduler(fa.allocator(), .{});
    defer s.deinit();

    // Act
    try s.scheduleAfter(.{ .namespace = "ns", .name = "a" }, 100 * std.time.ns_per_ms);
    try testing.expectEqual(@as(usize, 1), s.count());

    // Assert
    fa.fail_index = fa.alloc_index;
    fa.resize_fail_index = fa.resize_index;

    try testing.expectError(error.OutOfMemory, s.scheduleAfter(.{ .namespace = "ns", .name = "new-key" }, 100 * std.time.ns_per_ms));

    fa.fail_index = std.math.maxInt(usize);
    fa.resize_fail_index = std.math.maxInt(usize);

    try testing.expectEqual(@as(usize, 1), s.count());
}

test "BackoffScheduler: cleanupOrphan removes entry when not in waiting" {
    // Arrange
    var s = makeScheduler(testing.allocator, .{});
    defer s.deinit();

    // Act
    const key = ObjectKey{ .namespace = "ns", .name = "pod-1" };
    try s.scheduleRateLimited(key);
    try testing.expectEqual(@as(u32, 1), s.numRequeues(key));

    // Drain the item from waiting so it's no longer in waiting_keys.
    std.Thread.sleep(10 * std.time.ns_per_ms);
    var buf: [1]BackoffScheduler.WaitingItem = undefined;
    const now = try s.monotonicNowNs();
    const expired = s.drainExpired(now, &buf);
    try testing.expectEqual(@as(usize, 1), expired.len);

    // Assert
    s.cleanupOrphan(key);
    try testing.expectEqual(@as(u32, 0), s.numRequeues(key));
}

test "BackoffScheduler: cleanupOrphan preserves entry when in waiting" {
    // Arrange
    var s = makeScheduler(testing.allocator, .{
        .retry_policy = .{
            .max_retries = std.math.maxInt(u32),
            .initial_backoff_ns = 500 * std.time.ns_per_ms,
            .max_backoff_ns = 500 * std.time.ns_per_ms,
            .backoff_multiplier = 1,
            .jitter = false,
        },
    });
    defer s.deinit();

    // Act
    const key = ObjectKey{ .namespace = "ns", .name = "pod-1" };
    try s.scheduleRateLimited(key);
    try testing.expectEqual(@as(u32, 1), s.numRequeues(key));

    // Assert
    // Key is still in waiting (500ms backoff), cleanupOrphan should preserve it.
    s.cleanupOrphan(key);
    try testing.expectEqual(@as(u32, 1), s.numRequeues(key));
}
