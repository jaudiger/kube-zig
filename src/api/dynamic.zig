//! Dynamic (untyped) Kubernetes API for runtime-resolved resource types.
//!
//! Provides `DynamicApi`, which offers the same CRUD surface as the
//! comptime `Api(T)` but uses runtime `ResourceMeta` instead of comptime
//! `resource_meta`. All responses are returned as `std.json.Value`, and
//! request bodies are passed as pre-serialized JSON strings.

const std = @import("std");
const client_mod = @import("../client/Client.zig");
const Client = client_mod.Client;
const Context = client_mod.Context;
const deepClone = @import("../util/deep_clone.zig").deepClone;
const options_mod = @import("options.zig");
const query = @import("query.zig");
const watch_mod = @import("watch.zig");
const path_mod = @import("path.zig");
const PathBuilder = path_mod.PathBuilder;
const testing = std.testing;

const Json = std.json.Value;
const JsonResult = Client.ApiResult(std.json.Parsed(Json));

/// Runtime resource metadata for dynamic (untyped) API access.
///
/// This is the runtime equivalent of the comptime `resource_meta` declaration
/// used by `Api(T)`. Unlike `resource_meta`, there is no `list_kind` field
/// since all responses are returned as `std.json.Value`.
pub const ResourceMeta = struct {
    /// API group: `""` for the core group, `"apps"`, `"batch"`, etc.
    group: []const u8,
    /// API version: `"v1"`, `"v1beta1"`, etc.
    version: []const u8,
    /// Kind string: `"Pod"`, `"Deployment"`, etc.
    kind: []const u8 = "",
    /// Plural resource name: `"pods"`, `"deployments"`, etc.
    resource: []const u8,
    /// Whether the resource is namespaced or cluster-scoped.
    namespaced: bool,

    /// Validate that fields are safe for URL path interpolation.
    /// Reject empty or slash-containing version/resource, slash-containing group
    /// (empty group is valid for the core API group), and empty kind.
    pub fn validate(self: ResourceMeta) !void {
        if (self.version.len == 0 or std.mem.indexOfScalar(u8, self.version, '/') != null)
            return error.InvalidResourceMeta;
        if (self.resource.len == 0 or std.mem.indexOfScalar(u8, self.resource, '/') != null)
            return error.InvalidResourceMeta;
        if (std.mem.indexOfScalar(u8, self.group, '/') != null)
            return error.InvalidResourceMeta;
        if (self.kind.len == 0)
            return error.InvalidResourceMeta;
    }
};

// Option type aliases (private; external consumers import from root.zig).
const ListOptions = options_mod.ListOptions;
const WriteOptions = options_mod.WriteOptions;
const DeleteOptions = options_mod.DeleteOptions;
const PatchOptions = options_mod.PatchOptions;
const PatchType = options_mod.PatchType;
const WatchOptions = options_mod.WatchOptions;
const LogOptions = options_mod.LogOptions;
const ApplyOptions = options_mod.ApplyOptions;

/// Dynamic (untyped) Kubernetes API for runtime-defined resource types.
///
/// Provides the same CRUD surface as `Api(T)` but uses runtime `ResourceMeta`
/// instead of comptime `resource_meta`. All responses are `std.json.Value`.
/// Bodies for create/update/patch are passed as pre-serialized JSON (`[]const u8`).
///
/// Usage:
///   const api = DynamicApi.init(&client, .{
///       .group = "stable.example.com",
///       .version = "v1",
///       .resource = "crontabs",
///       .namespaced = true,
///   }, "default");
///   const list_result = try (try api.list(.{})).value();
///   defer list_result.deinit();
pub const DynamicApi = struct {
    client: *Client,
    ctx: Context,
    meta: ResourceMeta,
    namespace: ?[]const u8,

    /// Create a DynamicApi handle. Perform no allocations; all fields are borrowed.
    /// Return `error.InvalidResourceMeta` if `meta` contains invalid fields.
    pub fn init(client: *Client, ctx: Context, meta: ResourceMeta, namespace: ?[]const u8) !DynamicApi {
        try meta.validate();
        return .{ .client = client, .ctx = ctx, .meta = meta, .namespace = namespace };
    }

    fn pathBuilder(self: DynamicApi) PathBuilder {
        return .{
            .allocator = self.client.allocator,
            .group = self.meta.group,
            .version = self.meta.version,
            .resource = self.meta.resource,
            .namespaced = self.meta.namespaced,
            .namespace = self.namespace,
        };
    }

    // CRUD methods
    /// List all resources in the configured namespace, or cluster-wide for cluster-scoped resources.
    pub fn list(self: DynamicApi, opts: ListOptions) !JsonResult {
        const path = try self.pathBuilder().listPath(opts);
        defer self.client.allocator.free(path);
        return self.client.get(Json, path, self.ctx);
    }

    /// List all resources across all namespaces (cluster-wide).
    /// Only available for namespaced resources; returns `error.NotNamespaced`
    /// for cluster-scoped resources.
    pub fn listAll(self: DynamicApi, opts: ListOptions) !JsonResult {
        if (!self.meta.namespaced) return error.NotNamespaced;
        const path = try self.pathBuilder().listAllPath(opts);
        defer self.client.allocator.free(path);
        return self.client.get(Json, path, self.ctx);
    }

    /// Get a single resource by name.
    pub fn get(self: DynamicApi, name: []const u8) !JsonResult {
        const path = try self.pathBuilder().resourcePath(name);
        defer self.client.allocator.free(path);
        return self.client.get(Json, path, self.ctx);
    }

    /// Create a new resource from pre-serialized JSON.
    pub fn create(self: DynamicApi, body: []const u8, opts: WriteOptions) !JsonResult {
        const path = try self.pathBuilder().createPath(opts);
        defer self.client.allocator.free(path);
        return self.client.post(Json, path, body, self.ctx);
    }

    /// Update (PUT) an existing resource by name from pre-serialized JSON.
    pub fn update(self: DynamicApi, name: []const u8, body: []const u8, opts: WriteOptions) !JsonResult {
        const path = try self.pathBuilder().updatePath(name, opts);
        defer self.client.allocator.free(path);
        return self.client.put(Json, path, body, self.ctx);
    }

    /// Delete a resource by name.
    pub fn delete(self: DynamicApi, name: []const u8, opts: DeleteOptions) !Client.ApiResult(Client.RawResponse) {
        const path = try self.pathBuilder().resourcePath(name);
        defer self.client.allocator.free(path);
        const delete_body = try query.serializeDeleteOpts(self.client.allocator, opts);
        defer if (delete_body) |b| self.client.allocator.free(b);
        return self.client.delete(path, delete_body, self.ctx);
    }

    /// Patch a resource by name with a raw patch body.
    pub fn patch(self: DynamicApi, name: []const u8, patch_body: []const u8, opts: PatchOptions) !JsonResult {
        const path = try self.pathBuilder().patchPath(name, opts);
        defer self.client.allocator.free(path);
        return self.client.patch(Json, path, patch_body, opts.patch_type.contentType(), self.ctx);
    }

    /// Apply (SSA) a resource using a JSON value body.
    ///
    /// Set `apiVersion` and `kind` on the body from `ResourceMeta` before
    /// serializing. Send as an `application/apply-patch+yaml` PATCH request.
    /// The `kind` field must be set on `ResourceMeta` for this to work correctly.
    pub fn apply(self: DynamicApi, name: []const u8, body: Json, opts: ApplyOptions) !JsonResult {
        return self.applyInternal(name, body, opts, null);
    }

    /// Apply (SSA) to the /status subresource.
    pub fn applyStatus(self: DynamicApi, name: []const u8, body: Json, opts: ApplyOptions) !JsonResult {
        return self.applyInternal(name, body, opts, "status");
    }

    fn applyInternal(self: DynamicApi, name: []const u8, body: Json, opts: ApplyOptions, subresource: ?[]const u8) !JsonResult {
        std.debug.assert(self.meta.kind.len > 0);
        const alloc = self.client.allocator;

        // Build apiVersion string: "v1" for core group, "apps/v1" for named groups.
        const api_version = if (self.meta.group.len == 0)
            self.meta.version
        else blk: {
            break :blk try std.fmt.allocPrint(alloc, "{s}/{s}", .{ self.meta.group, self.meta.version });
        };
        defer if (self.meta.group.len > 0) alloc.free(api_version);

        // Deep-clone the body into a temporary arena so that mutating
        // apiVersion/kind does not affect the caller's original object.
        var clone_arena = std.heap.ArenaAllocator.init(alloc);
        defer clone_arena.deinit();
        var patched = try deepClone(Json, clone_arena.allocator(), body);
        switch (patched) {
            .object => |*obj| {
                try obj.put("apiVersion", .{ .string = api_version });
                try obj.put("kind", .{ .string = self.meta.kind });
            },
            else => {},
        }

        // Serialize to JSON.
        const json_body = try std.fmt.allocPrint(alloc, "{f}", .{
            std.json.fmt(patched, .{ .emit_null_optional_fields = false }),
        });
        defer alloc.free(json_body);

        const patch_opts = PatchOptions{
            .patch_type = .apply,
            .field_manager = opts.field_manager,
            .force = opts.force,
        };

        const pb = self.pathBuilder();
        const apply_base = if (subresource) |sub|
            try pb.subresourcePath(name, sub)
        else
            try pb.resourcePath(name);

        const path = try query.appendPatchQueryParams(alloc, apply_base, patch_opts);
        defer alloc.free(path);

        return self.client.patch(Json, path, json_body, PatchType.apply.contentType(), self.ctx);
    }

    /// Watch for changes to resources in the configured namespace.
    pub fn watch(self: DynamicApi, opts: WatchOptions) !watch_mod.WatchStream(Json) {
        const path = try self.pathBuilder().watchPath(opts);
        defer self.client.allocator.free(path);
        return watch_mod.WatchStream(Json).init(self.client, self.ctx, path, opts.max_line_size);
    }

    /// Watch for changes to resources across all namespaces.
    /// Only available for namespaced resources; returns `error.NotNamespaced`
    /// for cluster-scoped resources.
    pub fn watchAll(self: DynamicApi, opts: WatchOptions) !watch_mod.WatchStream(Json) {
        if (!self.meta.namespaced) return error.NotNamespaced;
        const path = try self.pathBuilder().watchAllPath(opts);
        defer self.client.allocator.free(path);
        return watch_mod.WatchStream(Json).init(self.client, self.ctx, path, opts.max_line_size);
    }

    // Subresource methods
    /// Get a named subresource (e.g. "status", "scale").
    pub fn getSubresource(self: DynamicApi, name: []const u8, subresource: []const u8) !JsonResult {
        const path = try self.pathBuilder().subresourcePath(name, subresource);
        defer self.client.allocator.free(path);
        return self.client.get(Json, path, self.ctx);
    }

    /// Update (PUT) a named subresource from pre-serialized JSON.
    pub fn updateSubresource(self: DynamicApi, name: []const u8, subresource: []const u8, body: []const u8) !JsonResult {
        const path = try self.pathBuilder().subresourcePath(name, subresource);
        defer self.client.allocator.free(path);
        return self.client.put(Json, path, body, self.ctx);
    }

    /// Patch a named subresource with a raw patch body.
    pub fn patchSubresource(self: DynamicApi, name: []const u8, subresource: []const u8, patch_body: []const u8, opts: PatchOptions) !JsonResult {
        const path = try self.pathBuilder().subresourcePatchPath(name, subresource, opts);
        defer self.client.allocator.free(path);
        return self.client.patch(Json, path, patch_body, opts.patch_type.contentType(), self.ctx);
    }

    /// Get the /status subresource.
    pub fn getStatus(self: DynamicApi, name: []const u8) !JsonResult {
        return self.getSubresource(name, "status");
    }

    /// Update (PUT) the /status subresource from pre-serialized JSON.
    pub fn updateStatus(self: DynamicApi, name: []const u8, body: []const u8) !JsonResult {
        return self.updateSubresource(name, "status", body);
    }

    /// Patch the /status subresource with a raw patch body.
    pub fn patchStatus(self: DynamicApi, name: []const u8, patch_body: []const u8, opts: PatchOptions) !JsonResult {
        return self.patchSubresource(name, "status", patch_body, opts);
    }

    /// Get a raw subresource (e.g. /log). Return raw bytes rather than parsed JSON.
    pub fn getRaw(self: DynamicApi, name: []const u8, subresource: []const u8) !Client.ApiResult(Client.RawResponse) {
        const path = try self.pathBuilder().subresourcePath(name, subresource);
        defer self.client.allocator.free(path);
        return self.client.getRaw(path, self.ctx);
    }
};

// listAll guard
test "listAll: cluster-scoped returns error.NotNamespaced" {
    // Arrange
    var client = try Client.init(testing.allocator, "http://127.0.0.1:8001", .{});
    defer client.deinit();
    const api = try DynamicApi.init(&client, client.context(), .{
        .group = "",
        .version = "v1",
        .kind = "Node",
        .resource = "nodes",
        .namespaced = false,
    }, null);

    // Act / Assert
    try testing.expectError(error.NotNamespaced, api.listAll(.{}));
}

// watchAll guard
test "watchAll: cluster-scoped returns error.NotNamespaced" {
    // Arrange
    var client = try Client.init(testing.allocator, "http://127.0.0.1:8001", .{});
    defer client.deinit();
    const api = try DynamicApi.init(&client, client.context(), .{
        .group = "",
        .version = "v1",
        .kind = "Node",
        .resource = "nodes",
        .namespaced = false,
    }, null);

    // Act / Assert
    try testing.expectError(error.NotNamespaced, api.watchAll(.{}));
}

// ResourceMeta validation tests
test "ResourceMeta validate: valid metadata passes" {
    // Arrange
    const meta = ResourceMeta{
        .group = "apps",
        .version = "v1",
        .kind = "Deployment",
        .resource = "deployments",
        .namespaced = true,
    };

    // Act / Assert
    try meta.validate();
}

test "ResourceMeta validate: empty group is valid (core API group)" {
    // Arrange
    const meta = ResourceMeta{
        .group = "",
        .version = "v1",
        .kind = "Pod",
        .resource = "pods",
        .namespaced = true,
    };

    // Act / Assert
    try meta.validate();
}

test "ResourceMeta validate: empty version returns error" {
    // Arrange
    const meta = ResourceMeta{
        .group = "",
        .version = "",
        .kind = "Pod",
        .resource = "pods",
        .namespaced = true,
    };

    // Act / Assert
    try testing.expectError(error.InvalidResourceMeta, meta.validate());
}

test "ResourceMeta validate: version with slash returns error" {
    // Arrange
    const meta = ResourceMeta{
        .group = "",
        .version = "v1/beta1",
        .kind = "Pod",
        .resource = "pods",
        .namespaced = true,
    };

    // Act / Assert
    try testing.expectError(error.InvalidResourceMeta, meta.validate());
}

test "ResourceMeta validate: empty resource returns error" {
    // Arrange
    const meta = ResourceMeta{
        .group = "",
        .version = "v1",
        .kind = "Pod",
        .resource = "",
        .namespaced = true,
    };

    // Act / Assert
    try testing.expectError(error.InvalidResourceMeta, meta.validate());
}

test "ResourceMeta validate: resource with slash returns error" {
    // Arrange
    const meta = ResourceMeta{
        .group = "",
        .version = "v1",
        .kind = "Pod",
        .resource = "pods/status",
        .namespaced = true,
    };

    // Act / Assert
    try testing.expectError(error.InvalidResourceMeta, meta.validate());
}

test "ResourceMeta validate: group with slash returns error" {
    // Arrange
    const meta = ResourceMeta{
        .group = "apps/evil",
        .version = "v1",
        .kind = "Deployment",
        .resource = "deployments",
        .namespaced = true,
    };

    // Act / Assert
    try testing.expectError(error.InvalidResourceMeta, meta.validate());
}

test "ResourceMeta validate: empty kind returns error" {
    // Arrange
    const meta = ResourceMeta{
        .group = "",
        .version = "v1",
        .resource = "pods",
        .namespaced = true,
    };

    // Act / Assert
    try testing.expectError(error.InvalidResourceMeta, meta.validate());
}

test "DynamicApi.init: invalid metadata returns error" {
    // Arrange
    var client = try Client.init(testing.allocator, "http://127.0.0.1:8001", .{});
    defer client.deinit();

    // Act / Assert
    try testing.expectError(error.InvalidResourceMeta, DynamicApi.init(&client, client.context(), .{
        .group = "",
        .version = "",
        .kind = "Pod",
        .resource = "pods",
        .namespaced = true,
    }, "default"));
}

test "DynamicApi.init: resource with slash returns error" {
    // Arrange
    var client = try Client.init(testing.allocator, "http://127.0.0.1:8001", .{});
    defer client.deinit();

    // Act / Assert
    try testing.expectError(error.InvalidResourceMeta, DynamicApi.init(&client, client.context(), .{
        .group = "",
        .version = "v1",
        .kind = "Pod",
        .resource = "../pods",
        .namespaced = true,
    }, "default"));
}

// applyInternal body isolation test
test "applyInternal does not mutate the caller's body" {
    // Arrange
    var obj = std.json.ObjectMap.init(testing.allocator);
    defer obj.deinit();
    try obj.put("metadata", .{ .object = blk: {
        var meta = std.json.ObjectMap.init(testing.allocator);
        try meta.put("name", .{ .string = "my-pod" });
        break :blk meta;
    } });
    const body: Json = .{ .object = obj };

    // Act
    // We cannot call applyInternal directly (it requires a real Client
    // connection), so we replicate its patching logic to verify the
    // deep-clone strategy works.
    var clone_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer clone_arena.deinit();
    var patched = try deepClone(Json, clone_arena.allocator(), body);
    switch (patched) {
        .object => |*patched_obj| {
            try patched_obj.put("apiVersion", .{ .string = "v1" });
            try patched_obj.put("kind", .{ .string = "Pod" });
        },
        else => {},
    }

    // Assert
    try testing.expect(obj.get("apiVersion") == null);
    try testing.expect(obj.get("kind") == null);
    try testing.expectEqual(@as(u32, 1), obj.count());
    try testing.expectEqualStrings("my-pod", obj.get("metadata").?.object.get("name").?.string);
}
