//! Allocator-based deep cloning for Kubernetes resource structs.
//!
//! Recursively duplicates a value of any generated Kubernetes type,
//! copying all heap-referenced memory (slices, strings, maps, JSON
//! trees) into the provided allocator. Designed for cloning resources
//! into arena allocators without a JSON serialize/re-parse round-trip.

const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const json_helpers = @import("json_helpers.zig");

/// Deep-clone a value of type T, allocating all referenced memory
/// (slices, strings, nested containers) into the provided allocator.
///
/// Designed for cloning Kubernetes resource structs into arena allocators,
/// replacing the expensive JSON serialize/re-parse round-trip pattern.
///
/// Handles: primitives, optionals, slices (including []const u8 strings),
/// structs (recursive), tagged unions, single pointers, std.json.Value
/// trees, and managed ArrayHashMap containers (used for K8s labels,
/// annotations, and other map fields).
pub fn deepClone(comptime T: type, allocator: Allocator, value: T) Allocator.Error!T {
    return deepCloneImpl(T, allocator, value);
}

fn deepCloneImpl(comptime T: type, allocator: Allocator, value: T) Allocator.Error!T {
    const info = @typeInfo(T);

    switch (info) {
        .bool, .int, .float, .comptime_int, .comptime_float, .void, .@"enum", .enum_literal, .null => return value,

        .optional => |opt| {
            if (value) |v| {
                return try deepCloneImpl(opt.child, allocator, v);
            }
            return null;
        },

        .pointer => |ptr| {
            switch (ptr.size) {
                .slice => {
                    if (ptr.child == u8) {
                        // []const u8 (byte string): just dupe.
                        return try allocator.dupe(u8, value);
                    }
                    // []const SomeType: allocate new slice, clone each element.
                    const new_slice = try allocator.alloc(ptr.child, value.len);
                    for (value, 0..) |item, i| {
                        new_slice[i] = try deepCloneImpl(ptr.child, allocator, item);
                    }
                    return new_slice;
                },
                .one => {
                    const new_ptr = try allocator.create(ptr.child);
                    new_ptr.* = try deepCloneImpl(ptr.child, allocator, value.*);
                    return new_ptr;
                },
                else => @compileError("deepClone: unsupported pointer size for " ++ @typeName(T)),
            }
        },

        .@"union" => {
            // Special-case std.json.Value to properly handle its
            // managed ArrayList and ObjectMap internals.
            if (T == json.Value) {
                return cloneJsonValue(allocator, value);
            }
            return cloneTaggedUnion(T, allocator, value);
        },

        .@"struct" => {
            // Container types with internal MultiArrayList storage (which uses
            // [*]align pointers) cannot be cloned field-by-field. Detect and
            // clone via their public API instead.
            if (comptime json_helpers.isJsonArrayHashMap(T)) {
                return cloneJsonArrayHashMap(T, allocator, value);
            }
            if (comptime isManagedArrayHashMap(T)) {
                return cloneManagedArrayHashMap(T, allocator, value);
            }
            return cloneStruct(T, allocator, value);
        },

        else => @compileError("deepClone: unsupported type " ++ @typeName(T)),
    }
}

/// Detect managed std.ArrayHashMap types by their characteristic fields.
/// Managed maps have `unmanaged`, `allocator`, and `ctx` fields, where
/// the unmanaged inner type contains entries stored in a MultiArrayList.
fn isManagedArrayHashMap(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .@"struct") return false;
    return @hasField(T, "unmanaged") and @hasField(T, "allocator") and @hasField(T, "ctx");
}

fn cloneStruct(comptime T: type, allocator: Allocator, value: T) Allocator.Error!T {
    const struct_info = @typeInfo(T).@"struct";
    var result: T = undefined;
    inline for (struct_info.fields) |field| {
        @field(result, field.name) = try deepCloneImpl(field.type, allocator, @field(value, field.name));
    }
    return result;
}

fn cloneTaggedUnion(comptime T: type, allocator: Allocator, value: T) Allocator.Error!T {
    const union_info = @typeInfo(T).@"union";
    if (union_info.tag_type == null) {
        @compileError("deepClone: unsupported untagged union " ++ @typeName(T));
    }
    inline for (union_info.fields) |field| {
        if (value == @field(T, field.name)) {
            if (field.type == void) {
                return @unionInit(T, field.name, {});
            }
            return @unionInit(T, field.name, try deepCloneImpl(field.type, allocator, @field(value, field.name)));
        }
    }
    unreachable;
}

/// Clone a std.json.ArrayHashMap(V) by iterating its unmanaged inner map
/// and deep-cloning each key (string) and value into the target allocator.
fn cloneJsonArrayHashMap(comptime T: type, allocator: Allocator, value: T) Allocator.Error!T {
    var result: T = .{}; // .map = .empty (default)
    try result.map.ensureTotalCapacity(allocator, value.map.count());
    var it = value.map.iterator();
    while (it.next()) |entry| {
        const new_key = try allocator.dupe(u8, entry.key_ptr.*);
        const new_val = try deepCloneImpl(@TypeOf(entry.value_ptr.*), allocator, entry.value_ptr.*);
        result.map.putAssumeCapacityNoClobber(new_key, new_val);
    }
    return result;
}

/// Clone a managed ArrayHashMap by iterating its entries and deep-cloning
/// each key and value into the target allocator.
fn cloneManagedArrayHashMap(comptime T: type, allocator: Allocator, value: T) Allocator.Error!T {
    var new_map = T.init(allocator);
    try new_map.ensureTotalCapacity(value.count());
    var it = value.iterator();
    while (it.next()) |entry| {
        const new_key = try deepCloneImpl(@TypeOf(entry.key_ptr.*), allocator, entry.key_ptr.*);
        const new_val = try deepCloneImpl(@TypeOf(entry.value_ptr.*), allocator, entry.value_ptr.*);
        new_map.putAssumeCapacityNoClobber(new_key, new_val);
    }
    return new_map;
}

/// Clone a std.json.Value tree, allocating all strings, arrays, and object
/// maps into the target allocator.
fn cloneJsonValue(allocator: Allocator, value: json.Value) Allocator.Error!json.Value {
    switch (value) {
        .null => return .null,
        .bool => |b| return .{ .bool = b },
        .integer => |i| return .{ .integer = i },
        .float => |f| return .{ .float = f },
        .number_string => |s| return .{ .number_string = try allocator.dupe(u8, s) },
        .string => |s| return .{ .string = try allocator.dupe(u8, s) },
        .array => |arr| {
            var new_arr = @TypeOf(arr).init(allocator);
            try new_arr.ensureTotalCapacity(arr.items.len);
            for (arr.items) |item| {
                new_arr.appendAssumeCapacity(try cloneJsonValue(allocator, item));
            }
            return .{ .array = new_arr };
        },
        .object => |obj| {
            var new_obj: @TypeOf(obj) = .empty;
            try new_obj.ensureTotalCapacity(allocator, obj.count());
            var it = obj.iterator();
            while (it.next()) |entry| {
                const new_key = try allocator.dupe(u8, entry.key_ptr.*);
                const new_val = try cloneJsonValue(allocator, entry.value_ptr.*);
                new_obj.putAssumeCapacityNoClobber(new_key, new_val);
            }
            return .{ .object = new_obj };
        },
    }
}

const SimpleStruct = struct {
    name: ?[]const u8 = null,
    count: ?i64 = null,
    flag: bool = false,
};

const NestedStruct = struct {
    metadata: ?SimpleStruct = null,
    items: ?[]const SimpleStruct = null,
    tags: ?[]const []const u8 = null,
};

test "deepClone: primitives pass through" {
    // Act / Assert
    try testing.expectEqual(@as(i64, 42), try deepClone(i64, testing.allocator, 42));
    try testing.expectEqual(true, try deepClone(bool, testing.allocator, true));
}

test "deepClone: optional null" {
    // Arrange
    const result = try deepClone(?i64, testing.allocator, null);

    // Act / Assert
    try testing.expect(result == null);
}

test "deepClone: optional with value" {
    // Arrange
    const result = try deepClone(?i64, testing.allocator, 42);

    // Act / Assert
    try testing.expectEqual(@as(i64, 42), result.?);
}

test "deepClone: string is duped" {
    // Arrange
    const original: []const u8 = "hello";

    // Act
    const cloned = try deepClone([]const u8, testing.allocator, original);
    defer testing.allocator.free(cloned);

    // Assert
    try testing.expectEqualStrings("hello", cloned);
    // Must be a distinct allocation.
    try testing.expect(original.ptr != cloned.ptr);
}

test "deepClone: simple struct" {
    // Arrange
    const original = SimpleStruct{ .name = "test", .count = 5, .flag = true };

    // Act
    const cloned = try deepClone(SimpleStruct, testing.allocator, original);
    defer if (cloned.name) |n| testing.allocator.free(n);

    // Assert
    try testing.expectEqualStrings("test", cloned.name.?);
    try testing.expectEqual(@as(i64, 5), cloned.count.?);
    try testing.expectEqual(true, cloned.flag);
    try testing.expect(original.name.?.ptr != cloned.name.?.ptr);
}

test "deepClone: nested struct with slices" {
    // Arrange
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Act
    const items = [_]SimpleStruct{
        .{ .name = "a", .count = 1 },
        .{ .name = "b", .count = 2 },
    };
    const tags = [_][]const u8{ "tag1", "tag2" };
    const original = NestedStruct{
        .metadata = .{ .name = "parent", .count = 10 },
        .items = &items,
        .tags = &tags,
    };

    // Assert
    const cloned = try deepClone(NestedStruct, alloc, original);

    try testing.expectEqualStrings("parent", cloned.metadata.?.name.?);
    try testing.expectEqual(@as(i64, 10), cloned.metadata.?.count.?);
    try testing.expectEqual(@as(usize, 2), cloned.items.?.len);
    try testing.expectEqualStrings("a", cloned.items.?[0].name.?);
    try testing.expectEqualStrings("b", cloned.items.?[1].name.?);
    try testing.expectEqual(@as(usize, 2), cloned.tags.?.len);
    try testing.expectEqualStrings("tag1", cloned.tags.?[0]);
    try testing.expectEqualStrings("tag2", cloned.tags.?[1]);

    // Verify distinct allocations.
    try testing.expect(original.items.?.ptr != cloned.items.?.ptr);
    try testing.expect(original.tags.?.ptr != cloned.tags.?.ptr);
    try testing.expect(original.metadata.?.name.?.ptr != cloned.metadata.?.name.?.ptr);
}

test "deepClone: null optional struct" {
    // Arrange
    const original = NestedStruct{};

    // Act
    const cloned = try deepClone(NestedStruct, testing.allocator, original);

    // Assert
    try testing.expect(cloned.metadata == null);
    try testing.expect(cloned.items == null);
}

test "deepClone: json.Value null/bool/integer/float" {
    // Arrange
    const null_val: json.Value = .null;
    const bool_val = json.Value{ .bool = true };
    const int_val = json.Value{ .integer = 42 };
    const float_val = json.Value{ .float = 3.14 };

    // Act / Assert
    try testing.expect(try deepClone(json.Value, testing.allocator, null_val) == .null);
    try testing.expectEqual(true, (try deepClone(json.Value, testing.allocator, bool_val)).bool);
    try testing.expectEqual(@as(i64, 42), (try deepClone(json.Value, testing.allocator, int_val)).integer);
    try testing.expectEqual(@as(f64, 3.14), (try deepClone(json.Value, testing.allocator, float_val)).float);
}

test "deepClone: json.Value string" {
    // Arrange
    const original = json.Value{ .string = "hello" };

    // Act
    const cloned = try deepClone(json.Value, testing.allocator, original);
    defer testing.allocator.free(cloned.string);

    // Assert
    try testing.expectEqualStrings("hello", cloned.string);
    try testing.expect(original.string.ptr != cloned.string.ptr);
}

test "deepClone: json.Value array" {
    // Arrange
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Act
    // Build a json array: [1, "two", null]
    var arr = json.Array.init(alloc);
    try arr.appendSlice(&.{
        json.Value{ .integer = 1 },
        json.Value{ .string = "two" },
        .null,
    });
    const original = json.Value{ .array = arr };

    // Assert
    const cloned = try deepClone(json.Value, alloc, original);

    try testing.expectEqual(@as(usize, 3), cloned.array.items.len);
    try testing.expectEqual(@as(i64, 1), cloned.array.items[0].integer);
    try testing.expectEqualStrings("two", cloned.array.items[1].string);
    try testing.expect(cloned.array.items[2] == .null);
    // Distinct array storage.
    try testing.expect(original.array.items.ptr != cloned.array.items.ptr);
}

test "deepClone: json.Value object" {
    // Arrange
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Act
    var obj = json.ObjectMap.init(alloc);
    try obj.put("key1", json.Value{ .string = "val1" });
    try obj.put("key2", json.Value{ .integer = 99 });
    const original = json.Value{ .object = obj };

    // Assert
    const cloned = try deepClone(json.Value, alloc, original);

    try testing.expectEqual(@as(u32, 2), cloned.object.count());
    try testing.expectEqualStrings("val1", cloned.object.get("key1").?.string);
    try testing.expectEqual(@as(i64, 99), cloned.object.get("key2").?.integer);
}

test "deepClone: struct containing json.Value field" {
    // Arrange
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Act
    const Wrapper = struct {
        name: ?[]const u8 = null,
        data: ?json.Value = null,
    };

    // Assert
    const original = Wrapper{
        .name = "test",
        .data = json.Value{ .string = "payload" },
    };

    const cloned = try deepClone(Wrapper, alloc, original);

    try testing.expectEqualStrings("test", cloned.name.?);
    try testing.expectEqualStrings("payload", cloned.data.?.string);
    try testing.expect(original.name.?.ptr != cloned.name.?.ptr);
    try testing.expect(original.data.?.string.ptr != cloned.data.?.string.ptr);
}

test "deepClone: tagged union" {
    // Arrange
    const Event = union(enum) {
        added: SimpleStruct,
        removed: void,
        count: i64,
    };

    // Act
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Assert
    const original = Event{ .added = .{ .name = "pod-1", .count = 3 } };
    const void_event = Event{ .removed = {} };
    const int_event = Event{ .count = 42 };

    const cloned = try deepClone(Event, alloc, original);
    const cloned_void = try deepClone(Event, alloc, void_event);
    const cloned_int = try deepClone(Event, alloc, int_event);

    try testing.expectEqualStrings("pod-1", cloned.added.name.?);
    try testing.expectEqual(@as(i64, 3), cloned.added.count.?);
    try testing.expect(cloned_void == .removed);
    try testing.expectEqual(@as(i64, 42), cloned_int.count);
}

test "deepClone: empty slices" {
    // Arrange
    const empty_str: []const u8 = "";
    const empty_items: []const SimpleStruct = &.{};

    // Act
    const cloned_str = try deepClone([]const u8, testing.allocator, empty_str);
    defer testing.allocator.free(cloned_str);
    const cloned_items = try deepClone([]const SimpleStruct, testing.allocator, empty_items);
    defer testing.allocator.free(cloned_items);

    // Assert
    try testing.expectEqual(@as(usize, 0), cloned_str.len);
    try testing.expectEqual(@as(usize, 0), cloned_items.len);
}

test "deepClone: json.ArrayHashMap (string-to-string)" {
    // Arrange
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Act
    var original: json.ArrayHashMap([]const u8) = .{};
    try original.map.put(alloc, "key1", "val1");
    try original.map.put(alloc, "key2", "val2");

    // Assert
    const cloned = try deepClone(json.ArrayHashMap([]const u8), alloc, original);

    try testing.expectEqual(@as(u32, 2), cloned.map.count());
    try testing.expectEqualStrings("val1", cloned.map.get("key1").?);
    try testing.expectEqualStrings("val2", cloned.map.get("key2").?);
}

test "deepClone: struct with json.ArrayHashMap field" {
    // Arrange
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Act
    const Meta = struct {
        name: ?[]const u8 = null,
        labels: ?json.ArrayHashMap([]const u8) = null,
    };

    // Assert
    var labels: json.ArrayHashMap([]const u8) = .{};
    try labels.map.put(alloc, "app", "test");
    try labels.map.put(alloc, "env", "dev");

    const original = Meta{ .name = "my-pod", .labels = labels };

    const cloned = try deepClone(Meta, alloc, original);

    try testing.expectEqualStrings("my-pod", cloned.name.?);
    try testing.expectEqual(@as(u32, 2), cloned.labels.?.map.count());
    try testing.expectEqualStrings("test", cloned.labels.?.map.get("app").?);
    try testing.expectEqualStrings("dev", cloned.labels.?.map.get("env").?);
}

// OOM tests
test "deepClone: OOM on recursive clone does not leak" {
    // Arrange
    var fa = std.testing.FailingAllocator.init(testing.allocator, .{});
    const original = SimpleStruct{ .name = "test", .count = 5, .flag = true };

    // Act
    fa.fail_index = fa.alloc_index;

    // Assert
    try testing.expectError(error.OutOfMemory, deepClone(SimpleStruct, fa.allocator(), original));
}
