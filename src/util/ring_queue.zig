//! Generic FIFO ring buffer (circular queue) backed by a growable array.
//!
//! Provides O(1) amortized `push` and `pop` with cache-friendly contiguous
//! storage. The buffer doubles in capacity when full and never shrinks.
//! An optional `max_capacity` field caps growth and causes `push` to
//! return `error.Overflow` once the limit is reached.

const std = @import("std");
const testing = std.testing;

/// Returns a FIFO ring queue type parameterized over element type `T`.
///
/// The returned struct is a circular buffer that grows by doubling when
/// full. Growth can be capped via the `max_capacity` field; once the
/// cap is reached, `push` returns `error.Overflow`.
pub fn RingQueue(comptime T: type) type {
    return struct {
        items: []T = &[_]T{},
        head: usize = 0,
        count: usize = 0,
        max_capacity: usize = std.math.maxInt(usize),

        const Self = @This();

        /// Append `item` to the back of the queue, growing the backing
        /// buffer if necessary. Returns `error.Overflow` when growth
        /// would exceed `max_capacity`, or `error.OutOfMemory` on
        /// allocation failure.
        pub fn push(self: *Self, allocator: std.mem.Allocator, item: T) error{ OutOfMemory, Overflow }!void {
            if (self.count == self.items.len) {
                const old_cap = self.items.len;
                const doubled: usize = if (old_cap == 0) 8 else old_cap *| 2;
                const new_cap = @min(doubled, self.max_capacity);
                if (new_cap <= old_cap) return error.Overflow;
                // Allocate
                const new_items = try allocator.alloc(T, new_cap);
                errdefer comptime unreachable;

                // Fill (linearize wrapped elements into the new buffer)
                for (0..self.count) |i| {
                    new_items[i] = self.items[(self.head + i) % old_cap];
                }
                if (old_cap > 0) allocator.free(self.items);
                self.items = new_items;
                self.head = 0;
            }
            self.items[(self.head + self.count) % self.items.len] = item;
            self.count += 1;
        }

        /// Remove and return the front element, or `null` if the queue
        /// is empty.
        pub fn pop(self: *Self) ?T {
            if (self.count == 0) return null;
            const item = self.items[self.head];
            self.head = (self.head + 1) % self.items.len;
            self.count -= 1;
            return item;
        }

        /// Free the backing buffer. The queue must not be used after
        /// calling this.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            if (self.items.len > 0) allocator.free(self.items);
        }
    };
}

test "RingQueue: push and pop single item" {
    // Arrange
    var q: RingQueue(u32) = .{};
    defer q.deinit(testing.allocator);

    // Act
    try q.push(testing.allocator, 42);

    // Assert
    try testing.expectEqual(@as(u32, 42), q.pop().?);
    try testing.expectEqual(@as(usize, 0), q.count);
}

test "RingQueue: FIFO ordering" {
    // Arrange
    var q: RingQueue(u32) = .{};
    defer q.deinit(testing.allocator);

    // Act
    try q.push(testing.allocator, 1);
    try q.push(testing.allocator, 2);
    try q.push(testing.allocator, 3);

    // Assert
    try testing.expectEqual(@as(u32, 1), q.pop().?);
    try testing.expectEqual(@as(u32, 2), q.pop().?);
    try testing.expectEqual(@as(u32, 3), q.pop().?);
}

test "RingQueue: grow on capacity exceeded" {
    // Arrange
    var q: RingQueue(u32) = .{};
    defer q.deinit(testing.allocator);

    // Act
    for (0..9) |i| {
        try q.push(testing.allocator, @intCast(i));
    }

    // Assert
    try testing.expectEqual(@as(usize, 9), q.count);

    for (0..9) |i| {
        try testing.expectEqual(@as(u32, @intCast(i)), q.pop().?);
    }
}

test "RingQueue: wraparound preserves order" {
    // Arrange
    var q: RingQueue(u32) = .{};
    defer q.deinit(testing.allocator);

    // Act
    // Fill to capacity 8.
    for (0..8) |i| {
        try q.push(testing.allocator, @intCast(i));
    }
    // Pop 4 items (head advances to 4).
    for (0..4) |_| _ = q.pop().?;

    // Assert
    for (8..12) |i| {
        try q.push(testing.allocator, @intCast(i));
    }

    for (4..12) |i| {
        try testing.expectEqual(@as(u32, @intCast(i)), q.pop().?);
    }
}

test "RingQueue: grow with wraparound linearizes correctly" {
    // Arrange
    var q: RingQueue(u32) = .{};
    defer q.deinit(testing.allocator);

    // Act
    // Fill to capacity, pop half, fill again to create wraparound.
    for (0..8) |i| try q.push(testing.allocator, @intCast(i));
    for (0..6) |_| _ = q.pop().?;
    for (8..14) |i| try q.push(testing.allocator, @intCast(i));
    // count=8, cap=8, head=6, so the buffer wraps.

    // Assert
    // wrapped items into the new buffer.
    try q.push(testing.allocator, 14);

    for (6..15) |i| {
        try testing.expectEqual(@as(u32, @intCast(i)), q.pop().?);
    }
}

test "RingQueue: max_capacity prevents unbounded growth" {
    // Arrange
    var q: RingQueue(u32) = .{ .max_capacity = 16 };
    defer q.deinit(testing.allocator);

    // Act
    // Fill to initial capacity of 8.
    for (0..8) |i| {
        try q.push(testing.allocator, @intCast(i));
    }

    // Assert
    // Push one more to trigger grow to 16 (within max_capacity).
    try q.push(testing.allocator, 8);
    try testing.expectEqual(@as(usize, 9), q.count);

    // Fill to capacity 16.
    for (9..16) |i| {
        try q.push(testing.allocator, @intCast(i));
    }

    try testing.expectError(error.Overflow, q.push(testing.allocator, 16));

    for (0..16) |i| {
        try testing.expectEqual(@as(u32, @intCast(i)), q.pop().?);
    }
}

test "RingQueue: non-power-of-2 max_capacity is fully usable" {
    // Arrange
    // not just 64 (the largest power-of-2 step that fits under 100).
    var q: RingQueue(u32) = .{ .max_capacity = 100 };
    defer q.deinit(testing.allocator);

    // Act
    for (0..100) |i| {
        try q.push(testing.allocator, @intCast(i));
    }

    // Assert
    try testing.expectEqual(@as(usize, 100), q.count);

    try testing.expectError(error.Overflow, q.push(testing.allocator, 100));

    for (0..100) |i| {
        try testing.expectEqual(@as(u32, @intCast(i)), q.pop().?);
    }
}

test "RingQueue: pop returns null on empty queue" {
    // Arrange
    var q: RingQueue(u32) = .{};
    defer q.deinit(testing.allocator);

    // Act / Assert
    try testing.expect(q.pop() == null);

    // Also verify pop returns null after draining.
    try q.push(testing.allocator, 1);
    _ = q.pop().?;
    try testing.expect(q.pop() == null);
}

test "RingQueue: push OOM on resize does not leak" {
    // Arrange
    var fa = std.testing.FailingAllocator.init(testing.allocator, .{});
    var q: RingQueue(u32) = .{};
    defer q.deinit(fa.allocator());

    // Act
    // Fill to initial capacity (8 items).
    for (0..8) |i| {
        try q.push(fa.allocator(), @intCast(i));
    }

    // Assert
    fa.fail_index = fa.alloc_index;

    try testing.expectError(error.OutOfMemory, q.push(fa.allocator(), 99));

    try testing.expectEqual(@as(usize, 8), q.count);
    for (0..8) |i| {
        try testing.expectEqual(@as(u32, @intCast(i)), q.pop().?);
    }
}
