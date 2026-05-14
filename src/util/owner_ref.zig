//! Helpers for managing Kubernetes owner references on resource metadata.
//!
//! Provides functions to build an `OwnerReference` from a resource's
//! comptime `resource_meta`, and to check, set, or remove owner references
//! in an `ArrayListUnmanaged`. Assign `metadata.ownerReferences = list.items`
//! to publish the updated slice.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

/// Owner reference struct compatible with the generated `MetaV1OwnerReference`.
/// Returned by `ownerReferenceFor` and accepted by `setOwnerReference`.
pub const OwnerReference = struct {
    apiVersion: []const u8,
    kind: []const u8,
    name: []const u8,
    uid: []const u8,
    controller: ?bool = null,
    blockOwnerDeletion: ?bool = null,
};

/// Build an `OwnerReference` for `owner` using its comptime `resource_meta`.
/// Sets `controller = true` and `blockOwnerDeletion = true`.
/// Returns `null` if `owner.metadata`, `.name`, or `.uid` is null.
pub fn ownerReferenceFor(comptime T: type, owner: T) ?OwnerReference {
    comptime {
        if (!@hasDecl(T, "resource_meta")) {
            @compileError("type '" ++ @typeName(T) ++ "' has no resource_meta declaration");
        }
    }
    const meta = owner.metadata orelse return null;
    const name = meta.name orelse return null;
    const uid = meta.uid orelse return null;

    const rm = T.resource_meta;
    const api_version = comptime if (rm.group.len == 0) rm.version else rm.group ++ "/" ++ rm.version;

    return .{
        .apiVersion = api_version,
        .kind = rm.kind,
        .name = name,
        .uid = uid,
        .controller = true,
        .blockOwnerDeletion = true,
    };
}

/// Check whether an owner reference with the given `uid` exists in `items`.
/// Pass `metadata.ownerReferences orelse &.{}` or `list.items` directly.
pub fn hasOwnerReference(items: anytype, uid: []const u8) bool {
    for (items) |r| {
        if (std.mem.eql(u8, r.uid, uid)) return true;
    }
    return false;
}

/// Add or replace an owner reference in `list`. Replaces in-place when the
/// UID matches an existing entry; otherwise appends.
pub fn setOwnerReference(list: anytype, allocator: Allocator, ref: anytype) !void {
    const T = std.meta.Child(@TypeOf(list.items));
    const new_ref: T = .{
        .apiVersion = ref.apiVersion,
        .kind = ref.kind,
        .name = ref.name,
        .uid = ref.uid,
        .controller = ref.controller,
        .blockOwnerDeletion = ref.blockOwnerDeletion,
    };

    for (list.items) |*r| {
        if (std.mem.eql(u8, r.uid, ref.uid)) {
            r.* = new_ref;
            return;
        }
    }
    try list.append(allocator, new_ref);
}

/// Remove an owner reference by UID from `list` using swap-remove.
/// Does NOT allocate. Returns `true` if an entry was found and removed.
pub fn removeOwnerReference(list: anytype, uid: []const u8) bool {
    for (list.items, 0..) |r, i| {
        if (std.mem.eql(u8, r.uid, uid)) {
            _ = list.swapRemove(i);
            return true;
        }
    }
    return false;
}

const test_types = @import("../test_types.zig");
const TestOwnerRef = test_types.TestOwnerRef;
const TestMeta = test_types.TestMeta;

// ownerReferenceFor tests
const TestResource = struct {
    pub const resource_meta = .{
        .group = "apps",
        .version = "v1",
        .kind = "Deployment",
        .resource = "deployments",
        .namespaced = true,
        .list_kind = void,
    };
    metadata: ?struct {
        name: ?[]const u8 = null,
        uid: ?[]const u8 = null,
    } = null,
};

const TestCoreResource = struct {
    pub const resource_meta = .{
        .group = "",
        .version = "v1",
        .kind = "Pod",
        .resource = "pods",
        .namespaced = true,
        .list_kind = void,
    };
    metadata: ?struct {
        name: ?[]const u8 = null,
        uid: ?[]const u8 = null,
    } = null,
};

test "ownerReferenceFor: builds ref with group/version for named group" {
    // Act / Assert
    const owner = TestResource{
        .metadata = .{ .name = "my-deploy", .uid = "uid-123" },
    };
    const ref = ownerReferenceFor(TestResource, owner).?;
    try testing.expectEqualStrings("apps/v1", ref.apiVersion);
    try testing.expectEqualStrings("Deployment", ref.kind);
    try testing.expectEqualStrings("my-deploy", ref.name);
    try testing.expectEqualStrings("uid-123", ref.uid);
    try testing.expectEqual(true, ref.controller.?);
    try testing.expectEqual(true, ref.blockOwnerDeletion.?);
}

test "ownerReferenceFor: uses bare version for core group" {
    // Act / Assert
    const owner = TestCoreResource{
        .metadata = .{ .name = "my-pod", .uid = "uid-456" },
    };
    const ref = ownerReferenceFor(TestCoreResource, owner).?;
    try testing.expectEqualStrings("v1", ref.apiVersion);
    try testing.expectEqualStrings("Pod", ref.kind);
}

test "ownerReferenceFor: returns null when metadata is null" {
    // Act / Assert
    const owner = TestResource{};
    try testing.expect(ownerReferenceFor(TestResource, owner) == null);
}

test "ownerReferenceFor: returns null when name is null" {
    // Act / Assert
    const owner = TestResource{ .metadata = .{ .uid = "uid-123" } };
    try testing.expect(ownerReferenceFor(TestResource, owner) == null);
}

test "ownerReferenceFor: returns null when uid is null" {
    // Act / Assert
    const owner = TestResource{ .metadata = .{ .name = "my-deploy" } };
    try testing.expect(ownerReferenceFor(TestResource, owner) == null);
}

// hasOwnerReference tests
test "hasOwnerReference: returns false when slice is empty" {
    // Act / Assert
    try testing.expect(!hasOwnerReference(&[_]TestOwnerRef{}, "uid-1"));
}

test "hasOwnerReference: returns false when uid not present" {
    // Act / Assert
    const refs = [_]TestOwnerRef{.{
        .apiVersion = "v1",
        .kind = "Pod",
        .name = "pod-1",
        .uid = "uid-other",
    }};
    try testing.expect(!hasOwnerReference(&refs, "uid-1"));
}

test "hasOwnerReference: returns true when uid is present" {
    // Act / Assert
    const refs = [_]TestOwnerRef{.{
        .apiVersion = "v1",
        .kind = "Pod",
        .name = "pod-1",
        .uid = "uid-1",
    }};
    try testing.expect(hasOwnerReference(&refs, "uid-1"));
}

// setOwnerReference tests
test "setOwnerReference: adds to empty list" {
    // Arrange
    var list: std.ArrayListUnmanaged(TestOwnerRef) = .empty;
    defer list.deinit(testing.allocator);
    const ref = OwnerReference{
        .apiVersion = "v1",
        .kind = "Pod",
        .name = "pod-1",
        .uid = "uid-1",
        .controller = true,
        .blockOwnerDeletion = true,
    };

    // Act
    try setOwnerReference(&list, testing.allocator, ref);

    // Assert
    try testing.expectEqual(@as(usize, 1), list.items.len);
    try testing.expectEqualStrings("uid-1", list.items[0].uid);
    try testing.expectEqual(true, list.items[0].controller.?);
}

test "setOwnerReference: appends when uid not present" {
    // Arrange
    var list: std.ArrayListUnmanaged(TestOwnerRef) = .empty;
    defer list.deinit(testing.allocator);
    try list.append(testing.allocator, .{
        .apiVersion = "v1",
        .kind = "Pod",
        .name = "pod-1",
        .uid = "uid-1",
    });
    const ref = OwnerReference{
        .apiVersion = "apps/v1",
        .kind = "Deployment",
        .name = "deploy-1",
        .uid = "uid-2",
        .controller = false,
        .blockOwnerDeletion = false,
    };

    // Act
    try setOwnerReference(&list, testing.allocator, ref);

    // Assert
    try testing.expectEqual(@as(usize, 2), list.items.len);
    try testing.expectEqualStrings("uid-1", list.items[0].uid);
    try testing.expectEqualStrings("uid-2", list.items[1].uid);
}

test "setOwnerReference: replaces when uid already exists" {
    // Arrange
    var list: std.ArrayListUnmanaged(TestOwnerRef) = .empty;
    defer list.deinit(testing.allocator);
    try list.append(testing.allocator, .{
        .apiVersion = "v1",
        .kind = "Pod",
        .name = "pod-1",
        .uid = "uid-1",
    });
    const ref = OwnerReference{
        .apiVersion = "v1",
        .kind = "Pod",
        .name = "pod-1-updated",
        .uid = "uid-1",
        .controller = true,
        .blockOwnerDeletion = true,
    };

    // Act
    try setOwnerReference(&list, testing.allocator, ref);

    // Assert
    try testing.expectEqual(@as(usize, 1), list.items.len);
    try testing.expectEqualStrings("pod-1-updated", list.items[0].name);
    try testing.expectEqual(true, list.items[0].controller.?);
}

test "setOwnerReference: grow path frees previous buffer via list" {
    // Arrange: seed a list so the next append triggers a reallocation.
    var list: std.ArrayListUnmanaged(TestOwnerRef) = .empty;
    defer list.deinit(testing.allocator);
    try list.ensureTotalCapacity(testing.allocator, 1);
    try list.append(testing.allocator, .{
        .apiVersion = "v1",
        .kind = "Pod",
        .name = "a",
        .uid = "uid-a",
    });

    // Act: append a second entry with a different UID, forcing a grow.
    try setOwnerReference(&list, testing.allocator, OwnerReference{
        .apiVersion = "v1",
        .kind = "Pod",
        .name = "b",
        .uid = "uid-b",
    });

    // Assert
    try testing.expectEqual(@as(usize, 2), list.items.len);
    try testing.expectEqualStrings("uid-a", list.items[0].uid);
    try testing.expectEqualStrings("uid-b", list.items[1].uid);
}

// removeOwnerReference tests
test "removeOwnerReference: returns false when list is empty" {
    // Act / Assert
    var list: std.ArrayListUnmanaged(TestOwnerRef) = .empty;
    defer list.deinit(testing.allocator);
    try testing.expect(!removeOwnerReference(&list, "uid-1"));
}

test "removeOwnerReference: returns false when uid not present" {
    // Arrange
    var list: std.ArrayListUnmanaged(TestOwnerRef) = .empty;
    defer list.deinit(testing.allocator);
    try list.append(testing.allocator, .{
        .apiVersion = "v1",
        .kind = "Pod",
        .name = "pod-1",
        .uid = "uid-other",
    });

    // Act / Assert
    try testing.expect(!removeOwnerReference(&list, "uid-1"));
}

test "removeOwnerReference: removes sole entry" {
    // Arrange
    var list: std.ArrayListUnmanaged(TestOwnerRef) = .empty;
    defer list.deinit(testing.allocator);
    try list.append(testing.allocator, .{
        .apiVersion = "v1",
        .kind = "Pod",
        .name = "pod-1",
        .uid = "uid-1",
    });

    // Act / Assert
    try testing.expect(removeOwnerReference(&list, "uid-1"));
    try testing.expectEqual(@as(usize, 0), list.items.len);
}

test "removeOwnerReference: swap-removes from multiple" {
    // Arrange
    var list: std.ArrayListUnmanaged(TestOwnerRef) = .empty;
    defer list.deinit(testing.allocator);
    try list.appendSlice(testing.allocator, &.{
        .{ .apiVersion = "v1", .kind = "Pod", .name = "a", .uid = "uid-a" },
        .{ .apiVersion = "v1", .kind = "Pod", .name = "target", .uid = "uid-target" },
        .{ .apiVersion = "v1", .kind = "Pod", .name = "c", .uid = "uid-c" },
    });

    // Act
    try testing.expect(removeOwnerReference(&list, "uid-target"));

    // Assert: 2 entries remain; swap-remove brings uid-c into slot 1.
    try testing.expectEqual(@as(usize, 2), list.items.len);
    try testing.expectEqualStrings("uid-a", list.items[0].uid);
    try testing.expectEqualStrings("uid-c", list.items[1].uid);
}
