//! Helpers for managing Kubernetes owner references on resource metadata.
//!
//! Provides functions to build an `OwnerReference` from a resource's
//! comptime `resource_meta`, and to check, set, or remove owner references
//! in a metadata struct's `ownerReferences` field. Set uses upsert semantics
//! (matching by UID), and remove uses swap-remove without allocating.

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

/// Check whether an owner reference with the given `uid` exists
/// in `metadata.ownerReferences`. Null-safe.
pub fn hasOwnerReference(metadata: anytype, uid: []const u8) bool {
    const refs = metadata.ownerReferences orelse return false;
    for (refs) |r| {
        if (std.mem.eql(u8, r.uid, uid)) return true;
    }
    return false;
}

/// Add or replace an owner reference in `metadata.ownerReferences`.
/// If an entry with the same UID already exists, it is replaced.
/// Each allocating code path uses a single allocation followed by an
/// infallible fill. Allocates a new slice via `allocator`.
pub fn setOwnerReference(metadata: anytype, allocator: Allocator, ref: anytype) !void {
    const OwnerRefT = OwnerRefElement(@TypeOf(metadata));
    const new_ref: OwnerRefT = .{
        .apiVersion = ref.apiVersion,
        .kind = ref.kind,
        .name = ref.name,
        .uid = ref.uid,
        .controller = ref.controller,
        .blockOwnerDeletion = ref.blockOwnerDeletion,
    };

    const existing = metadata.ownerReferences orelse {
        // Allocate
        const new = try allocator.alloc(OwnerRefT, 1);
        errdefer comptime unreachable;

        // Fill
        new[0] = new_ref;
        metadata.ownerReferences = new;
        return;
    };

    // Check for existing ref by UID; replace in place.
    for (existing) |*r| {
        if (std.mem.eql(u8, r.uid, ref.uid)) {
            // Replace via mutable pointer cast (underlying memory is mutable).
            const mutable: *OwnerRefT = @constCast(r);
            mutable.* = new_ref;
            return;
        }
    }

    // Allocate
    const new = try allocator.alloc(OwnerRefT, existing.len + 1);
    errdefer comptime unreachable;

    // Fill
    @memcpy(new[0..existing.len], existing);
    new[existing.len] = new_ref;
    metadata.ownerReferences = new;
}

/// Remove an owner reference by UID from `metadata.ownerReferences`.
/// Uses swap-remove (order is irrelevant). Does NOT allocate.
/// Returns `true` if an entry was found and removed.
pub fn removeOwnerReference(metadata: anytype, uid: []const u8) bool {
    const refs = metadata.ownerReferences orelse return false;
    for (refs, 0..) |r, i| {
        if (std.mem.eql(u8, r.uid, uid)) {
            const OwnerRefT = OwnerRefElement(@TypeOf(metadata));
            const mutable: []OwnerRefT = @constCast(refs);
            const last = refs.len - 1;
            if (i != last) {
                mutable[i] = mutable[last];
            }
            metadata.ownerReferences = refs[0..last];
            return true;
        }
    }
    return false;
}

// Comptime helpers
/// Extract the element type of `ownerReferences` from a metadata type
/// (or pointer-to-metadata type). Works with any struct that has
/// `ownerReferences: ?[]const T`.
fn OwnerRefElement(comptime MetaPtrT: type) type {
    const MetaT = switch (@typeInfo(MetaPtrT)) {
        .pointer => |p| p.child,
        else => MetaPtrT,
    };
    const field_type = @TypeOf(@as(MetaT, undefined).ownerReferences);
    const opt_child = @typeInfo(field_type).optional.child;
    return @typeInfo(opt_child).pointer.child;
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
test "hasOwnerReference: returns false when ownerReferences is null" {
    // Act / Assert
    const meta = TestMeta{};
    try testing.expect(!hasOwnerReference(meta, "uid-1"));
}

test "hasOwnerReference: returns false when uid not present" {
    // Act / Assert
    const refs = [_]TestOwnerRef{.{
        .apiVersion = "v1",
        .kind = "Pod",
        .name = "pod-1",
        .uid = "uid-other",
    }};
    const meta = TestMeta{ .ownerReferences = &refs };
    try testing.expect(!hasOwnerReference(meta, "uid-1"));
}

test "hasOwnerReference: returns true when uid is present" {
    // Act / Assert
    const refs = [_]TestOwnerRef{.{
        .apiVersion = "v1",
        .kind = "Pod",
        .name = "pod-1",
        .uid = "uid-1",
    }};
    const meta = TestMeta{ .ownerReferences = &refs };
    try testing.expect(hasOwnerReference(meta, "uid-1"));
}

// setOwnerReference tests
test "setOwnerReference: adds to null ownerReferences" {
    // Act / Assert
    var meta = TestMeta{};
    const ref = OwnerReference{
        .apiVersion = "v1",
        .kind = "Pod",
        .name = "pod-1",
        .uid = "uid-1",
        .controller = true,
        .blockOwnerDeletion = true,
    };
    try setOwnerReference(&meta, testing.allocator, ref);
    defer testing.allocator.free(meta.ownerReferences.?);
    try testing.expectEqual(@as(usize, 1), meta.ownerReferences.?.len);
    try testing.expectEqualStrings("uid-1", meta.ownerReferences.?[0].uid);
    try testing.expectEqual(true, meta.ownerReferences.?[0].controller.?);
}

test "setOwnerReference: appends when uid not present" {
    // Act / Assert
    var existing = [_]TestOwnerRef{.{
        .apiVersion = "v1",
        .kind = "Pod",
        .name = "pod-1",
        .uid = "uid-1",
    }};
    var meta = TestMeta{ .ownerReferences = &existing };
    const ref = OwnerReference{
        .apiVersion = "apps/v1",
        .kind = "Deployment",
        .name = "deploy-1",
        .uid = "uid-2",
        .controller = false,
        .blockOwnerDeletion = false,
    };
    try setOwnerReference(&meta, testing.allocator, ref);
    defer testing.allocator.free(meta.ownerReferences.?);
    try testing.expectEqual(@as(usize, 2), meta.ownerReferences.?.len);
    try testing.expectEqualStrings("uid-1", meta.ownerReferences.?[0].uid);
    try testing.expectEqualStrings("uid-2", meta.ownerReferences.?[1].uid);
}

test "setOwnerReference: replaces when uid already exists" {
    // Act / Assert
    var existing = [_]TestOwnerRef{.{
        .apiVersion = "v1",
        .kind = "Pod",
        .name = "pod-1",
        .uid = "uid-1",
    }};
    var meta = TestMeta{ .ownerReferences = &existing };
    const ref = OwnerReference{
        .apiVersion = "v1",
        .kind = "Pod",
        .name = "pod-1-updated",
        .uid = "uid-1",
        .controller = true,
        .blockOwnerDeletion = true,
    };
    try setOwnerReference(&meta, testing.allocator, ref);
    // No new allocation; in-place replace.
    try testing.expectEqual(@as(usize, 1), meta.ownerReferences.?.len);
    try testing.expectEqualStrings("pod-1-updated", meta.ownerReferences.?[0].name);
    try testing.expectEqual(true, meta.ownerReferences.?[0].controller.?);
}

// removeOwnerReference tests
test "removeOwnerReference: returns false when ownerReferences is null" {
    // Act / Assert
    var meta = TestMeta{};
    try testing.expect(!removeOwnerReference(&meta, "uid-1"));
}

test "removeOwnerReference: returns false when uid not present" {
    // Act / Assert
    var refs = [_]TestOwnerRef{.{
        .apiVersion = "v1",
        .kind = "Pod",
        .name = "pod-1",
        .uid = "uid-other",
    }};
    var meta = TestMeta{ .ownerReferences = &refs };
    try testing.expect(!removeOwnerReference(&meta, "uid-1"));
}

test "removeOwnerReference: removes sole entry" {
    // Act / Assert
    var refs = [_]TestOwnerRef{.{
        .apiVersion = "v1",
        .kind = "Pod",
        .name = "pod-1",
        .uid = "uid-1",
    }};
    var meta = TestMeta{ .ownerReferences = &refs };
    try testing.expect(removeOwnerReference(&meta, "uid-1"));
    try testing.expectEqual(@as(usize, 0), meta.ownerReferences.?.len);
}

test "removeOwnerReference: swap-removes from multiple" {
    // Act / Assert
    var refs = [_]TestOwnerRef{
        .{ .apiVersion = "v1", .kind = "Pod", .name = "a", .uid = "uid-a" },
        .{ .apiVersion = "v1", .kind = "Pod", .name = "target", .uid = "uid-target" },
        .{ .apiVersion = "v1", .kind = "Pod", .name = "c", .uid = "uid-c" },
    };
    var meta = TestMeta{ .ownerReferences = &refs };
    try testing.expect(removeOwnerReference(&meta, "uid-target"));
    try testing.expectEqual(@as(usize, 2), meta.ownerReferences.?.len);
    try testing.expectEqualStrings("uid-a", meta.ownerReferences.?[0].uid);
    try testing.expectEqualStrings("uid-c", meta.ownerReferences.?[1].uid);
}
