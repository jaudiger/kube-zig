//! Generic, type-safe Kubernetes API for performing CRUD operations on resources.
//!
//! Provides `Api(T)`, a comptime-generic struct that reads `T.resource_meta`
//! to construct correct Kubernetes API URL paths. Supports list, get, create,
//! update, delete, patch, watch, server-side apply, subresource access, and
//! transparent pagination via `collectAll`.

const std = @import("std");
const client_mod = @import("../client/Client.zig");
const Client = client_mod.Client;
const Context = client_mod.Context;
const watch_mod = @import("watch.zig");
const deepClone = @import("../util/deep_clone.zig").deepClone;
const options_mod = @import("options.zig");
const query = @import("query.zig");
const path_mod = @import("path.zig");
const PathBuilder = path_mod.PathBuilder;
const testing = std.testing;

const ThisModule = @This();

// Option type aliases (private; external consumers import from root.zig)
const PatchType = options_mod.PatchType;
const PatchOptions = options_mod.PatchOptions;
const ResourceVersionMatch = options_mod.ResourceVersionMatch;
const PropagationPolicy = options_mod.PropagationPolicy;
const ListOptions = options_mod.ListOptions;
const WatchOptions = options_mod.WatchOptions;
const WriteOptions = options_mod.WriteOptions;
const ApplyOptions = options_mod.ApplyOptions;
const DeleteOptions = options_mod.DeleteOptions;
const LogOptions = options_mod.LogOptions;

// Comptime validation
/// Validate that `T` has a well-formed `resource_meta` declaration at comptime.
/// Produce clear compile errors when the declaration is missing or malformed.
fn validateResourceMeta(comptime T: type) void {
    const type_name = @typeName(T);

    if (!@hasDecl(T, "resource_meta")) {
        @compileError("type '" ++ type_name ++ "' is missing a 'resource_meta' declaration; " ++
            "only generated Kubernetes resource types with API endpoints can be used with Api(T)");
    }

    const meta = T.resource_meta;
    const MetaType = @TypeOf(meta);

    if (!@hasField(MetaType, "group")) {
        @compileError("'" ++ type_name ++ ".resource_meta' is missing field 'group' (expected []const u8)");
    }
    if (!@hasField(MetaType, "version")) {
        @compileError("'" ++ type_name ++ ".resource_meta' is missing field 'version' (expected []const u8)");
    }
    if (!@hasField(MetaType, "kind")) {
        @compileError("'" ++ type_name ++ ".resource_meta' is missing field 'kind' (expected []const u8)");
    }
    if (!@hasField(MetaType, "resource")) {
        @compileError("'" ++ type_name ++ ".resource_meta' is missing field 'resource' (expected []const u8)");
    }
    if (!@hasField(MetaType, "namespaced")) {
        @compileError("'" ++ type_name ++ ".resource_meta' is missing field 'namespaced' (expected bool)");
    }
    if (@TypeOf(meta.namespaced) != bool) {
        @compileError("'" ++ type_name ++ ".resource_meta.namespaced' must be bool");
    }
    if (!@hasField(MetaType, "list_kind")) {
        @compileError("'" ++ type_name ++ ".resource_meta' is missing field 'list_kind' (expected type)");
    }
    if (@TypeOf(meta.list_kind) != type) {
        @compileError("'" ++ type_name ++ ".resource_meta.list_kind' must be a type");
    }

    // Verify string fields coerce to []const u8 by using them in a comptime context.
    // This works for both `[]const u8` and comptime string literals (`*const [N:0]u8`).
    comptime {
        const group: []const u8 = meta.group;
        const version: []const u8 = meta.version;
        const kind: []const u8 = meta.kind;
        const resource: []const u8 = meta.resource;
        _ = group;
        _ = version;
        _ = kind;
        _ = resource;
    }
}

// Generic API
/// Generic, type-safe Kubernetes API for a given resource type `T`.
///
/// `T` must have a `pub const resource_meta` declaration (generated from OpenAPI paths)
/// containing `.group`, `.version`, `.resource`, `.namespaced`, and `.list_kind`.
///
/// Usage:
///   const pods = Api(CoreV1Pod).init(&client, "default");
///   const list = try pods.list(.{});
///   const pod = try pods.get("my-pod");
pub fn Api(comptime T: type) type {
    comptime validateResourceMeta(T);
    const meta = T.resource_meta;
    const ListT = meta.list_kind;

    return struct {
        client: *Client,
        ctx: Context,
        namespace: ?[]const u8,

        /// Create an API handle for the given client, context, and namespace.
        /// For namespaced resources, `namespace` is required.
        /// For cluster-scoped resources, `namespace` is optional and ignored.
        pub fn init(client: *Client, ctx: Context, namespace: if (meta.namespaced) []const u8 else ?[]const u8) @This() {
            return .{ .client = client, .ctx = ctx, .namespace = namespace };
        }

        const TypedResult = Client.ApiResult;

        fn pathBuilder(self: @This()) PathBuilder {
            return .{
                .allocator = self.client.allocator,
                .group = meta.group,
                .version = meta.version,
                .resource = meta.resource,
                .namespaced = meta.namespaced,
                .namespace = self.namespace,
            };
        }

        /// List all resources in the configured namespace, or cluster-wide for cluster-scoped resources.
        pub fn list(self: @This(), opts: ThisModule.ListOptions) !TypedResult(std.json.Parsed(ListT)) {
            const path = try self.pathBuilder().listPath(opts);
            defer self.client.allocator.free(path);
            return self.client.get(ListT, path, self.ctx);
        }

        /// List all resources across all namespaces (cluster-wide).
        /// Only available for namespaced resources; cluster-scoped resources
        /// are already cluster-wide, use `list()` instead.
        pub fn listAll(self: @This(), opts: ThisModule.ListOptions) !TypedResult(std.json.Parsed(ListT)) {
            if (!meta.namespaced) @compileError("listAll is only available for namespaced resources; use list() instead");
            const path = try self.pathBuilder().listAllPath(opts);
            defer self.client.allocator.free(path);
            return self.client.get(ListT, path, self.ctx);
        }

        /// Watch for changes to resources in the configured namespace.
        /// Return a `WatchStream(T)` iterator that yields typed events.
        /// The caller must call `close()` on the returned stream when done.
        pub fn watch(self: @This(), opts: ThisModule.WatchOptions) !watch_mod.WatchStream(T) {
            const path = try self.pathBuilder().watchPath(opts);
            // Safe to free path after init: WatchStream.init() calls client.watchStream()
            // which copies the path into a URI via buildUri() and opens the HTTP request
            // synchronously. The path slice is not retained by WatchStream.
            defer self.client.allocator.free(path);
            return watch_mod.WatchStream(T).init(self.client, self.ctx, path, opts.max_line_size);
        }

        /// Watch for changes to resources across all namespaces.
        /// Only available for namespaced resources; cluster-scoped resources
        /// are already cluster-wide, use `watch()` instead.
        pub fn watchAll(self: @This(), opts: ThisModule.WatchOptions) !watch_mod.WatchStream(T) {
            if (!meta.namespaced) @compileError("watchAll is only available for namespaced resources; use watch() instead");
            const path = try self.pathBuilder().watchAllPath(opts);
            // Safe to free path after init: see comment in watch() above.
            defer self.client.allocator.free(path);
            return watch_mod.WatchStream(T).init(self.client, self.ctx, path, opts.max_line_size);
        }

        /// Get a single resource by name.
        pub fn get(self: @This(), name: []const u8) !TypedResult(std.json.Parsed(T)) {
            const path = try self.pathBuilder().resourcePath(name);
            defer self.client.allocator.free(path);
            return self.client.get(T, path, self.ctx);
        }

        /// Create a new resource.
        pub fn create(self: @This(), body: T, opts: ThisModule.WriteOptions) !TypedResult(std.json.Parsed(T)) {
            const path = try self.pathBuilder().createPath(opts);
            defer self.client.allocator.free(path);
            return self.client.postValue(T, T, path, &body, self.ctx);
        }

        /// Update (PUT) an existing resource by name.
        /// The `name` must match `body.metadata.name`.
        pub fn update(self: @This(), name: []const u8, body: T, opts: ThisModule.WriteOptions) !TypedResult(std.json.Parsed(T)) {
            if (body.metadata) |m| {
                if (m.name) |body_name| {
                    std.debug.assert(std.mem.eql(u8, name, body_name));
                }
            }
            const path = try self.pathBuilder().updatePath(name, opts);
            defer self.client.allocator.free(path);
            return self.client.putValue(T, T, path, &body, self.ctx);
        }

        /// Delete a resource by name. Return an `ApiResult` wrapping a `RawResponse`
        /// with the raw JSON body, which may be the deleted resource or a
        /// Kubernetes Status object.
        pub fn delete(self: @This(), name: []const u8, opts: ThisModule.DeleteOptions) !Client.ApiResult(Client.RawResponse) {
            const path = try self.pathBuilder().resourcePath(name);
            defer self.client.allocator.free(path);
            const delete_body = try query.serializeDeleteOpts(self.client.allocator, opts);
            defer if (delete_body) |b| self.client.allocator.free(b);
            return self.client.delete(path, delete_body, self.ctx);
        }

        /// Patch a resource by name with a raw patch body.
        /// The caller provides the raw bytes appropriate for the chosen
        /// patch type (JSON merge-patch, strategic merge-patch, etc.).
        pub fn patch(self: @This(), name: []const u8, patch_body: []const u8, opts: ThisModule.PatchOptions) !TypedResult(std.json.Parsed(T)) {
            const path = try self.pathBuilder().patchPath(name, opts);
            defer self.client.allocator.free(path);
            return self.client.patch(T, path, patch_body, opts.patch_type.contentType(), self.ctx);
        }

        // Server-Side Apply methods
        /// Kubernetes API version string for this resource, computed at comptime.
        /// Core group (group == ""): "v1".
        /// Named group: "apps/v1", "batch/v1", etc.
        const api_version = blk: {
            if (meta.group.len == 0) {
                break :blk meta.version;
            } else {
                break :blk meta.group ++ "/" ++ meta.version;
            }
        };

        /// Apply (SSA) a resource using a typed Zig struct.
        ///
        /// Automatically set `apiVersion` and `kind` from `T.resource_meta` on
        /// the body before serializing. Serialize the body to JSON and send it
        /// as an `application/apply-patch+yaml` PATCH request. Kubernetes
        /// accepts JSON for apply patches despite the MIME type name.
        ///
        /// The caller builds a partial object. Since all generated fields are
        /// `?T = null`, only non-null fields appear in the serialized output,
        /// which is exactly what SSA expects.
        pub fn apply(self: @This(), name: []const u8, body: T, opts: ThisModule.ApplyOptions) !TypedResult(std.json.Parsed(T)) {
            return self.applyInternal(name, body, opts, null);
        }

        /// Apply (SSA) to the /status subresource.
        pub fn applyStatus(self: @This(), name: []const u8, body: T, opts: ThisModule.ApplyOptions) !TypedResult(std.json.Parsed(T)) {
            return self.applyInternal(name, body, opts, "status");
        }

        fn applyInternal(self: @This(), name: []const u8, body: T, opts: ThisModule.ApplyOptions, comptime subresource: ?[]const u8) !TypedResult(std.json.Parsed(T)) {
            // Set apiVersion and kind on the body from resource_meta.
            var patched_body = body;
            if (@hasField(T, "apiVersion")) {
                patched_body.apiVersion = api_version;
            }
            if (@hasField(T, "kind")) {
                patched_body.kind = meta.kind;
            }

            // Serialize with null optional fields omitted.
            const alloc = self.client.allocator;
            const json_body = try std.fmt.allocPrint(alloc, "{f}", .{
                std.json.fmt(patched_body, .{ .emit_null_optional_fields = false }),
            });
            defer alloc.free(json_body);

            const patch_opts = ThisModule.PatchOptions{
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

            return self.client.patch(T, path, json_body, ThisModule.PatchType.apply.contentType(), self.ctx);
        }

        // Subresource methods
        /// Get the /status subresource.
        /// The Kubernetes API returns 404 for resources that do not support this subresource.
        pub fn getStatus(self: @This(), name: []const u8) !TypedResult(std.json.Parsed(T)) {
            const path = try self.pathBuilder().subresourcePath(name, "status");
            defer self.client.allocator.free(path);
            return self.client.get(T, path, self.ctx);
        }

        /// Update (PUT) the /status subresource.
        /// The Kubernetes API returns 404 for resources that do not support this subresource.
        pub fn updateStatus(self: @This(), name: []const u8, body: T) !TypedResult(std.json.Parsed(T)) {
            const path = try self.pathBuilder().subresourcePath(name, "status");
            defer self.client.allocator.free(path);
            return self.client.putValue(T, T, path, &body, self.ctx);
        }

        /// Patch the /status subresource.
        /// The Kubernetes API returns 404 for resources that do not support this subresource.
        pub fn patchStatus(self: @This(), name: []const u8, patch_body: []const u8, opts: ThisModule.PatchOptions) !TypedResult(std.json.Parsed(T)) {
            const path = try self.pathBuilder().subresourcePatchPath(name, "status", opts);
            defer self.client.allocator.free(path);
            return self.client.patch(T, path, patch_body, opts.patch_type.contentType(), self.ctx);
        }

        /// Get the /scale subresource. Return `ApiResult(Parsed(ScaleT))`.
        /// The Kubernetes API returns 404 for resources that do not support this subresource.
        ///
        /// Example: `api.getScale(k8s.AutoscalingV1Scale, "my-deployment")`
        pub fn getScale(self: @This(), comptime ScaleT: type, name: []const u8) !TypedResult(std.json.Parsed(ScaleT)) {
            const path = try self.pathBuilder().subresourcePath(name, "scale");
            defer self.client.allocator.free(path);
            return self.client.get(ScaleT, path, self.ctx);
        }

        /// Update (PUT) the /scale subresource. Return `ApiResult(Parsed(ScaleT))`.
        /// The Kubernetes API returns 404 for resources that do not support this subresource.
        ///
        /// Example: `api.updateScale(k8s.AutoscalingV1Scale, "my-deployment", scale_body)`
        pub fn updateScale(self: @This(), comptime ScaleT: type, name: []const u8, body: ScaleT) !TypedResult(std.json.Parsed(ScaleT)) {
            const path = try self.pathBuilder().subresourcePath(name, "scale");
            defer self.client.allocator.free(path);
            return self.client.putValue(ScaleT, ScaleT, path, &body, self.ctx);
        }

        /// Patch the /scale subresource. Return `ApiResult(Parsed(ScaleT))`.
        /// The Kubernetes API returns 404 for resources that do not support this subresource.
        pub fn patchScale(self: @This(), comptime ScaleT: type, name: []const u8, patch_body: []const u8, opts: ThisModule.PatchOptions) !TypedResult(std.json.Parsed(ScaleT)) {
            const path = try self.pathBuilder().subresourcePatchPath(name, "scale", opts);
            defer self.client.allocator.free(path);
            return self.client.patch(ScaleT, path, patch_body, opts.patch_type.contentType(), self.ctx);
        }

        /// Post an eviction to the /eviction subresource.
        /// Return an `ApiResult` wrapping a `RawResponse`.
        /// The Kubernetes API returns 404 for resources that do not support this subresource.
        ///
        /// Example: `api.evict(k8s.PolicyV1Eviction, "my-pod", eviction_body)`
        pub fn evict(self: @This(), comptime EvictionT: type, name: []const u8, body: EvictionT) !Client.ApiResult(Client.RawResponse) {
            const path = try self.pathBuilder().subresourcePath(name, "eviction");
            defer self.client.allocator.free(path);
            return self.client.postValueRaw(EvictionT, path, &body, self.ctx);
        }

        /// Get the /log subresource. Return an `ApiResult` wrapping a `RawResponse`
        /// with raw plain text.
        /// The Kubernetes API returns 404 for resources that do not support this subresource.
        pub fn getLogs(self: @This(), name: []const u8, opts: ThisModule.LogOptions) !Client.ApiResult(Client.RawResponse) {
            const path = try self.pathBuilder().logPath(name, opts);
            defer self.client.allocator.free(path);
            return self.client.getRaw(path, self.ctx);
        }

        // Pagination helpers
        /// Configuration for paginated collection.
        pub const PagerOptions = struct {
            /// Number of items to request per page.
            page_size: i64 = 500,
        };

        /// Result of collecting all pages of a list operation.
        /// All items and strings are owned by an internal arena allocator.
        pub const CollectedList = struct {
            /// All collected items, deep-cloned and owned by the internal arena.
            items: []const T,
            /// The resourceVersion from the first page (consistent list snapshot version).
            resource_version: ?[]const u8,
            /// Arena that owns all item memory. Destroy via `deinit()`.
            arena: std.heap.ArenaAllocator,

            /// Free all collected items and their referenced memory.
            pub fn deinit(self: *CollectedList) void {
                self.arena.deinit();
            }
        };

        /// Collect all resources across all pages into a single owned slice.
        ///
        /// Transparently paginate using the given page size (default: 500).
        /// Each item is deep-cloned into an internal arena allocator, so the
        /// returned slice is fully owned and independent of any JSON parse arena.
        ///
        /// The caller owns the returned `CollectedList` and must call `deinit()`
        /// to free all cloned items and the items slice.
        ///
        /// Label/field selectors from `opts` are forwarded to every page request.
        /// The `limit` and `continue_token` fields in `opts` are ignored and
        /// overridden by the pager.
        pub fn collectAll(
            self: @This(),
            allocator: std.mem.Allocator,
            opts: ThisModule.ListOptions,
            pager_opts: PagerOptions,
        ) !CollectedList {
            return self.collectPages(allocator, opts, pager_opts, false);
        }

        /// Like `collectAll`, but lists across all namespaces.
        /// Only available for namespaced resources.
        pub fn collectAllAcrossNamespaces(
            self: @This(),
            allocator: std.mem.Allocator,
            opts: ThisModule.ListOptions,
            pager_opts: PagerOptions,
        ) !CollectedList {
            if (!meta.namespaced) @compileError("collectAllAcrossNamespaces is only available for namespaced resources; use collectAll() instead");
            return self.collectPages(allocator, opts, pager_opts, true);
        }

        fn collectPages(
            self: @This(),
            allocator: std.mem.Allocator,
            opts: ThisModule.ListOptions,
            pager_opts: PagerOptions,
            comptime use_list_all: bool,
        ) !CollectedList {
            var arena = std.heap.ArenaAllocator.init(allocator);
            errdefer arena.deinit();
            const arena_alloc = arena.allocator();

            var collected: std.ArrayListUnmanaged(T) = .empty;
            var resource_version: ?[]const u8 = null;
            var is_first_page = true;

            var page_opts = opts;
            page_opts.limit = pager_opts.page_size;
            page_opts.continue_token = null;

            while (true) {
                const api_result = if (use_list_all)
                    try self.listAll(page_opts)
                else
                    try self.list(page_opts);
                const parsed = try api_result.value();
                defer parsed.deinit();

                // Save resource version from the first page.
                if (is_first_page) {
                    if (parsed.value.metadata) |m| {
                        if (m.resourceVersion) |rv| {
                            resource_version = try arena_alloc.dupe(u8, rv);
                        }
                    }
                    is_first_page = false;
                }

                // Deep-clone each item into the arena.
                for (parsed.value.items) |item| {
                    try collected.append(arena_alloc, try deepClone(T, arena_alloc, item));
                }

                // Extract continue token before the parsed response is freed by defer.
                // Kubernetes returns continue:"" when there are no more pages,
                // so treat empty strings as null.
                const next_continue: ?[]const u8 = blk: {
                    const m = parsed.value.metadata orelse break :blk null;
                    const c = m.@"continue" orelse break :blk null;
                    break :blk if (c.len > 0) try arena_alloc.dupe(u8, c) else null;
                };

                page_opts.continue_token = next_continue;
                if (next_continue == null) break;
            }

            return .{
                .items = collected.items,
                .resource_version = resource_version,
                .arena = arena,
            };
        }
    };
}

const MockNamespacedResource = struct {
    apiVersion: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    pub const resource_meta = .{
        .group = "",
        .version = "v1",
        .kind = "Pod",
        .resource = "pods",
        .namespaced = true,
        .list_kind = MockNamespacedResourceList,
    };
};
const MockNamespacedResourceList = struct {};

const MockClusterResource = struct {
    apiVersion: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    pub const resource_meta = .{
        .group = "",
        .version = "v1",
        .kind = "Node",
        .resource = "nodes",
        .namespaced = false,
        .list_kind = MockClusterResourceList,
    };
};
const MockClusterResourceList = struct {};

const MockNamedGroupResource = struct {
    apiVersion: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    pub const resource_meta = .{
        .group = "apps",
        .version = "v1",
        .kind = "Deployment",
        .resource = "deployments",
        .namespaced = true,
        .list_kind = MockNamedGroupResourceList,
    };
};
const MockNamedGroupResourceList = struct {};

test "Api comptime instantiation" {
    // Act / Assert
    comptime {
        _ = Api(MockNamespacedResource);
        _ = Api(MockClusterResource);
        _ = Api(MockNamedGroupResource);
    }
}

test "init: namespaced resource requires []const u8 namespace parameter" {
    // Act / Assert
    comptime {
        const ApiType = Api(MockNamespacedResource);
        const info = @typeInfo(@TypeOf(ApiType.init));
        // params: [0]=self/client, [1]=ctx, [2]=namespace
        if (info.@"fn".params[2].type.? != []const u8)
            @compileError("expected non-optional namespace param for namespaced resource");
    }
}

test "init: cluster-scoped resource accepts ?[]const u8 namespace parameter" {
    // Act / Assert
    comptime {
        const ApiType = Api(MockClusterResource);
        const info = @typeInfo(@TypeOf(ApiType.init));
        // params: [0]=self/client, [1]=ctx, [2]=namespace
        if (info.@"fn".params[2].type.? != ?[]const u8)
            @compileError("expected optional namespace param for cluster-scoped resource");
    }
}

test "Api comptime instantiation includes patch" {
    // Act / Assert
    comptime {
        const PodApi = Api(MockNamespacedResource);
        _ = &PodApi.patch;
        _ = PatchType;
        _ = PatchOptions;
    }
}

// Subresource comptime instantiation
const MockScaleType = struct { replicas: ?i32 = null };
const MockEvictionType = struct { name: ?[]const u8 = null };

test "Api comptime instantiation includes subresource methods" {
    // Arrange
    comptime {
        const PodApi = Api(MockNamespacedResource);
        _ = &PodApi.getStatus;
        _ = &PodApi.updateStatus;
        _ = &PodApi.patchStatus;
        _ = &PodApi.getLogs;
        _ = LogOptions;

        // Act / Assert
        const DeployApi = Api(MockNamedGroupResource);
        _ = &DeployApi.getStatus;
        _ = &DeployApi.updateStatus;
        _ = &DeployApi.patchStatus;
    }
}

test "Api comptime instantiation: getScale/updateScale/patchScale/evict with type params" {
    // Arrange
    comptime {
        const PodApi = Api(MockNamespacedResource);
        _ = @TypeOf(PodApi.evict);

        // Act / Assert
        const DeployApi = Api(MockNamedGroupResource);
        _ = @TypeOf(DeployApi.getScale);
        _ = @TypeOf(DeployApi.updateScale);
        _ = @TypeOf(DeployApi.patchScale);
    }
}

test "Api comptime instantiation: listAll available for namespaced" {
    // Act / Assert
    comptime {
        const PodApi = Api(MockNamespacedResource);
        _ = &PodApi.listAll;
    }
}

// Pagination tests
test "PagerOptions: default page_size is 500" {
    // Act
    const opts = Api(MockNamespacedResource).PagerOptions{};

    // Assert
    try testing.expectEqual(@as(i64, 500), opts.page_size);
}

test "CollectedList: deinit on empty list does not panic" {
    // Arrange
    var collected = Api(MockNamespacedResource).CollectedList{
        .items = &.{},
        .resource_version = null,
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
    };

    // Act / Assert
    collected.deinit();
}

test "Api comptime instantiation includes collectAll and pagination types" {
    // Arrange
    comptime {
        const PodApi = Api(MockNamespacedResource);
        if (!@hasDecl(PodApi, "collectAll")) @compileError("missing collectAll");
        if (!@hasDecl(PodApi, "collectAllAcrossNamespaces")) @compileError("missing collectAllAcrossNamespaces");
        if (!@hasDecl(PodApi, "PagerOptions")) @compileError("missing PagerOptions");
        if (!@hasDecl(PodApi, "CollectedList")) @compileError("missing CollectedList");

        // Act / Assert
        const NodeApi = Api(MockClusterResource);
        if (!@hasDecl(NodeApi, "collectAll")) @compileError("missing collectAll for cluster-scoped");
        // collectAllAcrossNamespaces exists as a declaration but would @compileError if referenced
        // for non-namespaced resources, matching the listAll pattern.
        if (!@hasDecl(NodeApi, "collectAllAcrossNamespaces"))
            @compileError("missing collectAllAcrossNamespaces declaration for cluster-scoped");
    }
}
