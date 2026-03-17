//! Event-to-reconcile-request mappers for secondary resource watches.
//!
//! Provides `MapFn(S)` function types that convert a secondary resource
//! event into an `ObjectKey` for the primary reconcile queue. Includes
//! built-in mappers for owner-reference lookup (`enqueueOwner`) and
//! fixed-key routing (`enqueueConst`).

const std = @import("std");
const ObjectKey = @import("../object_key.zig").ObjectKey;
const testing = std.testing;

/// A mapper function that converts a secondary resource event into zero or more
/// primary resource keys for the reconcile queue.
///
/// Returns an `ObjectKey` to enqueue, or `null` to skip enqueueing.
pub fn MapFn(comptime S: type) type {
    return *const fn (allocator: std.mem.Allocator, obj: *const S) ?ObjectKey;
}

/// Returns a `MapFn(S)` that extracts the ownerReference matching the given
/// `owner_kind` and returns an ObjectKey for the owner.
///
/// This is the standard way to watch secondary resources in Kubernetes
/// controllers. When a Pod owned by a ReplicaSet changes, the mapper
/// returns the ReplicaSet's namespace+name so it gets reconciled.
///
/// If the secondary object has no matching ownerReference, returns null
/// (event is dropped, no key enqueued).
///
/// `owner_kind` should match the Kubernetes `kind` field in the ownerReference
/// (e.g. "Deployment", "ReplicaSet", "Job").
///
/// Usage:
/// ```zig
/// try ctrl.watchSecondary(k8s.CoreV1Pod, &client, "default", .{
///     .map_fn = mapper.enqueueOwner(k8s.CoreV1Pod, "ReplicaSet"),
/// });
/// ```
pub fn enqueueOwner(comptime S: type, comptime owner_kind: []const u8) MapFn(S) {
    const Pred = struct {
        fn pred(_: std.mem.Allocator, obj: *const S) ?ObjectKey {
            if (!@hasField(S, "metadata")) return null;
            const meta = obj.metadata orelse return null;
            const ns = if (@hasField(@TypeOf(meta), "namespace")) (meta.namespace orelse "") else "";
            const refs = if (@hasField(@TypeOf(meta), "ownerReferences")) (meta.ownerReferences orelse return null) else return null;
            for (refs) |ref| {
                if (std.mem.eql(u8, ref.kind, owner_kind)) {
                    return .{ .namespace = ns, .name = ref.name };
                }
            }
            return null;
        }
    };
    return Pred.pred;
}

/// Returns a `MapFn(S)` that always returns the same fixed ObjectKey,
/// regardless of which secondary object changed.
///
/// Useful for singleton controllers where any secondary change should
/// reconcile a single well-known primary resource.
pub fn enqueueConst(comptime S: type, comptime ns: []const u8, comptime name: []const u8) MapFn(S) {
    const Pred = struct {
        fn pred(_: std.mem.Allocator, _: *const S) ?ObjectKey {
            return .{ .namespace = ns, .name = name };
        }
    };
    return Pred.pred;
}

const test_types = @import("../test_types.zig");
const TestOwnerRef = test_types.TestOwnerRef;
const TestSecondary = test_types.TestSecondary;

test "enqueueOwner: returns correct key when matching ownerReference exists" {
    // Arrange
    const map_fn = enqueueOwner(TestSecondary, "ReplicaSet");
    const obj = TestSecondary{
        .metadata = .{
            .name = "pod-abc",
            .namespace = "default",
            .ownerReferences = &.{
                .{
                    .apiVersion = "apps/v1",
                    .kind = "ReplicaSet",
                    .name = "my-rs-12345",
                    .uid = "uid-1",
                },
            },
        },
    };

    // Act
    const result = map_fn(testing.allocator, &obj);

    // Assert
    try testing.expect(result != null);
    try testing.expectEqualStrings("default", result.?.namespace);
    try testing.expectEqualStrings("my-rs-12345", result.?.name);
}

test "enqueueOwner: returns null when no matching kind" {
    // Arrange
    const map_fn = enqueueOwner(TestSecondary, "Deployment");
    const obj = TestSecondary{
        .metadata = .{
            .name = "pod-abc",
            .namespace = "default",
            .ownerReferences = &.{
                .{
                    .apiVersion = "apps/v1",
                    .kind = "ReplicaSet",
                    .name = "my-rs-12345",
                    .uid = "uid-1",
                },
            },
        },
    };

    // Act / Assert
    try testing.expect(map_fn(testing.allocator, &obj) == null);
}

test "enqueueOwner: returns null when ownerReferences is null" {
    // Arrange
    const map_fn = enqueueOwner(TestSecondary, "ReplicaSet");
    const obj = TestSecondary{
        .metadata = .{
            .name = "pod-abc",
            .namespace = "default",
        },
    };

    // Act / Assert
    try testing.expect(map_fn(testing.allocator, &obj) == null);
}

test "enqueueOwner: returns null when metadata is null" {
    // Arrange
    const map_fn = enqueueOwner(TestSecondary, "ReplicaSet");
    const obj = TestSecondary{};

    // Act / Assert
    try testing.expect(map_fn(testing.allocator, &obj) == null);
}

test "enqueueOwner: uses the secondary object's namespace for the key" {
    // Arrange
    const map_fn = enqueueOwner(TestSecondary, "Job");
    const obj = TestSecondary{
        .metadata = .{
            .name = "pod-xyz",
            .namespace = "kube-system",
            .ownerReferences = &.{
                .{
                    .apiVersion = "batch/v1",
                    .kind = "Job",
                    .name = "my-job",
                    .uid = "uid-2",
                },
            },
        },
    };

    // Act
    const result = map_fn(testing.allocator, &obj).?;

    // Assert
    try testing.expectEqualStrings("kube-system", result.namespace);
    try testing.expectEqualStrings("my-job", result.name);
}

test "enqueueOwner: with multiple ownerReferences picks the matching one" {
    // Arrange
    const map_fn = enqueueOwner(TestSecondary, "StatefulSet");
    const obj = TestSecondary{
        .metadata = .{
            .name = "pod-multi",
            .namespace = "default",
            .ownerReferences = &.{
                .{
                    .apiVersion = "apps/v1",
                    .kind = "ReplicaSet",
                    .name = "rs-1",
                    .uid = "uid-a",
                },
                .{
                    .apiVersion = "apps/v1",
                    .kind = "StatefulSet",
                    .name = "sts-1",
                    .uid = "uid-b",
                },
                .{
                    .apiVersion = "v1",
                    .kind = "Node",
                    .name = "node-1",
                    .uid = "uid-c",
                },
            },
        },
    };

    // Act
    const result = map_fn(testing.allocator, &obj).?;

    // Assert
    try testing.expectEqualStrings("default", result.namespace);
    try testing.expectEqualStrings("sts-1", result.name);
}

test "enqueueConst: always returns the fixed key" {
    // Arrange
    const map_fn = enqueueConst(TestSecondary, "my-ns", "my-singleton");

    // Act
    const obj1 = TestSecondary{};
    const result1 = map_fn(testing.allocator, &obj1).?;

    // Assert
    try testing.expectEqualStrings("my-ns", result1.namespace);
    try testing.expectEqualStrings("my-singleton", result1.name);

    const obj2 = TestSecondary{
        .metadata = .{ .name = "something-else", .namespace = "other" },
    };
    const result2 = map_fn(testing.allocator, &obj2).?;

    try testing.expectEqualStrings("my-ns", result2.namespace);
    try testing.expectEqualStrings("my-singleton", result2.name);
}

test "enqueueOwner: type without ownerReferences field compiles and returns null" {
    // Arrange
    const NoRefsMeta = struct {
        name: ?[]const u8 = null,
        namespace: ?[]const u8 = null,
    };
    const NoRefsType = struct {
        metadata: ?NoRefsMeta = null,
    };
    const map_fn = enqueueOwner(NoRefsType, "Deployment");
    const obj = NoRefsType{ .metadata = .{ .name = "test", .namespace = "ns" } };

    // Act / Assert
    try testing.expect(map_fn(testing.allocator, &obj) == null);
}

test "enqueueOwner: type without metadata field compiles and returns null" {
    // Arrange
    const NoMetaType = struct {
        spec: ?[]const u8 = null,
    };
    const map_fn = enqueueOwner(NoMetaType, "Deployment");
    const obj = NoMetaType{ .spec = "test" };

    // Act / Assert
    try testing.expect(map_fn(testing.allocator, &obj) == null);
}
