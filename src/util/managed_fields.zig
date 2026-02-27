//! Helpers for inspecting Kubernetes Server-Side Apply managed fields.
//!
//! Provides accessors to query the `managedFields` array on a Kubernetes
//! object's metadata: listing field managers, finding entries by manager
//! name and subresource, and checking whether a manager uses Apply (SSA)
//! or Update semantics. All functions are comptime-validated and null-safe.

const std = @import("std");
const testing = std.testing;

// Comptime validation
const resource_shape = @import("resource_shape.zig");
const validateHasMetadata = resource_shape.validateHasMetadata;

/// Returns the metadata type's managed fields entry type.
/// This is the element type of the managedFields slice.
fn ManagedFieldsEntryType(comptime T: type) type {
    comptime validateHasMetadata(T);
    // Get the metadata field type, unwrap the optional.
    const fields = @typeInfo(T).@"struct".fields;
    inline for (fields) |f| {
        if (std.mem.eql(u8, f.name, "metadata")) {
            // metadata is ?MetaType; unwrap the optional to get MetaType.
            const MetaType = @typeInfo(f.type).optional.child;
            const meta_fields = @typeInfo(MetaType).@"struct".fields;
            inline for (meta_fields) |mf| {
                if (std.mem.eql(u8, mf.name, "managedFields")) {
                    // Field type is ?[]const Entry; unwrap optional, then get child of slice.
                    const OptionalSlice = mf.type;
                    const Slice = @typeInfo(OptionalSlice).optional.child;
                    return @typeInfo(Slice).pointer.child;
                }
            }
            @compileError("metadata type has no 'managedFields' field");
        }
    }
    @compileError("type has no 'metadata' field");
}

// Public API
/// Get the managed fields entries from an object's metadata.
/// Returns null if metadata or managedFields is missing.
pub fn getManagedFields(comptime T: type, obj: T) ?[]const ManagedFieldsEntryType(T) {
    comptime validateHasMetadata(T);
    const meta = obj.metadata orelse return null;
    if (!@hasField(@TypeOf(meta), "managedFields")) return null;
    return meta.managedFields;
}

/// Get the names of all field managers that manage this object.
/// Returns null if metadata or managedFields is missing.
///
/// The caller owns both the returned outer slice and each inner string.
/// Use `freeFieldManagers()` to free everything in one call.
pub fn getFieldManagers(
    comptime T: type,
    obj: T,
    allocator: std.mem.Allocator,
) error{OutOfMemory}!?[]const []const u8 {
    const entries = getManagedFields(T, obj) orelse return null;

    var managers: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (managers.items) |m| allocator.free(m);
        managers.deinit(allocator);
    }

    for (entries) |entry| {
        if (@hasField(@TypeOf(entry), "manager")) {
            if (entry.manager) |mgr| {
                // Deduplicate: only add if not already present.
                var found = false;
                for (managers.items) |existing| {
                    if (std.mem.eql(u8, existing, mgr)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    try managers.append(allocator, try allocator.dupe(u8, mgr));
                }
            }
        }
    }

    const result: []const []const u8 = try managers.toOwnedSlice(allocator);
    return result;
}

/// Free a slice returned by `getFieldManagers`, including all inner strings.
pub fn freeFieldManagers(managers: []const []const u8, allocator: std.mem.Allocator) void {
    for (managers) |m| allocator.free(m);
    allocator.free(managers);
}

/// Find the managed fields entry for a specific manager name.
/// Returns the first entry matching the manager name, or null if not found.
/// If `subresource` is non-null, also matches on the subresource field.
pub fn findManager(
    comptime T: type,
    obj: T,
    manager_name: []const u8,
    subresource: ?[]const u8,
) ?*const ManagedFieldsEntryType(T) {
    const entries = getManagedFields(T, obj) orelse return null;

    for (entries) |*entry| {
        const mgr = if (@hasField(@TypeOf(entry.*), "manager")) entry.manager else continue;
        if (mgr == null) continue;
        if (!std.mem.eql(u8, mgr.?, manager_name)) continue;

        // If subresource filter is given, check it.
        if (subresource) |sub| {
            const entry_sub = if (@hasField(@TypeOf(entry.*), "subresource")) entry.subresource else null;
            const sub_str = entry_sub orelse "";
            if (!std.mem.eql(u8, sub_str, sub)) continue;
        }

        return entry;
    }

    return null;
}

/// Returns true if the object has a managed fields entry for the given manager.
pub fn isFieldManager(comptime T: type, obj: T, manager_name: []const u8) bool {
    return findManager(T, obj, manager_name, null) != null;
}

/// Returns true if the given manager's operation type is "Apply" (SSA).
/// Returns false if the manager is not found or uses "Update" (non-SSA).
pub fn isApplyManager(comptime T: type, obj: T, manager_name: []const u8) bool {
    const entry = findManager(T, obj, manager_name, null) orelse return false;
    if (@hasField(@TypeOf(entry.*), "operation")) {
        const op = entry.operation orelse return false;
        return std.mem.eql(u8, op, "Apply");
    }
    return false;
}

const test_types = @import("../test_types.zig");
const TestManagedFieldsEntry = test_types.TestManagedFieldsEntry;
const TestMeta = test_types.TestMeta;
const TestResource = test_types.TestResource;

test "getManagedFields: returns entries when present" {
    // Arrange
    const entries = [_]TestManagedFieldsEntry{
        .{ .manager = "kubectl", .operation = "Update" },
        .{ .manager = "my-controller", .operation = "Apply" },
    };
    const obj = TestResource{
        .metadata = .{ .managedFields = &entries },
    };

    // Act
    const result = getManagedFields(TestResource, obj);

    // Assert
    try testing.expect(result != null);
    try testing.expectEqual(@as(usize, 2), result.?.len);
}

test "getManagedFields: returns null when metadata is null" {
    // Arrange
    const obj = TestResource{ .metadata = null };

    // Act
    const result = getManagedFields(TestResource, obj);

    // Assert
    try testing.expect(result == null);
}

test "getManagedFields: returns null when managedFields is null" {
    // Arrange
    const obj = TestResource{ .metadata = .{ .managedFields = null } };

    // Act
    const result = getManagedFields(TestResource, obj);

    // Assert
    try testing.expect(result == null);
}

test "getFieldManagers: returns unique manager names" {
    // Arrange
    const entries = [_]TestManagedFieldsEntry{
        .{ .manager = "kubectl", .operation = "Update" },
        .{ .manager = "my-controller", .operation = "Apply" },
        .{ .manager = "kubectl", .operation = "Update", .subresource = "status" },
    };
    const obj = TestResource{
        .metadata = .{ .managedFields = &entries },
    };

    // Act
    const result = (try getFieldManagers(TestResource, obj, testing.allocator)).?;
    defer freeFieldManagers(result, testing.allocator);

    // Assert
    try testing.expectEqual(@as(usize, 2), result.len);
    try testing.expectEqualStrings("kubectl", result[0]);
    try testing.expectEqualStrings("my-controller", result[1]);
}

test "getFieldManagers: returns null when metadata is null" {
    // Arrange
    const obj = TestResource{ .metadata = null };

    // Act
    const result = try getFieldManagers(TestResource, obj, testing.allocator);

    // Assert
    try testing.expect(result == null);
}

test "findManager: finds matching manager" {
    // Arrange
    const entries = [_]TestManagedFieldsEntry{
        .{ .manager = "kubectl", .operation = "Update" },
        .{ .manager = "my-controller", .operation = "Apply" },
    };
    const obj = TestResource{
        .metadata = .{ .managedFields = &entries },
    };

    // Act
    const result = findManager(TestResource, obj, "my-controller", null);

    // Assert
    try testing.expect(result != null);
    try testing.expectEqualStrings("Apply", result.?.operation.?);
}

test "findManager: returns null for unknown manager" {
    // Arrange
    const entries = [_]TestManagedFieldsEntry{
        .{ .manager = "kubectl", .operation = "Update" },
    };
    const obj = TestResource{
        .metadata = .{ .managedFields = &entries },
    };

    // Act
    const result = findManager(TestResource, obj, "unknown", null);

    // Assert
    try testing.expect(result == null);
}

test "findManager: matches on subresource" {
    // Arrange
    const entries = [_]TestManagedFieldsEntry{
        .{ .manager = "my-controller", .operation = "Apply", .subresource = "" },
        .{ .manager = "my-controller", .operation = "Apply", .subresource = "status" },
    };
    const obj = TestResource{
        .metadata = .{ .managedFields = &entries },
    };

    // Act
    const result = findManager(TestResource, obj, "my-controller", "status");

    // Assert
    try testing.expect(result != null);
    try testing.expectEqualStrings("status", result.?.subresource.?);
}

test "findManager: returns null when metadata is null" {
    // Arrange
    const obj = TestResource{ .metadata = null };

    // Act
    const result = findManager(TestResource, obj, "any", null);

    // Assert
    try testing.expect(result == null);
}

test "isFieldManager: returns true for existing manager" {
    // Arrange
    const entries = [_]TestManagedFieldsEntry{
        .{ .manager = "kubectl", .operation = "Update" },
    };
    const obj = TestResource{
        .metadata = .{ .managedFields = &entries },
    };

    // Act / Assert
    try testing.expect(isFieldManager(TestResource, obj, "kubectl"));
}

test "isFieldManager: returns false for missing manager" {
    // Arrange
    const entries = [_]TestManagedFieldsEntry{
        .{ .manager = "kubectl", .operation = "Update" },
    };
    const obj = TestResource{
        .metadata = .{ .managedFields = &entries },
    };

    // Act / Assert
    try testing.expect(!isFieldManager(TestResource, obj, "unknown"));
}

test "isApplyManager: returns true for Apply operation" {
    // Arrange
    const entries = [_]TestManagedFieldsEntry{
        .{ .manager = "my-controller", .operation = "Apply" },
    };
    const obj = TestResource{
        .metadata = .{ .managedFields = &entries },
    };

    // Act / Assert
    try testing.expect(isApplyManager(TestResource, obj, "my-controller"));
}

test "isApplyManager: returns false for Update operation" {
    // Arrange
    const entries = [_]TestManagedFieldsEntry{
        .{ .manager = "kubectl", .operation = "Update" },
    };
    const obj = TestResource{
        .metadata = .{ .managedFields = &entries },
    };

    // Act / Assert
    try testing.expect(!isApplyManager(TestResource, obj, "kubectl"));
}

test "isApplyManager: returns false for missing manager" {
    // Arrange
    const entries = [_]TestManagedFieldsEntry{
        .{ .manager = "kubectl", .operation = "Update" },
    };
    const obj = TestResource{
        .metadata = .{ .managedFields = &entries },
    };

    // Act / Assert
    try testing.expect(!isApplyManager(TestResource, obj, "unknown"));
}
