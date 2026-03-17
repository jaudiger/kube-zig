//! Thread-safe in-memory store for Kubernetes resources.
//!
//! Provides a generic `Store(T)` keyed by namespace/name that supports
//! atomic bulk replacement, reference-counted entries, and deep cloning.
//! Uses a `RwLock` for concurrent read access with exclusive writes.

const std = @import("std");
const deepClone = @import("../util/deep_clone.zig").deepClone;
const logging_mod = @import("../util/logging.zig");
const Logger = logging_mod.Logger;
const LogField = logging_mod.Field;
const object_key_mod = @import("../object_key.zig");
pub const ObjectKey = object_key_mod.ObjectKey;
pub const ObjectKeyContext = object_key_mod.ObjectKeyContext;
const testing = std.testing;

/// Thread-safe in-memory cache of Kubernetes resources, keyed by namespace/name.
///
/// Each stored object owns its memory via an `ArenaAllocator` and is
/// reference-counted. The store uses a `RwLock` for HashMap structural
/// consistency, but never exposes the lock to callers.
///
/// **Pointer validity:** `get()` returns a retained `*Entry` that remains
/// valid until the caller calls `entry.release()`. The lock is not held
/// across the caller boundary. Forgetting `release()` leaks memory but
/// cannot cause a deadlock.
///
/// For callers that need the data to outlive the entry (e.g. across I/O),
/// use `getCloned()` which deep-clones into a caller-owned arena.
pub fn Store(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        mutex: std.Thread.RwLock = .{},
        items: ItemMap = .empty,
        synced: bool = false,
        logger: Logger = Logger.noop,

        const ItemMap = std.HashMapUnmanaged(
            ObjectKey,
            *Entry,
            ObjectKeyContext,
            std.hash_map.default_max_load_percentage,
        );

        /// A stored object with its memory-owning arena and reference count.
        /// Callers must call `release()` when done with a retained entry.
        pub const Entry = struct {
            rc: std.atomic.Value(u32) = .init(1),
            key: ObjectKey,
            object: T,
            arena: *std.heap.ArenaAllocator,
            backing_allocator: std.mem.Allocator,

            /// Increment the reference count.
            pub fn retain(self: *Entry) void {
                _ = self.rc.fetchAdd(1, .monotonic);
            }

            /// Decrement the reference count. When it reaches zero,
            /// free all memory owned by this entry.
            pub fn release(self: *Entry) void {
                if (self.rc.fetchSub(1, .acq_rel) == 1) {
                    const alloc = self.backing_allocator;
                    self.arena.deinit();
                    alloc.destroy(self.arena);
                    alloc.destroy(self);
                }
            }
        };

        /// Input for `replace()`: an object with its key and owning arena.
        pub const ReplaceItem = struct {
            key: ObjectKey,
            object: T,
            arena: *std.heap.ArenaAllocator,
        };

        /// Create an empty store backed by the given allocator.
        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        /// Free all stored objects and internal map storage.
        pub fn deinit(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            var it = self.items.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.*.release();
            }
            self.items.deinit(self.allocator);
        }

        // Read operations (shared lock)
        /// Get a single object by key.
        /// Returns a retained `*Entry`. The caller must call `entry.release()`
        /// when done. The lock is NOT held across the caller boundary.
        pub fn get(self: *Self, key: ObjectKey) ?*Entry {
            self.mutex.lockShared();
            defer self.mutex.unlockShared();
            const entry = self.items.get(key) orelse return null;
            entry.retain();
            return entry;
        }

        /// A deep-cloned object returned by `getCloned()`. Owns its
        /// memory via an arena. Call `deinit()` to free.
        pub const GetResult = struct {
            object: T,
            arena: *std.heap.ArenaAllocator,
            backing_allocator: std.mem.Allocator,

            /// Free the arena and all cloned memory.
            pub fn deinit(self: GetResult) void {
                self.arena.deinit();
                self.backing_allocator.destroy(self.arena);
            }
        };

        /// Get a single object by key, deep-cloned into a caller-owned arena.
        /// The lock is released before returning. Use this instead of `get()`
        /// when the data must outlive the lock (e.g. across I/O operations).
        pub fn getCloned(self: *Self, allocator: std.mem.Allocator, key: ObjectKey) error{OutOfMemory}!?GetResult {
            // Retain the entry under the shared lock, then release the lock
            // before deep-cloning. Entries are immutable after creation, so
            // reading the object outside the lock is safe. This keeps the
            // lock held only for the HashMap lookup + atomic increment,
            // not for the potentially expensive deep clone.
            const entry = blk: {
                self.mutex.lockShared();
                defer self.mutex.unlockShared();
                const e = self.items.get(key) orelse return null;
                e.retain();
                break :blk e;
            };
            defer entry.release();

            const arena = try allocator.create(std.heap.ArenaAllocator);
            arena.* = std.heap.ArenaAllocator.init(allocator);
            errdefer {
                arena.deinit();
                allocator.destroy(arena);
            }
            const cloned = try deepClone(T, arena.allocator(), entry.object);
            return .{ .object = cloned, .arena = arena, .backing_allocator = allocator };
        }

        /// Check whether a key exists in the store without returning an entry.
        /// Cheaper than `get()` when the caller only needs an existence check.
        pub fn contains(self: *Self, key: ObjectKey) bool {
            self.mutex.lockShared();
            defer self.mutex.unlockShared();
            return self.items.contains(key);
        }

        /// Get the number of cached objects.
        pub fn len(self: *Self) u32 {
            self.mutex.lockShared();
            defer self.mutex.unlockShared();
            return self.items.count();
        }

        /// Has the store been populated by at least one complete list?
        pub fn hasSynced(self: *Self) bool {
            self.mutex.lockShared();
            defer self.mutex.unlockShared();
            return self.synced;
        }

        /// A snapshot of cached objects returned by `list()`.
        ///
        /// Each element is a retained `*Entry` with `key` and `object` fields.
        /// The caller must call `release()` when done, which releases all
        /// entry references and frees the slice.
        pub const ListResult = struct {
            entries: []*Entry,
            allocator: std.mem.Allocator,

            /// Release all entry references and free the slice.
            pub fn release(self: ListResult) void {
                for (self.entries) |entry| entry.release();
                self.allocator.free(self.entries);
            }
        };

        /// Result of `replace()`: entries removed from the store (present in
        /// old but absent from new). `entries` is a sub-slice of `allocation`;
        /// call `release()` to free both the entries and the backing buffer.
        pub const ReplaceResult = struct {
            entries: []*Entry,
            allocation: []*Entry,
            allocator: std.mem.Allocator,

            /// Release removed entry references and free the backing buffer.
            pub fn release(self: ReplaceResult) void {
                for (self.entries) |entry| entry.release();
                self.allocator.free(self.allocation);
            }
        };

        /// Returns a snapshot of all cached objects as retained entries.
        ///
        /// The shared lock is held during the allocation and fill phase
        /// (one alloc + N atomic increments + N pointer copies). This is
        /// required for correctness: entries cannot be retained outside the
        /// lock because a concurrent writer could free them between
        /// iteration and the atomic increment. The lock is NOT held after
        /// returning, so callers can process entries without blocking
        /// writers.
        ///
        /// The caller must call `release()` on the returned `ListResult`
        /// when done.
        pub fn list(self: *Self, allocator: std.mem.Allocator) !ListResult {
            self.mutex.lockShared();
            defer self.mutex.unlockShared();

            // Allocate
            const entries = try allocator.alloc(*Entry, self.items.count());
            errdefer allocator.free(entries);

            // Fill and retain
            var i: usize = 0;
            var it = self.items.iterator();
            while (it.next()) |map_entry| {
                map_entry.value_ptr.*.retain();
                entries[i] = map_entry.value_ptr.*;
                i += 1;
            }

            return .{
                .entries = entries,
                .allocator = allocator,
            };
        }

        // Read-only view
        /// A read-only handle to the store. Exposes only read methods,
        /// preventing external code from mutating the store contents.
        pub const View = struct {
            store: *Self,

            /// Get a single object by key. See `Store.get()`.
            pub fn get(self: View, key: ObjectKey) ?*Entry {
                return self.store.get(key);
            }

            /// Get a deep-cloned copy of an object by key. See `Store.getCloned()`.
            pub fn getCloned(self: View, allocator: std.mem.Allocator, key: ObjectKey) error{OutOfMemory}!?GetResult {
                return self.store.getCloned(allocator, key);
            }

            /// Check whether a key exists in the store.
            pub fn contains(self: View, key: ObjectKey) bool {
                return self.store.contains(key);
            }

            /// Return the number of cached objects.
            pub fn len(self: View) u32 {
                return self.store.len();
            }

            /// Return whether the store has been populated by at least one complete list.
            pub fn hasSynced(self: View) bool {
                return self.store.hasSynced();
            }

            /// Return a snapshot of all cached objects as retained entries.
            pub fn list(self: View, allocator: std.mem.Allocator) !ListResult {
                return self.store.list(allocator);
            }
        };

        // Write operations (exclusive lock)
        /// Build a new ItemMap from a slice of ReplaceItems.
        /// On error, ALL arenas in new_items are freed: processed items
        /// (including duplicates) via release/direct free, unprocessed
        /// items via direct arena free. The caller must not free arenas.
        fn buildNewMap(self: *Self, new_items: []const ReplaceItem) !ItemMap {
            var new_map: ItemMap = .empty;
            var items_consumed: usize = 0;

            errdefer {
                // Free entries already inserted into the map (owns their arenas).
                var it = new_map.iterator();
                while (it.next()) |entry| {
                    entry.value_ptr.*.release();
                }
                new_map.deinit(self.allocator);

                // Free arenas for items not yet consumed.
                for (new_items[items_consumed..]) |item| {
                    item.arena.deinit();
                    self.allocator.destroy(item.arena);
                }
            }

            try new_map.ensureTotalCapacity(self.allocator, std.math.cast(ItemMap.Size, new_items.len) orelse return error.Overflow);

            for (new_items) |item| {
                const entry = try self.allocator.create(Entry);
                items_consumed += 1;

                entry.* = .{
                    .key = item.key,
                    .object = item.object,
                    .arena = item.arena,
                    .backing_allocator = self.allocator,
                };
                const gop = new_map.getOrPutAssumeCapacity(item.key);
                if (gop.found_existing) {
                    // Duplicate key in input; discard the new entry wrapper
                    // and free the duplicate item's arena to prevent a leak.
                    // Keep the first occurrence.
                    self.logger.warn("replace: duplicate key, keeping first", &.{
                        LogField.string("namespace", item.key.namespace),
                        LogField.string("name", item.key.name),
                    });
                    item.arena.deinit();
                    self.allocator.destroy(item.arena);
                    self.allocator.destroy(entry);
                } else {
                    gop.value_ptr.* = entry;
                }
            }

            return new_map;
        }

        /// Replace the entire store contents atomically, returning entries
        /// that were in the old store but not in the new set.
        ///
        /// Takes unconditional ownership of all arenas in `new_items`, both
        /// on success and error. On error, all arenas are freed by this
        /// function; the caller must only free the `new_items` slice itself.
        /// On success, the caller must call `result.release()` after
        /// dispatching delete events for the removed entries.
        pub fn replace(self: *Self, new_items: []const ReplaceItem) !ReplaceResult {
            const new_map = try self.buildNewMap(new_items);

            // Take exclusive lock for swap and classification of old entries.
            self.mutex.lock();
            const old_count = self.items.count();

            // Fast path: nothing to remove.
            if (old_count == 0) {
                self.items = new_map;
                self.synced = true;
                self.mutex.unlock();
                return .{
                    .entries = &.{},
                    .allocation = &.{},
                    .allocator = self.allocator,
                };
            }

            // Pre-allocate removed buffer BEFORE the swap (point of no return).
            const removed_buf = self.allocator.alloc(*Entry, old_count) catch {
                // Pre-alloc failed: swap never happened, release new_map entries.
                self.mutex.unlock();
                var it = new_map.iterator();
                while (it.next()) |entry| {
                    entry.value_ptr.*.release();
                }
                // Use a mutable copy for deinit since new_map is const.
                var map_copy = new_map;
                map_copy.deinit(self.allocator);
                return error.OutOfMemory;
            };

            // Point of no return: swap maps.
            var old_map = self.items;
            self.items = new_map;
            self.synced = true;

            // Classify old entries while still holding the exclusive lock.
            // new_map and self.items share the same backing storage (shallow
            // copy of HashMapUnmanaged), so a concurrent put()/remove() after
            // unlock would mutate the memory that new_map.get() reads from.
            var removed_count: usize = 0;
            var old_it = old_map.iterator();
            while (old_it.next()) |entry| {
                if (new_map.get(entry.key_ptr.*) == null) {
                    removed_buf[removed_count] = entry.value_ptr.*;
                    removed_count += 1;
                } else {
                    // Key exists in new map; release old entry.
                    entry.value_ptr.*.release();
                }
            }
            self.mutex.unlock();

            // old_map backing storage is exclusively owned; safe to free unlocked.
            old_map.deinit(self.allocator);

            return .{
                .entries = removed_buf[0..removed_count],
                .allocation = removed_buf,
                .allocator = self.allocator,
            };
        }

        /// Add or replace a single item in the store.
        ///
        /// On success, the store takes ownership of the arena.
        /// Returns the old entry if one existed. The caller must call
        /// `entry.release()` on it after handler dispatch.
        /// On error, ownership is NOT transferred.
        pub fn put(self: *Self, key: ObjectKey, object: T, arena: *std.heap.ArenaAllocator) !?*Entry {
            const entry = try self.allocator.create(Entry);
            entry.* = .{
                .key = key,
                .object = object,
                .arena = arena,
                .backing_allocator = self.allocator,
            };
            errdefer self.allocator.destroy(entry);

            self.mutex.lock();
            defer self.mutex.unlock();

            const gop = try self.items.getOrPut(self.allocator, key);
            if (gop.found_existing) {
                const old = gop.value_ptr.*;
                gop.value_ptr.* = entry;
                // Update key to point to new arena's strings (old key's
                // memory will be freed when caller releases the old entry).
                gop.key_ptr.* = key;
                return old;
            } else {
                gop.value_ptr.* = entry;
                return null;
            }
        }

        /// Remove an item from the store by key.
        /// Returns the removed entry. The caller must call `entry.release()`.
        /// Returns null if the key was not found.
        pub fn remove(self: *Self, key: ObjectKey) ?*Entry {
            self.mutex.lock();
            defer self.mutex.unlock();

            const result = self.items.fetchRemove(key);
            if (result) |kv| {
                return kv.value;
            }
            return null;
        }
    };
}

const TestResource = @import("../test_types.zig").TestResource;

/// Helper: create a TestResource entry owned by a new arena.
fn makeEntry(allocator: std.mem.Allocator, ns: []const u8, name: []const u8, replicas: i64) !Store(TestResource).ReplaceItem {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }

    const owned_ns = try arena.allocator().dupe(u8, ns);
    const owned_name = try arena.allocator().dupe(u8, name);

    return .{
        .key = .{ .namespace = owned_ns, .name = owned_name },
        .object = .{
            .metadata = .{ .name = owned_name, .namespace = owned_ns },
            .spec = .{ .replicas = replicas },
        },
        .arena = arena,
    };
}

test "ObjectKey: fromResource extracts namespace and name" {
    // Arrange
    const obj = TestResource{
        .metadata = .{ .name = "my-pod", .namespace = "default" },
    };

    // Act
    const key = ObjectKey.fromResource(TestResource, obj).?;

    // Assert
    try testing.expectEqualStrings("default", key.namespace);
    try testing.expectEqualStrings("my-pod", key.name);
}

test "ObjectKey: fromResource returns empty namespace for cluster-scoped" {
    // Arrange
    const obj = TestResource{
        .metadata = .{ .name = "my-node" },
    };

    // Act
    const key = ObjectKey.fromResource(TestResource, obj).?;

    // Assert
    try testing.expectEqualStrings("", key.namespace);
    try testing.expectEqualStrings("my-node", key.name);
}

test "ObjectKey: fromResource returns null for missing metadata" {
    // Arrange
    const obj = TestResource{};

    // Act / Assert
    try testing.expect(ObjectKey.fromResource(TestResource, obj) == null);
}

test "ObjectKey: fromResource returns null for missing name" {
    // Arrange
    const obj = TestResource{ .metadata = .{} };

    // Act / Assert
    try testing.expect(ObjectKey.fromResource(TestResource, obj) == null);
}

test "ObjectKey: equality" {
    // Arrange
    const a = ObjectKey{ .namespace = "ns", .name = "foo" };
    const b = ObjectKey{ .namespace = "ns", .name = "foo" };
    const c = ObjectKey{ .namespace = "ns", .name = "bar" };

    // Act / Assert
    try testing.expect(a.eql(b));
    try testing.expect(!a.eql(c));
}

test "ObjectKey: hash consistency" {
    // Arrange
    const a = ObjectKey{ .namespace = "ns", .name = "foo" };
    const b = ObjectKey{ .namespace = "ns", .name = "foo" };

    // Act / Assert
    try testing.expectEqual(a.hash(), b.hash());
}

test "ObjectKey: different keys have different hashes (basic)" {
    // Arrange
    const a = ObjectKey{ .namespace = "ns", .name = "foo" };
    const b = ObjectKey{ .namespace = "ns", .name = "bar" };

    // Act / Assert
    try testing.expect(a.hash() != b.hash());
}

test "Store: empty store" {
    // Arrange
    var store = Store(TestResource).init(testing.allocator);
    defer store.deinit();

    // Act / Assert
    try testing.expectEqual(@as(u32, 0), store.len());
    try testing.expect(!store.hasSynced());
    try testing.expect(store.get(.{ .namespace = "ns", .name = "x" }) == null);
}

test "Store: contains returns true for existing key and false for missing" {
    // Arrange
    var store = Store(TestResource).init(testing.allocator);
    defer store.deinit();

    // Act
    var items = [_]Store(TestResource).ReplaceItem{
        try makeEntry(testing.allocator, "default", "pod-1", 1),
    };
    const replace_result = try store.replace(&items);
    replace_result.release();

    // Assert
    try testing.expect(store.contains(.{ .namespace = "default", .name = "pod-1" }));
    try testing.expect(!store.contains(.{ .namespace = "default", .name = "pod-2" }));
    try testing.expect(!store.contains(.{ .namespace = "other", .name = "pod-1" }));
}

test "Store: contains returns false for empty store" {
    // Arrange
    var store = Store(TestResource).init(testing.allocator);
    defer store.deinit();

    // Act / Assert
    try testing.expect(!store.contains(.{ .namespace = "default", .name = "pod-1" }));
}

test "Store: get returns retained entry" {
    // Arrange
    var store = Store(TestResource).init(testing.allocator);
    defer store.deinit();

    // Act
    var items = [_]Store(TestResource).ReplaceItem{
        try makeEntry(testing.allocator, "default", "pod-1", 1),
    };
    const replace_result = try store.replace(&items);
    replace_result.release();

    // Assert
    const entry = store.get(.{ .namespace = "default", .name = "pod-1" }).?;
    defer entry.release();

    try testing.expectEqual(@as(i64, 1), entry.object.spec.?.replicas.?);
}

test "Store: getCloned returns owned copy independent of store" {
    // Arrange
    var store = Store(TestResource).init(testing.allocator);
    defer store.deinit();

    var items = [_]Store(TestResource).ReplaceItem{
        try makeEntry(testing.allocator, "default", "pod-1", 1),
    };
    const replace_result1 = try store.replace(&items);
    replace_result1.release();

    // Act
    const result = (try store.getCloned(testing.allocator, .{ .namespace = "default", .name = "pod-1" })).?;
    defer result.deinit();

    // Mutate store; the cloned data must remain valid.
    const replace_result2 = try store.replace(&.{});
    replace_result2.release();

    // Assert
    try testing.expectEqual(@as(i64, 1), result.object.spec.?.replicas.?);
    try testing.expectEqualStrings("pod-1", result.object.metadata.?.name.?);
}

test "Store: getCloned returns null for missing key" {
    // Arrange
    var store = Store(TestResource).init(testing.allocator);
    defer store.deinit();

    // Act / Assert
    try testing.expect(try store.getCloned(testing.allocator, .{ .namespace = "ns", .name = "x" }) == null);
}

test "Store: replace populates store and marks synced" {
    // Arrange
    var store = Store(TestResource).init(testing.allocator);
    defer store.deinit();

    // Act
    var items = [_]Store(TestResource).ReplaceItem{
        try makeEntry(testing.allocator, "default", "pod-1", 1),
        try makeEntry(testing.allocator, "default", "pod-2", 2),
    };
    const replace_result = try store.replace(&items);
    replace_result.release();

    // Assert
    try testing.expectEqual(@as(u32, 2), store.len());
    try testing.expect(store.hasSynced());

    const e1 = store.get(.{ .namespace = "default", .name = "pod-1" }).?;
    defer e1.release();
    try testing.expectEqual(@as(i64, 1), e1.object.spec.?.replicas.?);

    const e2 = store.get(.{ .namespace = "default", .name = "pod-2" }).?;
    defer e2.release();
    try testing.expectEqual(@as(i64, 2), e2.object.spec.?.replicas.?);
}

test "Store: replace removes old items not in new list" {
    // Arrange
    var store = Store(TestResource).init(testing.allocator);
    defer store.deinit();

    // Act
    var items1 = [_]Store(TestResource).ReplaceItem{
        try makeEntry(testing.allocator, "default", "pod-1", 1),
        try makeEntry(testing.allocator, "default", "pod-2", 2),
    };
    const replace_result1 = try store.replace(&items1);
    replace_result1.release();
    try testing.expectEqual(@as(u32, 2), store.len());

    // Replace with only pod-2
    var items2 = [_]Store(TestResource).ReplaceItem{
        try makeEntry(testing.allocator, "default", "pod-2", 20),
    };
    const replace_result2 = try store.replace(&items2);

    // Assert
    try testing.expectEqual(@as(usize, 1), replace_result2.entries.len);
    replace_result2.release();

    try testing.expectEqual(@as(u32, 1), store.len());
    try testing.expect(store.get(.{ .namespace = "default", .name = "pod-1" }) == null);

    const e2 = store.get(.{ .namespace = "default", .name = "pod-2" }).?;
    defer e2.release();
    try testing.expectEqual(@as(i64, 20), e2.object.spec.?.replicas.?);
}

test "Store: replace with empty list clears store" {
    // Arrange
    var store = Store(TestResource).init(testing.allocator);
    defer store.deinit();

    // Act
    var items = [_]Store(TestResource).ReplaceItem{
        try makeEntry(testing.allocator, "default", "pod-1", 1),
    };
    const replace_result1 = try store.replace(&items);
    replace_result1.release();
    try testing.expectEqual(@as(u32, 1), store.len());

    // Assert
    const replace_result2 = try store.replace(&.{});
    replace_result2.release();

    try testing.expectEqual(@as(u32, 0), store.len());
    try testing.expect(store.hasSynced()); // still synced
}

test "Store: put adds new item" {
    // Arrange
    var store = Store(TestResource).init(testing.allocator);
    defer store.deinit();

    // Act
    const item = try makeEntry(testing.allocator, "default", "pod-1", 3);

    // Assert
    const old = try store.put(item.key, item.object, item.arena);

    try testing.expect(old == null);
    try testing.expectEqual(@as(u32, 1), store.len());

    const entry = store.get(.{ .namespace = "default", .name = "pod-1" }).?;
    defer entry.release();
    try testing.expectEqual(@as(i64, 3), entry.object.spec.?.replicas.?);
}

test "Store: put replaces existing item and returns old" {
    // Arrange
    var store = Store(TestResource).init(testing.allocator);
    defer store.deinit();

    // Act
    const item1 = try makeEntry(testing.allocator, "default", "pod-1", 1);
    const old1 = try store.put(item1.key, item1.object, item1.arena);
    try testing.expect(old1 == null);

    // Assert
    const item2 = try makeEntry(testing.allocator, "default", "pod-1", 5);

    const old2 = try store.put(item2.key, item2.object, item2.arena);

    try testing.expect(old2 != null);
    try testing.expectEqual(@as(i64, 1), old2.?.object.spec.?.replicas.?);
    old2.?.release();

    const entry = store.get(.{ .namespace = "default", .name = "pod-1" }).?;
    defer entry.release();
    try testing.expectEqual(@as(i64, 5), entry.object.spec.?.replicas.?);
}

test "Store: remove returns entry" {
    // Arrange
    var store = Store(TestResource).init(testing.allocator);
    defer store.deinit();

    // Act
    const item = try makeEntry(testing.allocator, "default", "pod-1", 1);
    _ = try store.put(item.key, item.object, item.arena);

    // Assert
    const removed = store.remove(.{ .namespace = "default", .name = "pod-1" });

    try testing.expect(removed != null);
    try testing.expectEqual(@as(i64, 1), removed.?.object.spec.?.replicas.?);
    removed.?.release();

    try testing.expectEqual(@as(u32, 0), store.len());
}

test "Store: remove returns null for nonexistent key" {
    // Arrange
    var store = Store(TestResource).init(testing.allocator);
    defer store.deinit();

    // Act / Assert
    try testing.expect(store.remove(.{ .namespace = "ns", .name = "nope" }) == null);
}

test "Store: list iterates all objects" {
    // Arrange
    var store = Store(TestResource).init(testing.allocator);
    defer store.deinit();

    // Act
    var items = [_]Store(TestResource).ReplaceItem{
        try makeEntry(testing.allocator, "default", "pod-1", 1),
        try makeEntry(testing.allocator, "default", "pod-2", 2),
        try makeEntry(testing.allocator, "default", "pod-3", 3),
    };
    const replace_result = try store.replace(&items);
    replace_result.release();

    const result = try store.list(testing.allocator);
    defer result.release();

    // Assert
    try testing.expectEqual(@as(usize, 3), result.entries.len);
}

test "Store: hasSynced starts false, becomes true after replace" {
    // Arrange
    var store = Store(TestResource).init(testing.allocator);
    defer store.deinit();

    // Act
    try testing.expect(!store.hasSynced());

    // Assert
    const replace_result = try store.replace(&.{});
    replace_result.release();

    try testing.expect(store.hasSynced());
}

// Multi-namespace test helper
/// Populate a store with items across multiple namespaces.
fn populateMultiNs(store: *Store(TestResource)) !void {
    var items = [_]Store(TestResource).ReplaceItem{
        try makeEntry(testing.allocator, "default", "pod-1", 1),
        try makeEntry(testing.allocator, "default", "pod-2", 2),
        try makeEntry(testing.allocator, "kube-system", "coredns", 3),
    };
    const replace_result = try store.replace(&items);
    replace_result.release();
}

// list() tests
test "Store: list empty store returns 0-length slice" {
    // Arrange
    var store = Store(TestResource).init(testing.allocator);
    defer store.deinit();

    // Act
    const result = try store.list(testing.allocator);
    defer result.release();

    // Assert
    try testing.expectEqual(@as(usize, 0), result.entries.len);
}

test "Store: list returns all entries" {
    // Arrange
    var store = Store(TestResource).init(testing.allocator);
    defer store.deinit();
    try populateMultiNs(&store);

    // Act
    const result = try store.list(testing.allocator);
    defer result.release();

    // Assert
    try testing.expectEqual(@as(usize, 3), result.entries.len);

    // Verify all keys are present (order not guaranteed).
    var found_pod1 = false;
    var found_pod2 = false;
    var found_coredns = false;
    for (result.entries) |entry| {
        if (std.mem.eql(u8, entry.key.name, "pod-1")) found_pod1 = true;
        if (std.mem.eql(u8, entry.key.name, "pod-2")) found_pod2 = true;
        if (std.mem.eql(u8, entry.key.name, "coredns")) found_coredns = true;
    }
    try testing.expect(found_pod1);
    try testing.expect(found_pod2);
    try testing.expect(found_coredns);
}

test "Store: list returns accessible objects" {
    // Arrange
    var store = Store(TestResource).init(testing.allocator);
    defer store.deinit();
    try populateMultiNs(&store);

    // Act
    const result = try store.list(testing.allocator);
    defer result.release();

    // Assert
    for (result.entries) |entry| {
        if (std.mem.eql(u8, entry.key.name, "pod-1")) {
            try testing.expectEqual(@as(i64, 1), entry.object.spec.?.replicas.?);
        }
        if (std.mem.eql(u8, entry.key.name, "coredns")) {
            try testing.expectEqual(@as(i64, 3), entry.object.spec.?.replicas.?);
        }
    }
}

test "Store: list entries remain valid after store mutation" {
    // Arrange
    var store = Store(TestResource).init(testing.allocator);
    defer store.deinit();
    try populateMultiNs(&store);

    // Act
    const result = try store.list(testing.allocator);

    // Mutate the store; entries should remain valid due to refcounting.
    const replace_result = try store.replace(&.{});
    replace_result.release();

    // Assert
    try testing.expectEqual(@as(usize, 3), result.entries.len);
    for (result.entries) |entry| {
        try testing.expect(entry.object.metadata != null);
    }
    result.release();
}

// OOM tests
test "Store: put OOM on entry allocation does not corrupt store" {
    // Arrange
    var fa = std.testing.FailingAllocator.init(testing.allocator, .{});
    var fail_store = Store(TestResource).init(fa.allocator());
    defer fail_store.deinit();

    // Act
    const item = try makeEntry(testing.allocator, "default", "pod-1", 1);

    // Assert
    // Make next allocation fail (Entry.create inside put)
    fa.fail_index = fa.alloc_index;

    try testing.expectError(error.OutOfMemory, fail_store.put(item.key, item.object, item.arena));

    try testing.expectEqual(@as(u32, 0), fail_store.len());

    // Cleanup: free the arena that was never taken by the store
    item.arena.deinit();
    testing.allocator.destroy(item.arena);
}

// Concurrency tests
test "Store: concurrent reads and writes do not crash" {
    // Arrange
    var store = Store(TestResource).init(testing.allocator);
    defer store.deinit();

    // Act
    var items = [_]Store(TestResource).ReplaceItem{
        try makeEntry(testing.allocator, "default", "pod-1", 1),
    };
    const replace_result = try store.replace(&items);
    replace_result.release();

    // Assert
    const Reader = struct {
        fn run(view: Store(TestResource).View) void {
            for (0..50) |_| {
                const entry = view.get(.{ .namespace = "default", .name = "pod-1" });
                if (entry) |e| e.release();
                _ = view.len();
                _ = view.hasSynced();
            }
        }
    };

    const Writer = struct {
        fn run(s: *Store(TestResource)) void {
            for (0..20) |i| {
                const entry_item = makeEntry(testing.allocator, "default", "pod-w", @intCast(i)) catch continue;
                const old = s.put(entry_item.key, entry_item.object, entry_item.arena) catch continue;
                if (old) |o| o.release();
            }
        }
    };

    const view: Store(TestResource).View = .{ .store = &store };
    var threads: [3]std.Thread = undefined;
    threads[0] = try std.Thread.spawn(.{}, Reader.run, .{view});
    threads[1] = try std.Thread.spawn(.{}, Reader.run, .{view});
    threads[2] = try std.Thread.spawn(.{}, Writer.run, .{&store});

    for (&threads) |t| t.join();

    try testing.expect(store.len() >= 1);
}

// Duplicate key tests
test "Store: replace with duplicate keys keeps first occurrence" {
    // Arrange
    var store = Store(TestResource).init(testing.allocator);
    defer store.deinit();

    // Act
    const item1 = try makeEntry(testing.allocator, "default", "pod-dup", 1);
    const item2 = try makeEntry(testing.allocator, "default", "pod-dup", 99);

    var dup_items = [_]Store(TestResource).ReplaceItem{ item1, item2 };
    const replace_result = try store.replace(&dup_items);
    replace_result.release();

    // Assert
    try testing.expectEqual(@as(u32, 1), store.len());

    const entry = store.get(.{ .namespace = "default", .name = "pod-dup" }).?;
    defer entry.release();
    try testing.expectEqual(@as(i64, 1), entry.object.spec.?.replicas.?);
}

test "Store: replace with duplicate keys among non-duplicates" {
    // Arrange
    var store = Store(TestResource).init(testing.allocator);
    defer store.deinit();

    // Act
    const item1 = try makeEntry(testing.allocator, "default", "pod-a", 1);
    const item2 = try makeEntry(testing.allocator, "default", "pod-b", 2);
    const item3 = try makeEntry(testing.allocator, "default", "pod-a", 3); // duplicate of item1

    var dup_items = [_]Store(TestResource).ReplaceItem{ item1, item2, item3 };
    const replace_result = try store.replace(&dup_items);
    replace_result.release();

    // Assert
    try testing.expectEqual(@as(u32, 2), store.len());

    const ea = store.get(.{ .namespace = "default", .name = "pod-a" }).?;
    defer ea.release();
    try testing.expectEqual(@as(i64, 1), ea.object.spec.?.replicas.?); // first wins

    const eb = store.get(.{ .namespace = "default", .name = "pod-b" }).?;
    defer eb.release();
    try testing.expectEqual(@as(i64, 2), eb.object.spec.?.replicas.?);
}

// Refcount safety tests
test "Store: retained entry survives store replacement" {
    // Arrange
    var store = Store(TestResource).init(testing.allocator);
    defer store.deinit();

    var items = [_]Store(TestResource).ReplaceItem{
        try makeEntry(testing.allocator, "default", "pod-1", 42),
    };
    const replace_result1 = try store.replace(&items);
    replace_result1.release();

    // Act
    // Retain an entry, then replace the store (which would free it without refcount).
    const entry = store.get(.{ .namespace = "default", .name = "pod-1" }).?;

    const replace_result2 = try store.replace(&.{});
    replace_result2.release();

    // Assert
    // Entry is still accessible despite store being empty.
    try testing.expectEqual(@as(u32, 0), store.len());
    try testing.expectEqual(@as(i64, 42), entry.object.spec.?.replicas.?);
    try testing.expectEqualStrings("pod-1", entry.key.name);
    entry.release();
}

test "Store: multiple retains and releases work correctly" {
    // Arrange
    var store = Store(TestResource).init(testing.allocator);
    defer store.deinit();

    var items = [_]Store(TestResource).ReplaceItem{
        try makeEntry(testing.allocator, "default", "pod-1", 7),
    };
    const replace_result = try store.replace(&items);
    replace_result.release();

    // Act
    const e1 = store.get(.{ .namespace = "default", .name = "pod-1" }).?;
    const e2 = store.get(.{ .namespace = "default", .name = "pod-1" }).?;

    // Assert
    try testing.expectEqual(@as(i64, 7), e1.object.spec.?.replicas.?);
    try testing.expectEqual(@as(i64, 7), e2.object.spec.?.replicas.?);

    e1.release();
    e2.release();
}

// OOM safety for errdefer paths
test "Store: replace OOM on entry allocation cleans up partial map" {
    // Arrange
    var store = Store(TestResource).init(testing.allocator);
    defer store.deinit();

    // Act
    var initial = [_]Store(TestResource).ReplaceItem{
        try makeEntry(testing.allocator, "default", "existing", 1),
    };
    const replace_result_init = try store.replace(&initial);
    replace_result_init.release();

    // Assert
    const item1 = try makeEntry(testing.allocator, "default", "a", 10);
    const item2 = try makeEntry(testing.allocator, "default", "b", 20);

    var fa2 = std.testing.FailingAllocator.init(testing.allocator, .{});
    var fail_store2 = Store(TestResource).init(fa2.allocator());
    defer fail_store2.deinit();

    var new_items = [_]Store(TestResource).ReplaceItem{ item1, item2 };

    // Fail on the first allocation (ensureTotalCapacity).
    fa2.fail_index = fa2.alloc_index;

    const oom_result = fail_store2.replace(&new_items);
    try testing.expectError(error.OutOfMemory, oom_result);

    // Store is still empty and valid.
    // Arenas are freed by replace() on error (unconditional ownership).
    try testing.expectEqual(@as(u32, 0), fail_store2.len());
}

test "Store: replace OOM on second entry frees all arenas" {
    // Arrange
    // Use a FailingAllocator that allows ensureTotalCapacity and the first
    // Entry create, but fails on the second Entry create.
    var fa = std.testing.FailingAllocator.init(testing.allocator, .{});
    var fail_store = Store(TestResource).init(fa.allocator());
    defer fail_store.deinit();

    const item1 = try makeEntry(testing.allocator, "default", "a", 10);
    const item2 = try makeEntry(testing.allocator, "default", "b", 20);
    var new_items = [_]Store(TestResource).ReplaceItem{ item1, item2 };

    // Act
    // Allow ensureTotalCapacity + first Entry create, fail on the second.
    fa.fail_index = fa.alloc_index + 2;

    const oom_result = fail_store.replace(&new_items);

    // Assert
    try testing.expectError(error.OutOfMemory, oom_result);
    try testing.expectEqual(@as(u32, 0), fail_store.len());
    // All arenas freed by replace() on error; no manual cleanup needed.
}

test "Store: replace OOM on removed buffer pre-alloc does not swap" {
    // Arrange
    // Populate with one item using the real allocator, then switch to a
    // FailingAllocator for the second replace that will fail on pre-alloc.
    var store = Store(TestResource).init(testing.allocator);
    defer store.deinit();

    var initial = [_]Store(TestResource).ReplaceItem{
        try makeEntry(testing.allocator, "default", "existing", 1),
    };
    const replace_result_init = try store.replace(&initial);
    replace_result_init.release();
    try testing.expectEqual(@as(u32, 1), store.len());

    // Act
    // Create new items using a FailingAllocator. Allow buildNewMap to
    // succeed but fail on the removed_buf allocation.
    var fa = std.testing.FailingAllocator.init(testing.allocator, .{});
    store.allocator = fa.allocator();

    const item1 = try makeEntry(testing.allocator, "default", "x", 10);
    var new_items = [_]Store(TestResource).ReplaceItem{item1};

    // Allow ensureTotalCapacity + Entry create, fail on removed_buf alloc.
    fa.fail_index = fa.alloc_index + 2;

    const oom_result = store.replace(&new_items);

    // Assert
    // Restore real allocator for cleanup.
    store.allocator = testing.allocator;
    try testing.expectError(error.OutOfMemory, oom_result);

    // Swap must not have happened; old data should be intact.
    try testing.expectEqual(@as(u32, 1), store.len());
    const entry = store.get(.{ .namespace = "default", .name = "existing" }).?;
    defer entry.release();
    try testing.expectEqual(@as(i64, 1), entry.object.spec.?.replicas.?);
}

test "Store: list entries carry correct keys" {
    // Arrange
    var store = Store(TestResource).init(testing.allocator);
    defer store.deinit();
    try populateMultiNs(&store);

    // Act
    const result = try store.list(testing.allocator);
    defer result.release();

    // Assert
    var found_pod1 = false;
    var found_pod2 = false;
    var found_coredns = false;
    for (result.entries) |entry| {
        if (std.mem.eql(u8, entry.key.name, "pod-1") and std.mem.eql(u8, entry.key.namespace, "default")) found_pod1 = true;
        if (std.mem.eql(u8, entry.key.name, "pod-2") and std.mem.eql(u8, entry.key.namespace, "default")) found_pod2 = true;
        if (std.mem.eql(u8, entry.key.name, "coredns") and std.mem.eql(u8, entry.key.namespace, "kube-system")) found_coredns = true;
    }
    try testing.expect(found_pod1);
    try testing.expect(found_pod2);
    try testing.expect(found_coredns);
}
