//! Kubernetes object metadata accessors and owner reference helpers.
//!
//! Provides comptime-validated, null-safe accessors for common metadata fields
//! (name, namespace, resourceVersion, uid, generation) as well as helpers for
//! working with owner references, labels, and annotations. All functions
//! require a type with an optional `metadata` field and use comptime
//! validation to produce clear compile errors for unsupported types.

const std = @import("std");
const testing = std.testing;

/// A normalized representation of a Kubernetes owner reference.
pub const OwnerRef = struct {
    apiVersion: []const u8,
    kind: []const u8,
    name: []const u8,
    uid: []const u8,
    controller: bool,
    blockOwnerDeletion: bool,
};

// Comptime validation
const resource_shape = @import("resource_shape.zig");
const validateHasMetadata = resource_shape.validateHasMetadata;

// Common accessors
/// Returns the name from the object's metadata, or null if metadata or name is missing.
pub fn getName(comptime T: type, obj: T) ?[]const u8 {
    comptime validateHasMetadata(T);
    const meta = obj.metadata orelse return null;
    return if (@hasField(@TypeOf(meta), "name")) meta.name else null;
}

/// Returns the namespace from the object's metadata, or null if metadata or namespace is missing.
pub fn getNamespace(comptime T: type, obj: T) ?[]const u8 {
    comptime validateHasMetadata(T);
    const meta = obj.metadata orelse return null;
    return if (@hasField(@TypeOf(meta), "namespace")) meta.namespace else null;
}

/// Returns the resource version from the object's metadata, or null if metadata or resourceVersion is missing.
pub fn getResourceVersion(comptime T: type, obj: T) ?[]const u8 {
    comptime validateHasMetadata(T);
    const meta = obj.metadata orelse return null;
    return if (@hasField(@TypeOf(meta), "resourceVersion")) meta.resourceVersion else null;
}

/// Returns the UID from the object's metadata, or null if metadata or uid is missing.
pub fn getUid(comptime T: type, obj: T) ?[]const u8 {
    comptime validateHasMetadata(T);
    const meta = obj.metadata orelse return null;
    return if (@hasField(@TypeOf(meta), "uid")) meta.uid else null;
}

/// Returns the generation from the object's metadata, or null if metadata or generation is missing.
pub fn getGeneration(comptime T: type, obj: T) ?i64 {
    comptime validateHasMetadata(T);
    const meta = obj.metadata orelse return null;
    return if (@hasField(@TypeOf(meta), "generation")) meta.generation else null;
}

// Owner reference helpers
fn unwrapOptionalBool(value: anytype) bool {
    return if (@typeInfo(@TypeOf(value)) == .optional) (value orelse false) else value;
}

fn toOwnerRef(ref: anytype) OwnerRef {
    const RefType = @TypeOf(ref);
    return .{
        .apiVersion = ref.apiVersion,
        .kind = ref.kind,
        .name = ref.name,
        .uid = ref.uid,
        .controller = if (@hasField(RefType, "controller"))
            unwrapOptionalBool(ref.controller)
        else
            false,
        .blockOwnerDeletion = if (@hasField(RefType, "blockOwnerDeletion"))
            unwrapOptionalBool(ref.blockOwnerDeletion)
        else
            false,
    };
}

/// Returns the owner reference marked as controller, or null if none is found.
pub fn getControllerOwner(comptime T: type, obj: T) ?OwnerRef {
    comptime validateHasMetadata(T);
    const meta = obj.metadata orelse return null;
    if (!@hasField(@TypeOf(meta), "ownerReferences")) return null;
    const refs = meta.ownerReferences orelse return null;
    for (refs) |ref| {
        const RefType = @TypeOf(ref);
        const is_controller = if (@hasField(RefType, "controller"))
            unwrapOptionalBool(ref.controller)
        else
            false;
        if (is_controller) return toOwnerRef(ref);
    }
    return null;
}

/// Build an owner reference entry for `owner` to be placed on a dependent object.
/// The `owner` must have metadata with `name` and `uid` fields.
/// The caller provides `api_version`, `kind`, and whether this is the controller ref.
/// Returns null if the owner's metadata is missing or incomplete.
pub fn ownerReference(
    comptime OwnerT: type,
    owner: OwnerT,
    api_version: []const u8,
    kind: []const u8,
    controller: bool,
    block_owner_deletion: bool,
) ?OwnerRef {
    comptime validateHasMetadata(OwnerT);
    const meta = owner.metadata orelse return null;
    const MetaType = @TypeOf(meta);
    const owner_name: []const u8 = if (@hasField(MetaType, "name"))
        (meta.name orelse return null)
    else
        return null;
    const owner_uid: []const u8 = if (@hasField(MetaType, "uid"))
        (meta.uid orelse return null)
    else
        return null;
    return .{
        .apiVersion = api_version,
        .kind = kind,
        .name = owner_name,
        .uid = owner_uid,
        .controller = controller,
        .blockOwnerDeletion = block_owner_deletion,
    };
}

// Label and annotation helpers
/// Returns the value of a label by key, or null if metadata, labels, or the key is missing.
pub fn getLabel(comptime T: type, obj: T, key: []const u8) ?[]const u8 {
    comptime validateHasMetadata(T);
    const meta = obj.metadata orelse return null;
    if (!@hasField(@TypeOf(meta), "labels")) return null;
    const labels = meta.labels orelse return null;
    return labels.map.get(key);
}

/// Returns the value of an annotation by key, or null if metadata, annotations, or the key is missing.
pub fn getAnnotation(comptime T: type, obj: T, key: []const u8) ?[]const u8 {
    comptime validateHasMetadata(T);
    const meta = obj.metadata orelse return null;
    if (!@hasField(@TypeOf(meta), "annotations")) return null;
    const annotations = meta.annotations orelse return null;
    return annotations.map.get(key);
}

/// Returns true if a label with the given key exists.
pub fn hasLabel(comptime T: type, obj: T, key: []const u8) bool {
    return getLabel(T, obj, key) != null;
}

/// Returns true if an annotation with the given key exists.
pub fn hasAnnotation(comptime T: type, obj: T, key: []const u8) bool {
    return getAnnotation(T, obj, key) != null;
}

const test_types = @import("../test_types.zig");
const TestOwnerRef = test_types.TestOwnerRef;
const TestMeta = test_types.TestMeta;
const TestResource = test_types.TestResource;

// Accessor tests
test "getName returns name when metadata is present" {
    // Arrange
    const obj = TestResource{ .metadata = .{ .name = "my-pod" } };

    // Act
    const result = getName(TestResource, obj);

    // Assert
    try testing.expectEqualStrings("my-pod", result.?);
}

test "getNamespace returns namespace when present" {
    // Arrange
    const obj = TestResource{ .metadata = .{ .namespace = "default" } };

    // Act
    const result = getNamespace(TestResource, obj);

    // Assert
    try testing.expectEqualStrings("default", result.?);
}

test "getResourceVersion returns value when present" {
    // Arrange
    const obj = TestResource{ .metadata = .{ .resourceVersion = "12345" } };

    // Act
    const result = getResourceVersion(TestResource, obj);

    // Assert
    try testing.expectEqualStrings("12345", result.?);
}

test "getUid returns value when present" {
    // Arrange
    const obj = TestResource{ .metadata = .{ .uid = "abc-123" } };

    // Act
    const result = getUid(TestResource, obj);

    // Assert
    try testing.expectEqualStrings("abc-123", result.?);
}

test "getGeneration returns value when present" {
    // Arrange
    const obj = TestResource{ .metadata = .{ .generation = 3 } };

    // Act
    const result = getGeneration(TestResource, obj);

    // Assert
    try testing.expectEqual(@as(i64, 3), result.?);
}

test "string accessors return null when metadata is null" {
    // Arrange
    const obj = TestResource{};

    // Act / Assert
    try testing.expect(getName(TestResource, obj) == null);
    try testing.expect(getNamespace(TestResource, obj) == null);
    try testing.expect(getResourceVersion(TestResource, obj) == null);
    try testing.expect(getUid(TestResource, obj) == null);
    try testing.expect(getGeneration(TestResource, obj) == null);
}

test "string accessors return null when field is null" {
    // Arrange
    const obj = TestResource{ .metadata = .{} };

    // Act / Assert
    try testing.expect(getName(TestResource, obj) == null);
    try testing.expect(getNamespace(TestResource, obj) == null);
    try testing.expect(getResourceVersion(TestResource, obj) == null);
    try testing.expect(getUid(TestResource, obj) == null);
    try testing.expect(getGeneration(TestResource, obj) == null);
}

// Owner reference tests
test "getControllerOwner returns controller ref" {
    // Arrange
    const refs = [_]TestOwnerRef{
        .{ .apiVersion = "apps/v1", .kind = "ReplicaSet", .name = "rs-1", .uid = "uid-1" },
        .{ .apiVersion = "apps/v1", .kind = "Deployment", .name = "deploy-1", .uid = "uid-2", .controller = true },
    };
    const obj = TestResource{ .metadata = .{ .ownerReferences = &refs } };

    // Act
    const ctrl = getControllerOwner(TestResource, obj).?;

    // Assert
    try testing.expectEqualStrings("Deployment", ctrl.kind);
    try testing.expectEqualStrings("deploy-1", ctrl.name);
    try testing.expectEqualStrings("uid-2", ctrl.uid);
    try testing.expect(ctrl.controller);
}

test "getControllerOwner returns null when none is controller" {
    // Arrange
    const refs = [_]TestOwnerRef{
        .{ .apiVersion = "v1", .kind = "Pod", .name = "owner", .uid = "uid-1" },
    };
    const obj = TestResource{ .metadata = .{ .ownerReferences = &refs } };

    // Act / Assert
    try testing.expect(getControllerOwner(TestResource, obj) == null);
}

test "getControllerOwner returns null when controller is false" {
    // Arrange
    const refs = [_]TestOwnerRef{
        .{ .apiVersion = "v1", .kind = "Pod", .name = "owner", .uid = "uid-1", .controller = false },
    };
    const obj = TestResource{ .metadata = .{ .ownerReferences = &refs } };

    // Act / Assert
    try testing.expect(getControllerOwner(TestResource, obj) == null);
}

test "getControllerOwner returns null when ownerReferences is null" {
    // Arrange
    const obj = TestResource{ .metadata = .{} };

    // Act / Assert
    try testing.expect(getControllerOwner(TestResource, obj) == null);
}

test "getControllerOwner returns null when metadata is null" {
    // Arrange
    const obj = TestResource{};

    // Act / Assert
    try testing.expect(getControllerOwner(TestResource, obj) == null);
}

test "ownerReference builds correct ref" {
    // Arrange
    const owner = TestResource{ .metadata = .{ .name = "my-deploy", .uid = "uid-abc" } };

    // Act
    const ref = ownerReference(TestResource, owner, "apps/v1", "Deployment", true, true).?;

    // Assert
    try testing.expectEqualStrings("apps/v1", ref.apiVersion);
    try testing.expectEqualStrings("Deployment", ref.kind);
    try testing.expectEqualStrings("my-deploy", ref.name);
    try testing.expectEqualStrings("uid-abc", ref.uid);
    try testing.expect(ref.controller);
    try testing.expect(ref.blockOwnerDeletion);
}

test "ownerReference returns null when owner has no metadata" {
    // Arrange
    const owner = TestResource{};

    // Act / Assert
    try testing.expect(ownerReference(TestResource, owner, "v1", "Pod", false, false) == null);
}

test "ownerReference returns null when owner name is null" {
    // Arrange
    const owner = TestResource{ .metadata = .{ .uid = "uid-abc" } };

    // Act / Assert
    try testing.expect(ownerReference(TestResource, owner, "v1", "Pod", false, false) == null);
}

test "ownerReference returns null when owner uid is null" {
    // Arrange
    const owner = TestResource{ .metadata = .{ .name = "my-pod" } };

    // Act / Assert
    try testing.expect(ownerReference(TestResource, owner, "v1", "Pod", false, false) == null);
}

// Label and annotation tests
test "getLabel returns value for existing key" {
    // Arrange
    var labels_map = std.json.ArrayHashMap([]const u8){};
    defer labels_map.map.deinit(testing.allocator);
    try labels_map.map.put(testing.allocator, "app", "nginx");
    try labels_map.map.put(testing.allocator, "env", "prod");
    const obj = TestResource{ .metadata = .{ .labels = labels_map } };

    // Act
    const app_result = getLabel(TestResource, obj, "app");
    const env_result = getLabel(TestResource, obj, "env");

    // Assert
    try testing.expectEqualStrings("nginx", app_result.?);
    try testing.expectEqualStrings("prod", env_result.?);
}

test "getLabel returns null for missing key" {
    // Arrange
    var labels_map = std.json.ArrayHashMap([]const u8){};
    defer labels_map.map.deinit(testing.allocator);
    try labels_map.map.put(testing.allocator, "app", "nginx");
    const obj = TestResource{ .metadata = .{ .labels = labels_map } };

    // Act
    const result = getLabel(TestResource, obj, "missing");

    // Assert
    try testing.expect(result == null);
}

test "getLabel returns null when labels is null" {
    // Arrange
    const obj = TestResource{ .metadata = .{} };

    // Act / Assert
    try testing.expect(getLabel(TestResource, obj, "app") == null);
}

test "getLabel returns null when metadata is null" {
    // Arrange
    const obj = TestResource{};

    // Act / Assert
    try testing.expect(getLabel(TestResource, obj, "app") == null);
}

test "getAnnotation returns value for existing key" {
    // Arrange
    var ann_map = std.json.ArrayHashMap([]const u8){};
    defer ann_map.map.deinit(testing.allocator);
    try ann_map.map.put(testing.allocator, "note", "hello");
    const obj = TestResource{ .metadata = .{ .annotations = ann_map } };

    // Act
    const result = getAnnotation(TestResource, obj, "note");

    // Assert
    try testing.expectEqualStrings("hello", result.?);
}

test "getAnnotation returns null for missing key" {
    // Arrange
    var ann_map = std.json.ArrayHashMap([]const u8){};
    defer ann_map.map.deinit(testing.allocator);
    try ann_map.map.put(testing.allocator, "note", "hello");
    const obj = TestResource{ .metadata = .{ .annotations = ann_map } };

    // Act
    const result = getAnnotation(TestResource, obj, "missing");

    // Assert
    try testing.expect(result == null);
}

test "getAnnotation returns null when annotations is null" {
    // Arrange
    const obj = TestResource{ .metadata = .{} };

    // Act / Assert
    try testing.expect(getAnnotation(TestResource, obj, "note") == null);
}

test "getAnnotation returns null when metadata is null" {
    // Arrange
    const obj = TestResource{};

    // Act / Assert
    try testing.expect(getAnnotation(TestResource, obj, "note") == null);
}

test "hasLabel returns true for existing key" {
    // Arrange
    var labels_map = std.json.ArrayHashMap([]const u8){};
    defer labels_map.map.deinit(testing.allocator);
    try labels_map.map.put(testing.allocator, "app", "nginx");
    const obj = TestResource{ .metadata = .{ .labels = labels_map } };

    // Act
    const result = hasLabel(TestResource, obj, "app");

    // Assert
    try testing.expect(result);
}

test "hasLabel returns false for missing key" {
    // Arrange
    var labels_map = std.json.ArrayHashMap([]const u8){};
    defer labels_map.map.deinit(testing.allocator);
    try labels_map.map.put(testing.allocator, "app", "nginx");
    const obj = TestResource{ .metadata = .{ .labels = labels_map } };

    // Act
    const result = hasLabel(TestResource, obj, "missing");

    // Assert
    try testing.expect(!result);
}

test "hasLabel returns false when labels is null" {
    // Arrange
    const obj = TestResource{ .metadata = .{} };

    // Act / Assert
    try testing.expect(!hasLabel(TestResource, obj, "app"));
}

test "hasAnnotation returns true for existing key" {
    // Arrange
    var ann_map = std.json.ArrayHashMap([]const u8){};
    defer ann_map.map.deinit(testing.allocator);
    try ann_map.map.put(testing.allocator, "note", "hello");
    const obj = TestResource{ .metadata = .{ .annotations = ann_map } };

    // Act
    const result = hasAnnotation(TestResource, obj, "note");

    // Assert
    try testing.expect(result);
}

test "hasAnnotation returns false for missing key" {
    // Arrange
    const obj = TestResource{ .metadata = .{} };

    // Act / Assert
    try testing.expect(!hasAnnotation(TestResource, obj, "note"));
}

// Compile-error precondition test
test "type without metadata field detected" {
    // Act / Assert
    const NoMetadata = struct { spec: ?i32 = null };
    try testing.expect(!@hasField(NoMetadata, "metadata"));
}
