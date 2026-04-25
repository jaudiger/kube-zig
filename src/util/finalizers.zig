//! Helpers for managing Kubernetes finalizers on resource metadata.
//!
//! Low-level functions (`hasFinalizer`, `addFinalizer`, `removeFinalizer`)
//! operate directly on a metadata struct's `finalizers` field. High-level
//! functions (`ensureFinalizer`, `removeFinalizerAndUpdate`) perform a
//! GET-modify-PUT cycle with automatic retry on 409 Conflict.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const Api_mod = @import("../api/Api.zig");
const retry_conflict = @import("retry_conflict.zig");

// Low-level helpers
// These work directly on any metadata struct (or pointer to one) that
// has a `finalizers: ?[]const []const u8` field.

/// Check whether `finalizer` is present in `metadata.finalizers`.
/// Null-safe: returns false when finalizers is null.
pub fn hasFinalizer(metadata: anytype, finalizer: []const u8) bool {
    const finalizers = metadata.finalizers orelse return false;
    for (finalizers) |f| {
        if (std.mem.eql(u8, f, finalizer)) return true;
    }
    return false;
}

/// Append `finalizer` to `metadata.finalizers` if not already present.
/// Each allocating code path uses a single allocation followed by an
/// infallible fill. The caller is responsible for freeing the returned
/// slice when done (the previous slice, typically owned by a JSON parse
/// arena, is NOT freed).
/// Returns `true` if the finalizer was added, `false` if already present.
pub fn addFinalizer(metadata: anytype, allocator: Allocator, finalizer: []const u8) !bool {
    const old = metadata.finalizers orelse {
        // Allocate
        const new = try allocator.alloc([]const u8, 1);
        errdefer comptime unreachable;

        // Fill
        new[0] = finalizer;
        metadata.finalizers = new;
        return true;
    };

    for (old) |f| {
        if (std.mem.eql(u8, f, finalizer)) return false;
    }

    // Allocate
    const new = try allocator.alloc([]const u8, old.len + 1);
    errdefer comptime unreachable;

    // Fill
    @memcpy(new[0..old.len], old);
    new[old.len] = finalizer;
    metadata.finalizers = new;
    return true;
}

/// Remove `finalizer` from `metadata.finalizers` using swap-remove
/// (finalizer order is irrelevant in Kubernetes). Does NOT allocate.
/// Returns `true` if the finalizer was found and removed.
///
/// After removal, `metadata.finalizers` is a sub-slice of the original.
/// If the caller previously allocated the slice (via `addFinalizer`),
/// they must free the *original* allocation, not the shortened sub-slice.
pub fn removeFinalizer(metadata: anytype, finalizer: []const u8) bool {
    const finalizers = metadata.finalizers orelse return false;
    for (finalizers, 0..) |f, i| {
        if (std.mem.eql(u8, f, finalizer)) {
            const mutable: [][]const u8 = @constCast(finalizers);
            const last = finalizers.len - 1;
            if (i != last) {
                mutable[i] = mutable[last];
            }
            metadata.finalizers = finalizers[0..last];
            return true;
        }
    }
    return false;
}

// High-level helpers
/// GET the resource, add the finalizer if missing, and PUT it back.
/// Retries automatically on 409 Conflict (resourceVersion mismatch).
pub fn ensureFinalizer(
    comptime T: type,
    io: std.Io,
    api: Api_mod.Api(T),
    allocator: Allocator,
    name: []const u8,
    finalizer: []const u8,
) anyerror!void {
    const Ctx = struct {
        io: std.Io,
        api: Api_mod.Api(T),
        allocator: Allocator,
        name: []const u8,
        finalizer: []const u8,

        fn action(self: @This()) anyerror!void {
            const result = try self.api.get(self.io, self.name);
            var resource = try result.value();
            defer resource.deinit();

            if (resource.value.metadata) |*meta_ptr| {
                if (!hasFinalizer(meta_ptr, self.finalizer)) {
                    const added = try addFinalizer(meta_ptr, self.allocator, self.finalizer);
                    if (added) {
                        defer self.allocator.free(meta_ptr.finalizers.?);
                        const update_result = try self.api.update(self.io, self.name, resource.value, .{});
                        (try update_result.value()).deinit();
                    }
                }
            }
        }
    };
    try retry_conflict.retryOnConflict(
        io,
        Ctx,
        .{ .io = io, .api = api, .allocator = allocator, .name = name, .finalizer = finalizer },
        Ctx.action,
        retry_conflict.default_conflict_policy,
        api.ctx,
    );
}

/// GET the resource, remove the finalizer if present, and PUT it back.
/// Retries automatically on 409 Conflict (resourceVersion mismatch).
pub fn removeFinalizerAndUpdate(
    comptime T: type,
    io: std.Io,
    api: Api_mod.Api(T),
    name: []const u8,
    finalizer: []const u8,
) anyerror!void {
    const Ctx = struct {
        io: std.Io,
        api: Api_mod.Api(T),
        name: []const u8,
        finalizer: []const u8,

        fn action(self: @This()) anyerror!void {
            const result = try self.api.get(self.io, self.name);
            var resource = try result.value();
            defer resource.deinit();

            if (resource.value.metadata) |*meta_ptr| {
                if (removeFinalizer(meta_ptr, self.finalizer)) {
                    const update_result = try self.api.update(self.io, self.name, resource.value, .{});
                    (try update_result.value()).deinit();
                }
            }
        }
    };
    try retry_conflict.retryOnConflict(
        io,
        Ctx,
        .{ .io = io, .api = api, .name = name, .finalizer = finalizer },
        Ctx.action,
        retry_conflict.default_conflict_policy,
        api.ctx,
    );
}

const TestMeta = @import("../test_types.zig").TestMeta;

// hasFinalizer tests
test "hasFinalizer: returns false when finalizers is null" {
    // Act / Assert
    const meta = TestMeta{};
    try testing.expect(!hasFinalizer(meta, "my-finalizer"));
}

test "hasFinalizer: returns false when finalizer not present" {
    // Act / Assert
    const fins = [_][]const u8{"other-finalizer"};
    const meta = TestMeta{ .finalizers = &fins };
    try testing.expect(!hasFinalizer(meta, "my-finalizer"));
}

test "hasFinalizer: returns true when finalizer is present" {
    // Act / Assert
    const fins = [_][]const u8{ "a", "my-finalizer", "b" };
    const meta = TestMeta{ .finalizers = &fins };
    try testing.expect(hasFinalizer(meta, "my-finalizer"));
}

test "hasFinalizer: works through pointer" {
    // Act / Assert
    const fins = [_][]const u8{"my-finalizer"};
    var meta = TestMeta{ .finalizers = &fins };
    try testing.expect(hasFinalizer(&meta, "my-finalizer"));
}

// addFinalizer tests
test "addFinalizer: adds to null finalizers" {
    // Act / Assert
    var meta = TestMeta{};
    const added = try addFinalizer(&meta, testing.allocator, "my-finalizer");
    defer testing.allocator.free(meta.finalizers.?);
    try testing.expect(added);
    try testing.expectEqual(@as(usize, 1), meta.finalizers.?.len);
    try testing.expectEqualStrings("my-finalizer", meta.finalizers.?[0]);
}

test "addFinalizer: appends to existing finalizers" {
    // Act / Assert
    const old = [_][]const u8{"existing"};
    var meta = TestMeta{ .finalizers = &old };
    const added = try addFinalizer(&meta, testing.allocator, "new-one");
    defer testing.allocator.free(meta.finalizers.?);
    try testing.expect(added);
    try testing.expectEqual(@as(usize, 2), meta.finalizers.?.len);
    try testing.expectEqualStrings("existing", meta.finalizers.?[0]);
    try testing.expectEqualStrings("new-one", meta.finalizers.?[1]);
}

test "addFinalizer: idempotent when already present" {
    // Act / Assert
    const old = [_][]const u8{"my-finalizer"};
    var meta = TestMeta{ .finalizers = &old };
    const added = try addFinalizer(&meta, testing.allocator, "my-finalizer");
    try testing.expect(!added);
    try testing.expectEqual(@as(usize, 1), meta.finalizers.?.len);
}

// removeFinalizer tests
test "removeFinalizer: returns false when finalizers is null" {
    // Act / Assert
    var meta = TestMeta{};
    try testing.expect(!removeFinalizer(&meta, "my-finalizer"));
}

test "removeFinalizer: returns false when finalizer not present" {
    // Act / Assert
    var fins = [_][]const u8{"other"};
    var meta = TestMeta{ .finalizers = &fins };
    try testing.expect(!removeFinalizer(&meta, "my-finalizer"));
    try testing.expectEqual(@as(usize, 1), meta.finalizers.?.len);
}

test "removeFinalizer: removes sole finalizer" {
    // Act / Assert
    var fins = [_][]const u8{"my-finalizer"};
    var meta = TestMeta{ .finalizers = &fins };
    try testing.expect(removeFinalizer(&meta, "my-finalizer"));
    try testing.expectEqual(@as(usize, 0), meta.finalizers.?.len);
}

test "removeFinalizer: swap-removes from middle" {
    // Act / Assert
    var fins = [_][]const u8{ "a", "target", "c" };
    var meta = TestMeta{ .finalizers = &fins };
    try testing.expect(removeFinalizer(&meta, "target"));
    try testing.expectEqual(@as(usize, 2), meta.finalizers.?.len);
    try testing.expectEqualStrings("a", meta.finalizers.?[0]);
    try testing.expectEqualStrings("c", meta.finalizers.?[1]);
}

test "removeFinalizer: removes last element without swap" {
    // Act / Assert
    var fins = [_][]const u8{ "a", "b", "target" };
    var meta = TestMeta{ .finalizers = &fins };
    try testing.expect(removeFinalizer(&meta, "target"));
    try testing.expectEqual(@as(usize, 2), meta.finalizers.?.len);
    try testing.expectEqualStrings("a", meta.finalizers.?[0]);
    try testing.expectEqualStrings("b", meta.finalizers.?[1]);
}

test "addFinalizer then removeFinalizer round-trip" {
    // Arrange
    var meta = TestMeta{};

    // Act
    const added = try addFinalizer(&meta, testing.allocator, "controller.io/protect");
    try testing.expect(added);

    // Assert
    // Save the allocated slice before removeFinalizer shrinks it.
    const allocated = meta.finalizers.?;

    const removed = removeFinalizer(&meta, "controller.io/protect");
    try testing.expect(removed);
    try testing.expectEqual(@as(usize, 0), meta.finalizers.?.len);

    // Free the original allocation (not the shortened sub-slice).
    testing.allocator.free(allocated);
}

// High-level ensureFinalizer / removeFinalizerAndUpdate tests
const MockTransport = @import("../client/mock.zig").MockTransport;

test "ensureFinalizer: adds finalizer via GET-PUT with retry" {
    // Arrange
    const types = @import("types");
    const CoreV1Pod = types.core_v1.CoreV1Pod;
    const Api = Api_mod.Api;

    // Act
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    // Assert
    // GET response: pod without finalizers
    mock.respondWith(.ok,
        \\{"metadata":{"name":"test-pod","namespace":"default","resourceVersion":"1"}}
    );
    // PUT response: success
    mock.respondWith(.ok,
        \\{"metadata":{"name":"test-pod","namespace":"default","resourceVersion":"2","finalizers":["my-finalizer"]}}
    );

    var c = mock.client();
    defer c.deinit();

    const pods = Api(CoreV1Pod).init(&c, c.context(), "default");

    try ensureFinalizer(CoreV1Pod, pods, testing.allocator, "test-pod", "my-finalizer");

    // Verify GET then PUT were sent.
    try testing.expectEqual(@as(usize, 2), mock.requestCount());
    try testing.expectEqual(std.http.Method.GET, mock.getRequest(0).?.method);
    try testing.expectEqual(std.http.Method.PUT, mock.getRequest(1).?.method);
    // PUT body should contain the finalizer.
    try testing.expect(mock.getRequest(1).?.serialized_body != null);
    try testing.expect(std.mem.indexOf(u8, mock.getRequest(1).?.serialized_body.?, "my-finalizer") != null);
}

test "ensureFinalizer: skips PUT when finalizer already present" {
    // Arrange
    const types = @import("types");
    const CoreV1Pod = types.core_v1.CoreV1Pod;
    const Api = Api_mod.Api;

    // Act
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    // Assert
    // GET response: pod already has the finalizer
    mock.respondWith(.ok,
        \\{"metadata":{"name":"test-pod","namespace":"default","resourceVersion":"1","finalizers":["my-finalizer"]}}
    );

    var c = mock.client();
    defer c.deinit();

    const pods = Api(CoreV1Pod).init(&c, c.context(), "default");

    try ensureFinalizer(CoreV1Pod, pods, testing.allocator, "test-pod", "my-finalizer");

    // Only GET, no PUT needed.
    try testing.expectEqual(@as(usize, 1), mock.requestCount());
}

test "ensureFinalizer: retries on 409 Conflict" {
    // Arrange
    const types = @import("types");
    const CoreV1Pod = types.core_v1.CoreV1Pod;
    const Api = Api_mod.Api;

    // Act
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    // Assert
    // First attempt: GET ok, PUT 409
    mock.respondWith(.ok,
        \\{"metadata":{"name":"test-pod","namespace":"default","resourceVersion":"1"}}
    );
    mock.respondWith(.conflict,
        \\{"kind":"Status","apiVersion":"v1","status":"Failure","reason":"Conflict","code":409}
    );
    // Retry: GET (new resourceVersion), PUT ok
    mock.respondWith(.ok,
        \\{"metadata":{"name":"test-pod","namespace":"default","resourceVersion":"2"}}
    );
    mock.respondWith(.ok,
        \\{"metadata":{"name":"test-pod","namespace":"default","resourceVersion":"3","finalizers":["my-finalizer"]}}
    );

    var c = mock.client();
    defer c.deinit();

    const pods = Api(CoreV1Pod).init(&c, c.context(), "default");

    try ensureFinalizer(CoreV1Pod, pods, testing.allocator, "test-pod", "my-finalizer");

    // GET + PUT (409) + GET + PUT (ok) = 4 requests
    try testing.expectEqual(@as(usize, 4), mock.requestCount());
}

test "removeFinalizerAndUpdate: removes finalizer via GET-PUT" {
    // Arrange
    const types = @import("types");
    const CoreV1Pod = types.core_v1.CoreV1Pod;
    const Api = Api_mod.Api;

    // Act
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    // Assert
    // GET response: pod with finalizer
    mock.respondWith(.ok,
        \\{"metadata":{"name":"test-pod","namespace":"default","resourceVersion":"1","finalizers":["my-finalizer"]}}
    );
    // PUT response: success
    mock.respondWith(.ok,
        \\{"metadata":{"name":"test-pod","namespace":"default","resourceVersion":"2"}}
    );

    var c = mock.client();
    defer c.deinit();

    const pods = Api(CoreV1Pod).init(&c, c.context(), "default");

    try removeFinalizerAndUpdate(CoreV1Pod, pods, "test-pod", "my-finalizer");

    try testing.expectEqual(@as(usize, 2), mock.requestCount());
    try testing.expectEqual(std.http.Method.PUT, mock.getRequest(1).?.method);
}

test "removeFinalizerAndUpdate: skips PUT when finalizer absent" {
    // Arrange
    const types = @import("types");
    const CoreV1Pod = types.core_v1.CoreV1Pod;
    const Api = Api_mod.Api;

    // Act
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    // Assert
    // GET response: pod without the target finalizer
    mock.respondWith(.ok,
        \\{"metadata":{"name":"test-pod","namespace":"default","resourceVersion":"1","finalizers":["other"]}}
    );

    var c = mock.client();
    defer c.deinit();

    const pods = Api(CoreV1Pod).init(&c, c.context(), "default");

    try removeFinalizerAndUpdate(CoreV1Pod, pods, "test-pod", "my-finalizer");

    // Only GET, no PUT needed.
    try testing.expectEqual(@as(usize, 1), mock.requestCount());
}
