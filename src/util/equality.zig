//! Comptime-generic deep equality comparisons for Kubernetes resources.
//!
//! Provides allocation-free, read-only traversals that compare two values
//! of any generated Kubernetes struct type. Includes whole-resource
//! `deepEqual`, targeted field comparisons (`specEqual`, `statusEqual`,
//! `labelsEqual`, `annotationsEqual`), a metadata comparator that skips
//! server-managed fields, and `UpdatePredicate` factories for use with
//! the cache/informer layer.

const std = @import("std");
const json = std.json;
const resource_shape = @import("resource_shape.zig");
const testing = std.testing;

/// Comptime-generic deep equality for Kubernetes resource structs.
///
/// Recursively compares two values of any generated Kubernetes struct type,
/// returning true if they are semantically identical. Handles optionals,
/// slices (content-based, not pointer-based), `json.ArrayHashMap`,
/// `json.Value` trees, structs, and tagged unions.
///
/// Performs no memory allocation; all comparisons are read-only traversals.
pub fn deepEqual(comptime T: type, a: T, b: T) bool {
    return deepEqualImpl(T, a, b);
}

fn deepEqualImpl(comptime T: type, a: T, b: T) bool {
    const info = @typeInfo(T);

    switch (info) {
        .bool, .int, .float, .comptime_int, .comptime_float, .void, .@"enum", .enum_literal, .null => return a == b,

        .optional => |opt| {
            if (a == null and b == null) return true;
            if (a == null or b == null) return false;
            return deepEqualImpl(opt.child, a.?, b.?);
        },

        .pointer => |ptr| {
            switch (ptr.size) {
                .slice => {
                    if (ptr.child == u8) {
                        return std.mem.eql(u8, a, b);
                    }
                    if (a.len != b.len) return false;
                    for (a, b) |item_a, item_b| {
                        if (!deepEqualImpl(ptr.child, item_a, item_b)) return false;
                    }
                    return true;
                },
                .one => {
                    return deepEqualImpl(ptr.child, a.*, b.*);
                },
                else => @compileError("deepEqual: unsupported pointer size for " ++ @typeName(T)),
            }
        },

        .@"union" => {
            if (T == json.Value) {
                return jsonValueEqual(a, b);
            }
            return taggedUnionEqual(T, a, b);
        },

        .@"struct" => {
            if (comptime isJsonArrayHashMap(T)) {
                return jsonArrayHashMapEqual(T, a, b);
            }
            return structEqual(T, a, b);
        },

        else => @compileError("deepEqual: unsupported type " ++ @typeName(T)),
    }
}

/// Detect std.json.ArrayHashMap(V).
fn isJsonArrayHashMap(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .@"struct") return false;
    return @hasField(T, "map") and @hasDecl(T, "jsonStringify");
}

fn structEqual(comptime T: type, a: T, b: T) bool {
    const struct_info = @typeInfo(T).@"struct";
    inline for (struct_info.fields) |field| {
        if (!deepEqualImpl(field.type, @field(a, field.name), @field(b, field.name))) return false;
    }
    return true;
}

fn taggedUnionEqual(comptime T: type, a: T, b: T) bool {
    const union_info = @typeInfo(T).@"union";
    if (union_info.tag_type == null) {
        @compileError("deepEqual: unsupported untagged union " ++ @typeName(T));
    }
    inline for (union_info.fields) |field| {
        if (a == @field(T, field.name)) {
            if (b != @field(T, field.name)) return false;
            if (field.type == void) return true;
            return deepEqualImpl(field.type, @field(a, field.name), @field(b, field.name));
        }
    }
    unreachable;
}

fn jsonArrayHashMapEqual(comptime T: type, a: T, b: T) bool {
    if (a.map.count() != b.map.count()) return false;
    const V = @TypeOf(a.map).Value;
    var it = a.map.iterator();
    while (it.next()) |entry| {
        const b_val = b.map.get(entry.key_ptr.*) orelse return false;
        if (!deepEqualImpl(V, entry.value_ptr.*, b_val)) return false;
    }
    return true;
}

fn jsonValueEqual(a: json.Value, b: json.Value) bool {
    const Tag = std.meta.Tag(@TypeOf(a));
    const tag_a: Tag = a;
    const tag_b: Tag = b;
    if (tag_a != tag_b) return false;

    switch (a) {
        .null => return true,
        .bool => return a.bool == b.bool,
        .integer => return a.integer == b.integer,
        .float => return a.float == b.float,
        .number_string => return std.mem.eql(u8, a.number_string, b.number_string),
        .string => return std.mem.eql(u8, a.string, b.string),
        .array => {
            if (a.array.items.len != b.array.items.len) return false;
            for (a.array.items, b.array.items) |item_a, item_b| {
                if (!jsonValueEqual(item_a, item_b)) return false;
            }
            return true;
        },
        .object => {
            if (a.object.count() != b.object.count()) return false;
            var it = a.object.iterator();
            while (it.next()) |entry| {
                const b_val = b.object.get(entry.key_ptr.*) orelse return false;
                if (!jsonValueEqual(entry.value_ptr.*, b_val)) return false;
            }
            return true;
        },
    }
}

// Targeted helpers
/// Compare only the `.spec` field of two resources.
pub fn specEqual(comptime T: type, a: T, b: T) bool {
    comptime resource_shape.validateHasField(T, "spec", "specEqual");
    const SpecType = @TypeOf(@as(T, undefined).spec);
    return deepEqualImpl(SpecType, a.spec, b.spec);
}

/// Compare only the `.status` field of two resources.
pub fn statusEqual(comptime T: type, a: T, b: T) bool {
    comptime resource_shape.validateHasField(T, "status", "statusEqual");
    const StatusType = @TypeOf(@as(T, undefined).status);
    return deepEqualImpl(StatusType, a.status, b.status);
}

/// Compare only `.metadata.labels` of two resources.
pub fn labelsEqual(comptime T: type, a: T, b: T) bool {
    return optionalMetadataFieldEqual(T, "labels", a, b);
}

/// Compare only `.metadata.annotations` of two resources.
pub fn annotationsEqual(comptime T: type, a: T, b: T) bool {
    return optionalMetadataFieldEqual(T, "annotations", a, b);
}

fn optionalMetadataFieldEqual(comptime T: type, comptime field_name: []const u8, a: T, b: T) bool {
    comptime resource_shape.validateHasMetadata(T);
    const MetaType = @TypeOf(@as(T, undefined).metadata);
    const meta_info = @typeInfo(MetaType);

    if (meta_info == .optional) {
        const InnerMeta = meta_info.optional.child;
        if (!@hasField(InnerMeta, field_name)) @compileError("metadata type has no '" ++ field_name ++ "' field");

        const meta_a = a.metadata;
        const meta_b = b.metadata;
        if (meta_a == null and meta_b == null) return true;
        if (meta_a == null or meta_b == null) return false;

        const FieldType = @TypeOf(@field(@as(InnerMeta, undefined), field_name));
        return deepEqualImpl(FieldType, @field(meta_a.?, field_name), @field(meta_b.?, field_name));
    } else {
        if (!@hasField(MetaType, field_name)) @compileError("metadata type has no '" ++ field_name ++ "' field");
        const FieldType = @TypeOf(@field(@as(MetaType, undefined), field_name));
        return deepEqualImpl(FieldType, @field(a.metadata, field_name), @field(b.metadata, field_name));
    }
}

/// Compare metadata excluding server-managed fields (resourceVersion, uid,
/// creationTimestamp, managedFields, selfLink) that change on every write
/// and are not meaningful for semantic comparison. Returns true when
/// all non-excluded metadata fields are equal.
pub fn metadataEqual(comptime T: type, a: T, b: T) bool {
    comptime resource_shape.validateHasMetadata(T);
    const MetaType = @TypeOf(@as(T, undefined).metadata);
    const meta_info = @typeInfo(MetaType);

    if (meta_info == .optional) {
        const meta_a = a.metadata;
        const meta_b = b.metadata;
        if (meta_a == null and meta_b == null) return true;
        if (meta_a == null or meta_b == null) return false;
        return metadataFieldsEqual(meta_info.optional.child, meta_a.?, meta_b.?);
    } else {
        return metadataFieldsEqual(MetaType, a.metadata, b.metadata);
    }
}

const server_managed_meta_fields = [_][]const u8{
    "resourceVersion",
    "uid",
    "creationTimestamp",
    "managedFields",
    "selfLink",
};

fn isServerManagedField(comptime name: []const u8) bool {
    inline for (server_managed_meta_fields) |f| {
        if (comptime std.mem.eql(u8, name, f)) return true;
    }
    return false;
}

fn metadataFieldsEqual(comptime MetaType: type, a: MetaType, b: MetaType) bool {
    const struct_info = @typeInfo(MetaType).@"struct";
    inline for (struct_info.fields) |field| {
        if (comptime !isServerManagedField(field.name)) {
            if (!deepEqualImpl(field.type, @field(a, field.name), @field(b, field.name))) return false;
        }
    }
    return true;
}

// Predicate integration
const predicates = @import("../cache/predicates.zig");

/// Returns an `UpdatePredicate(T)` that passes only when the `.spec`
/// field actually changed. More accurate than `generationChanged` because
/// it checks actual content rather than relying on the generation counter.
pub fn specChanged(comptime T: type) predicates.UpdatePredicate(T) {
    return struct {
        fn pred(old: *const T, new: *const T) bool {
            return !specEqual(T, old.*, new.*);
        }
    }.pred;
}

/// Returns an `UpdatePredicate(T)` that passes when `.metadata.labels` differ.
pub fn labelsChanged(comptime T: type) predicates.UpdatePredicate(T) {
    return struct {
        fn pred(old: *const T, new: *const T) bool {
            return !labelsEqual(T, old.*, new.*);
        }
    }.pred;
}

/// Returns an `UpdatePredicate(T)` that passes when `.metadata.annotations` differ.
pub fn annotationsChanged(comptime T: type) predicates.UpdatePredicate(T) {
    return struct {
        fn pred(old: *const T, new: *const T) bool {
            return !annotationsEqual(T, old.*, new.*);
        }
    }.pred;
}

/// Returns an `UpdatePredicate(T)` that passes when `.status` differs.
pub fn statusChanged(comptime T: type) predicates.UpdatePredicate(T) {
    return struct {
        fn pred(old: *const T, new: *const T) bool {
            return !statusEqual(T, old.*, new.*);
        }
    }.pred;
}

const test_types = @import("../test_types.zig");
const TestOwnerRef = test_types.TestOwnerRef;
const TestMeta = test_types.TestMeta;
const TestSpec = test_types.TestSpec;
const TestStatus = test_types.TestStatus;
const TestResource = test_types.TestResource;

// deepEqual tests
test "deepEqual: two default (all-null) structs are equal" {
    // Arrange
    const a = TestResource{};
    const b = TestResource{};

    // Act / Assert
    try testing.expect(deepEqual(TestResource, a, b));
}

test "deepEqual: same non-null scalar fields are equal" {
    // Arrange
    const a = TestSpec{ .replicas = 3, .paused = true };
    const b = TestSpec{ .replicas = 3, .paused = true };

    // Act / Assert
    try testing.expect(deepEqual(TestSpec, a, b));
}

test "deepEqual: differing scalar field is not equal" {
    // Arrange
    const a = TestSpec{ .replicas = 3 };
    const b = TestSpec{ .replicas = 5 };

    // Act / Assert
    try testing.expect(!deepEqual(TestSpec, a, b));
}

test "deepEqual: null vs non-null optional is not equal" {
    // Arrange
    const a = TestSpec{ .replicas = null };
    const b = TestSpec{ .replicas = 3 };

    // Act / Assert
    try testing.expect(!deepEqual(TestSpec, a, b));
}

test "deepEqual: same string values are equal" {
    // Arrange
    const a = TestMeta{ .name = "my-pod" };
    const b = TestMeta{ .name = "my-pod" };

    // Act / Assert
    try testing.expect(deepEqual(TestMeta, a, b));
}

test "deepEqual: different string values are not equal" {
    // Arrange
    const a = TestMeta{ .name = "pod-a" };
    const b = TestMeta{ .name = "pod-b" };

    // Act / Assert
    try testing.expect(!deepEqual(TestMeta, a, b));
}

test "deepEqual: same slice contents, different pointers are equal" {
    // Arrange
    const items_a = [_][]const u8{ "a", "b", "c" };
    const items_b = [_][]const u8{ "a", "b", "c" };
    const a = TestMeta{ .finalizers = &items_a };
    const b = TestMeta{ .finalizers = &items_b };

    // Act / Assert
    try testing.expect(deepEqual(TestMeta, a, b));
}

test "deepEqual: different slice lengths are not equal" {
    // Arrange
    const items_a = [_][]const u8{ "a", "b" };
    const items_b = [_][]const u8{ "a", "b", "c" };
    const a = TestMeta{ .finalizers = &items_a };
    const b = TestMeta{ .finalizers = &items_b };

    // Act / Assert
    try testing.expect(!deepEqual(TestMeta, a, b));
}

test "deepEqual: same slice elements, one element differs is not equal" {
    // Arrange
    const items_a = [_][]const u8{ "a", "b", "c" };
    const items_b = [_][]const u8{ "a", "x", "c" };
    const a = TestMeta{ .finalizers = &items_a };
    const b = TestMeta{ .finalizers = &items_b };

    // Act / Assert
    try testing.expect(!deepEqual(TestMeta, a, b));
}

test "deepEqual: nested struct equality" {
    // Arrange
    const a = TestResource{ .spec = .{ .replicas = 3, .paused = false } };
    const b = TestResource{ .spec = .{ .replicas = 3, .paused = false } };

    // Act / Assert
    try testing.expect(deepEqual(TestResource, a, b));
}

test "deepEqual: nested struct inequality" {
    // Arrange
    const a = TestResource{ .spec = .{ .replicas = 3 } };
    const b = TestResource{ .spec = .{ .replicas = 5 } };

    // Act / Assert
    try testing.expect(!deepEqual(TestResource, a, b));
}

test "deepEqual: empty ArrayHashMap vs empty ArrayHashMap is equal" {
    // Arrange
    const a: json.ArrayHashMap([]const u8) = .{};
    const b: json.ArrayHashMap([]const u8) = .{};

    // Act / Assert
    try testing.expect(deepEqual(json.ArrayHashMap([]const u8), a, b));
}

test "deepEqual: same ArrayHashMap entries are equal" {
    // Arrange
    var a: json.ArrayHashMap([]const u8) = .{};
    defer a.map.deinit(testing.allocator);
    try a.map.put(testing.allocator, "app", "nginx");
    try a.map.put(testing.allocator, "env", "prod");

    // Act
    var b: json.ArrayHashMap([]const u8) = .{};
    defer b.map.deinit(testing.allocator);
    try b.map.put(testing.allocator, "app", "nginx");
    try b.map.put(testing.allocator, "env", "prod");

    // Assert
    try testing.expect(deepEqual(json.ArrayHashMap([]const u8), a, b));
}

test "deepEqual: different ArrayHashMap entries (different value) is not equal" {
    // Arrange
    var a: json.ArrayHashMap([]const u8) = .{};
    defer a.map.deinit(testing.allocator);
    try a.map.put(testing.allocator, "app", "nginx");

    // Act
    var b: json.ArrayHashMap([]const u8) = .{};
    defer b.map.deinit(testing.allocator);
    try b.map.put(testing.allocator, "app", "redis");

    // Assert
    try testing.expect(!deepEqual(json.ArrayHashMap([]const u8), a, b));
}

test "deepEqual: different ArrayHashMap entries (extra key) is not equal" {
    // Arrange
    var a: json.ArrayHashMap([]const u8) = .{};
    defer a.map.deinit(testing.allocator);
    try a.map.put(testing.allocator, "app", "nginx");

    // Act
    var b: json.ArrayHashMap([]const u8) = .{};
    defer b.map.deinit(testing.allocator);
    try b.map.put(testing.allocator, "app", "nginx");
    try b.map.put(testing.allocator, "env", "prod");

    // Assert
    try testing.expect(!deepEqual(json.ArrayHashMap([]const u8), a, b));
}

test "deepEqual: json.Value null, bool, integer, float, string" {
    // Act / Assert
    try testing.expect(deepEqual(json.Value, .null, .null));
    try testing.expect(deepEqual(json.Value, .{ .bool = true }, .{ .bool = true }));
    try testing.expect(!deepEqual(json.Value, .{ .bool = true }, .{ .bool = false }));
    try testing.expect(deepEqual(json.Value, .{ .integer = 42 }, .{ .integer = 42 }));
    try testing.expect(!deepEqual(json.Value, .{ .integer = 42 }, .{ .integer = 99 }));
    try testing.expect(deepEqual(json.Value, .{ .float = 3.14 }, .{ .float = 3.14 }));
    try testing.expect(!deepEqual(json.Value, .{ .float = 3.14 }, .{ .float = 2.71 }));
    try testing.expect(deepEqual(json.Value, .{ .string = "hello" }, .{ .string = "hello" }));
    try testing.expect(!deepEqual(json.Value, .{ .string = "hello" }, .{ .string = "world" }));
}

test "deepEqual: json.Value array same items are equal, different are not" {
    // Arrange
    var arr_a = json.Array.init(testing.allocator);
    defer arr_a.deinit();
    try arr_a.appendSlice(&.{ .{ .integer = 1 }, .{ .string = "two" } });

    // Act
    var arr_b = json.Array.init(testing.allocator);
    defer arr_b.deinit();
    try arr_b.appendSlice(&.{ .{ .integer = 1 }, .{ .string = "two" } });

    // Assert
    try testing.expect(deepEqual(json.Value, .{ .array = arr_a }, .{ .array = arr_b }));

    var arr_c = json.Array.init(testing.allocator);
    defer arr_c.deinit();
    try arr_c.appendSlice(&.{ .{ .integer = 1 }, .{ .string = "three" } });

    try testing.expect(!deepEqual(json.Value, .{ .array = arr_a }, .{ .array = arr_c }));
}

test "deepEqual: json.Value object same entries are equal, different are not" {
    // Arrange
    var obj_a = json.ObjectMap.init(testing.allocator);
    defer obj_a.deinit();
    try obj_a.put("key", .{ .integer = 42 });

    // Act
    var obj_b = json.ObjectMap.init(testing.allocator);
    defer obj_b.deinit();
    try obj_b.put("key", .{ .integer = 42 });

    // Assert
    try testing.expect(deepEqual(json.Value, .{ .object = obj_a }, .{ .object = obj_b }));

    var obj_c = json.ObjectMap.init(testing.allocator);
    defer obj_c.deinit();
    try obj_c.put("key", .{ .integer = 99 });

    try testing.expect(!deepEqual(json.Value, .{ .object = obj_a }, .{ .object = obj_c }));
}

test "deepEqual: json.Value type mismatch is not equal" {
    // Act / Assert
    try testing.expect(!deepEqual(json.Value, .{ .integer = 42 }, .{ .string = "42" }));
    try testing.expect(!deepEqual(json.Value, .null, .{ .bool = false }));
}

test "deepEqual: tagged union same tag same payload is equal" {
    // Arrange
    const Event = union(enum) {
        added: TestSpec,
        removed: void,
        count: i64,
    };

    // Act
    const a = Event{ .added = .{ .replicas = 3 } };
    const b = Event{ .added = .{ .replicas = 3 } };

    // Assert
    try testing.expect(deepEqual(Event, a, b));
}

test "deepEqual: tagged union same tag different payload is not equal" {
    // Arrange
    const Event = union(enum) {
        added: TestSpec,
        removed: void,
        count: i64,
    };

    // Act
    const a = Event{ .added = .{ .replicas = 3 } };
    const b = Event{ .added = .{ .replicas = 5 } };

    // Assert
    try testing.expect(!deepEqual(Event, a, b));
}

test "deepEqual: tagged union different tags is not equal" {
    // Arrange
    const Event = union(enum) {
        added: TestSpec,
        removed: void,
        count: i64,
    };

    // Act
    const a = Event{ .removed = {} };
    const b = Event{ .count = 1 };

    // Assert
    try testing.expect(!deepEqual(Event, a, b));
}

// specEqual tests
test "specEqual: both specs null is equal" {
    // Arrange
    const a = TestResource{};
    const b = TestResource{};

    // Act / Assert
    try testing.expect(specEqual(TestResource, a, b));
}

test "specEqual: same spec values are equal" {
    // Arrange
    const a = TestResource{ .spec = .{ .replicas = 3, .paused = true } };
    const b = TestResource{ .spec = .{ .replicas = 3, .paused = true } };

    // Act / Assert
    try testing.expect(specEqual(TestResource, a, b));
}

test "specEqual: different spec values are not equal" {
    // Arrange
    const a = TestResource{ .spec = .{ .replicas = 3 } };
    const b = TestResource{ .spec = .{ .replicas = 5 } };

    // Act / Assert
    try testing.expect(!specEqual(TestResource, a, b));
}

test "specEqual: one spec null other non-null is not equal" {
    // Arrange
    const a = TestResource{ .spec = null };
    const b = TestResource{ .spec = .{ .replicas = 3 } };

    // Act / Assert
    try testing.expect(!specEqual(TestResource, a, b));
}

test "specEqual: same spec but different metadata/status is equal" {
    // Arrange
    const a = TestResource{
        .metadata = .{ .name = "a", .generation = 1 },
        .spec = .{ .replicas = 3 },
        .status = .{ .availableReplicas = 1 },
    };
    const b = TestResource{
        .metadata = .{ .name = "b", .generation = 2 },
        .spec = .{ .replicas = 3 },
        .status = .{ .availableReplicas = 5 },
    };

    // Act / Assert
    try testing.expect(specEqual(TestResource, a, b));
}

// statusEqual tests
test "statusEqual: same status is equal" {
    // Arrange
    const a = TestResource{ .status = .{ .availableReplicas = 3, .readyReplicas = 2 } };
    const b = TestResource{ .status = .{ .availableReplicas = 3, .readyReplicas = 2 } };

    // Act / Assert
    try testing.expect(statusEqual(TestResource, a, b));
}

test "statusEqual: different status is not equal" {
    // Arrange
    const a = TestResource{ .status = .{ .availableReplicas = 3 } };
    const b = TestResource{ .status = .{ .availableReplicas = 1 } };

    // Act / Assert
    try testing.expect(!statusEqual(TestResource, a, b));
}

test "statusEqual: same status but different spec is equal" {
    // Arrange
    const a = TestResource{ .spec = .{ .replicas = 1 }, .status = .{ .readyReplicas = 2 } };
    const b = TestResource{ .spec = .{ .replicas = 9 }, .status = .{ .readyReplicas = 2 } };

    // Act / Assert
    try testing.expect(statusEqual(TestResource, a, b));
}

// labelsEqual tests
test "labelsEqual: both labels null is equal" {
    // Arrange
    const a = TestResource{ .metadata = .{} };
    const b = TestResource{ .metadata = .{} };

    // Act / Assert
    try testing.expect(labelsEqual(TestResource, a, b));
}

test "labelsEqual: same labels are equal" {
    // Arrange
    var labels_a: json.ArrayHashMap([]const u8) = .{};
    defer labels_a.map.deinit(testing.allocator);
    try labels_a.map.put(testing.allocator, "app", "nginx");

    // Act
    var labels_b: json.ArrayHashMap([]const u8) = .{};
    defer labels_b.map.deinit(testing.allocator);
    try labels_b.map.put(testing.allocator, "app", "nginx");

    // Assert
    const a = TestResource{ .metadata = .{ .labels = labels_a } };
    const b = TestResource{ .metadata = .{ .labels = labels_b } };

    try testing.expect(labelsEqual(TestResource, a, b));
}

test "labelsEqual: different labels are not equal" {
    // Arrange
    var labels_a: json.ArrayHashMap([]const u8) = .{};
    defer labels_a.map.deinit(testing.allocator);
    try labels_a.map.put(testing.allocator, "app", "nginx");

    // Act
    var labels_b: json.ArrayHashMap([]const u8) = .{};
    defer labels_b.map.deinit(testing.allocator);
    try labels_b.map.put(testing.allocator, "app", "redis");

    // Assert
    const a = TestResource{ .metadata = .{ .labels = labels_a } };
    const b = TestResource{ .metadata = .{ .labels = labels_b } };

    try testing.expect(!labelsEqual(TestResource, a, b));
}

test "labelsEqual: one side has metadata, other doesn't is not equal" {
    // Arrange
    const a = TestResource{ .metadata = .{} };
    const b = TestResource{ .metadata = null };

    // Act / Assert
    try testing.expect(!labelsEqual(TestResource, a, b));
}

test "labelsEqual: both have metadata but only one has labels is not equal" {
    // Arrange
    var labels: json.ArrayHashMap([]const u8) = .{};
    defer labels.map.deinit(testing.allocator);
    try labels.map.put(testing.allocator, "app", "nginx");

    // Act
    const a = TestResource{ .metadata = .{ .labels = labels } };
    const b = TestResource{ .metadata = .{ .labels = null } };

    // Assert
    try testing.expect(!labelsEqual(TestResource, a, b));
}

// annotationsEqual tests
test "annotationsEqual: both annotations null is equal" {
    // Arrange
    const a = TestResource{ .metadata = .{} };
    const b = TestResource{ .metadata = .{} };

    // Act / Assert
    try testing.expect(annotationsEqual(TestResource, a, b));
}

test "annotationsEqual: same annotations are equal" {
    // Arrange
    var ann_a: json.ArrayHashMap([]const u8) = .{};
    defer ann_a.map.deinit(testing.allocator);
    try ann_a.map.put(testing.allocator, "note", "test");

    // Act
    var ann_b: json.ArrayHashMap([]const u8) = .{};
    defer ann_b.map.deinit(testing.allocator);
    try ann_b.map.put(testing.allocator, "note", "test");

    // Assert
    const a = TestResource{ .metadata = .{ .annotations = ann_a } };
    const b = TestResource{ .metadata = .{ .annotations = ann_b } };

    try testing.expect(annotationsEqual(TestResource, a, b));
}

test "annotationsEqual: different annotations are not equal" {
    // Arrange
    var ann_a: json.ArrayHashMap([]const u8) = .{};
    defer ann_a.map.deinit(testing.allocator);
    try ann_a.map.put(testing.allocator, "note", "a");

    // Act
    var ann_b: json.ArrayHashMap([]const u8) = .{};
    defer ann_b.map.deinit(testing.allocator);
    try ann_b.map.put(testing.allocator, "note", "b");

    // Assert
    const a = TestResource{ .metadata = .{ .annotations = ann_a } };
    const b = TestResource{ .metadata = .{ .annotations = ann_b } };

    try testing.expect(!annotationsEqual(TestResource, a, b));
}

test "annotationsEqual: one side has metadata, other doesn't is not equal" {
    // Arrange
    const a = TestResource{ .metadata = .{} };
    const b = TestResource{ .metadata = null };

    // Act / Assert
    try testing.expect(!annotationsEqual(TestResource, a, b));
}

test "annotationsEqual: both have metadata but only one has annotations is not equal" {
    // Arrange
    var ann: json.ArrayHashMap([]const u8) = .{};
    defer ann.map.deinit(testing.allocator);
    try ann.map.put(testing.allocator, "note", "test");

    // Act
    const a = TestResource{ .metadata = .{ .annotations = ann } };
    const b = TestResource{ .metadata = .{ .annotations = null } };

    // Assert
    try testing.expect(!annotationsEqual(TestResource, a, b));
}

// metadataEqual tests
test "metadataEqual: same metadata is equal" {
    // Arrange
    const a = TestResource{ .metadata = .{ .name = "pod-1", .namespace = "default" } };
    const b = TestResource{ .metadata = .{ .name = "pod-1", .namespace = "default" } };

    // Act / Assert
    try testing.expect(metadataEqual(TestResource, a, b));
}

test "metadataEqual: different name is not equal" {
    // Arrange
    const a = TestResource{ .metadata = .{ .name = "pod-1" } };
    const b = TestResource{ .metadata = .{ .name = "pod-2" } };

    // Act / Assert
    try testing.expect(!metadataEqual(TestResource, a, b));
}

test "metadataEqual: different resourceVersion only is still equal (excluded)" {
    // Arrange
    const a = TestResource{ .metadata = .{ .name = "pod-1", .resourceVersion = "100" } };
    const b = TestResource{ .metadata = .{ .name = "pod-1", .resourceVersion = "200" } };

    // Act / Assert
    try testing.expect(metadataEqual(TestResource, a, b));
}

test "metadataEqual: different uid only is still equal (excluded)" {
    // Arrange
    const a = TestResource{ .metadata = .{ .name = "pod-1", .uid = "aaa" } };
    const b = TestResource{ .metadata = .{ .name = "pod-1", .uid = "bbb" } };

    // Act / Assert
    try testing.expect(metadataEqual(TestResource, a, b));
}

test "metadataEqual: different creationTimestamp only is still equal (excluded)" {
    // Arrange
    const a = TestResource{ .metadata = .{ .name = "pod-1", .creationTimestamp = "2024-01-01" } };
    const b = TestResource{ .metadata = .{ .name = "pod-1", .creationTimestamp = "2024-06-01" } };

    // Act / Assert
    try testing.expect(metadataEqual(TestResource, a, b));
}

test "metadataEqual: different labels is not equal (not excluded)" {
    // Arrange
    var labels_a: json.ArrayHashMap([]const u8) = .{};
    defer labels_a.map.deinit(testing.allocator);
    try labels_a.map.put(testing.allocator, "app", "nginx");

    // Act
    var labels_b: json.ArrayHashMap([]const u8) = .{};
    defer labels_b.map.deinit(testing.allocator);
    try labels_b.map.put(testing.allocator, "app", "redis");

    // Assert
    const a = TestResource{ .metadata = .{ .name = "pod-1", .labels = labels_a } };
    const b = TestResource{ .metadata = .{ .name = "pod-1", .labels = labels_b } };

    try testing.expect(!metadataEqual(TestResource, a, b));
}

test "metadataEqual: different finalizers is not equal (not excluded)" {
    // Arrange
    const fins_a = [_][]const u8{"finalizer-a"};
    const fins_b = [_][]const u8{"finalizer-b"};
    const a = TestResource{ .metadata = .{ .name = "pod-1", .finalizers = &fins_a } };
    const b = TestResource{ .metadata = .{ .name = "pod-1", .finalizers = &fins_b } };

    // Act / Assert
    try testing.expect(!metadataEqual(TestResource, a, b));
}

// Predicate integration tests
test "specChanged: returns false when specs are identical, true when they differ" {
    // Arrange
    const pred = specChanged(TestResource);
    const a = TestResource{ .spec = .{ .replicas = 3 } };
    const b = TestResource{ .spec = .{ .replicas = 3 } };

    // Act
    try testing.expect(!pred(&a, &b));

    // Assert
    const c = TestResource{ .spec = .{ .replicas = 5 } };

    try testing.expect(pred(&a, &c));
}

test "labelsChanged: returns false when labels match, true when they differ" {
    // Arrange
    const pred = labelsChanged(TestResource);
    const a = TestResource{ .metadata = .{ .labels = null } };
    const b = TestResource{ .metadata = .{ .labels = null } };

    // Act
    try testing.expect(!pred(&a, &b));

    // Assert
    var labels: json.ArrayHashMap([]const u8) = .{};
    defer labels.map.deinit(testing.allocator);
    try labels.map.put(testing.allocator, "app", "nginx");

    const c = TestResource{ .metadata = .{ .labels = labels } };

    try testing.expect(pred(&a, &c));
}

test "statusChanged: returns false when status matches, true when it differs" {
    // Arrange
    const pred = statusChanged(TestResource);
    const a = TestResource{ .status = .{ .readyReplicas = 2 } };
    const b = TestResource{ .status = .{ .readyReplicas = 2 } };

    // Act
    try testing.expect(!pred(&a, &b));

    // Assert
    const c = TestResource{ .status = .{ .readyReplicas = 0 } };

    try testing.expect(pred(&a, &c));
}
