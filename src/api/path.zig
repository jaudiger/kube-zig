//! URL path construction for Kubernetes API requests.
//!
//! `PathBuilder` is the shared implementation used by both `Api(T)` (comptime
//! resource metadata) and `DynamicApi` (runtime resource metadata) to build
//! correctly-formatted Kubernetes REST paths. All returned paths are
//! heap-allocated and must be freed by the caller.

const std = @import("std");
const options_mod = @import("options.zig");
const query = @import("query.zig");
const testing = std.testing;

const ListOptions = options_mod.ListOptions;
const WatchOptions = options_mod.WatchOptions;
const WriteOptions = options_mod.WriteOptions;
const PatchOptions = options_mod.PatchOptions;
const LogOptions = options_mod.LogOptions;

/// Constructs Kubernetes API URL paths from resource metadata.
///
/// Handles the differences between core-group resources (`/api/v1/...`) and
/// named-group resources (`/apis/apps/v1/...`), as well as namespaced vs
/// cluster-scoped resources.
pub const PathBuilder = struct {
    allocator: std.mem.Allocator,
    group: []const u8,
    version: []const u8,
    resource: []const u8,
    namespaced: bool,
    namespace: ?[]const u8,

    /// Return the namespace, or error if the resource is namespaced but
    /// no valid namespace was provided.
    fn resolveNamespace(self: PathBuilder) ![]const u8 {
        const ns = self.namespace orelse return error.NamespaceRequired;
        if (ns.len == 0) return error.NamespaceRequired;
        query.validateName(ns) catch return error.InvalidNamespace;
        return ns;
    }

    /// Append the API group+version prefix: `/api/{version}` or `/apis/{group}/{version}`.
    fn appendGroupVersionPrefix(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, group: []const u8, version: []const u8) !void {
        if (group.len == 0) {
            try buf.appendSlice(alloc, "/api/");
        } else {
            try buf.appendSlice(alloc, "/apis/");
            try buf.appendSlice(alloc, group);
            try buf.append(alloc, '/');
        }
        try buf.appendSlice(alloc, version);
    }

    // Buffer-based path helpers
    /// Append the collection path segments (group/version prefix + optional
    /// namespace + resource) to `buf`.
    fn appendCollectionTo(self: PathBuilder, buf: *std.ArrayList(u8), alloc: std.mem.Allocator) !void {
        try appendGroupVersionPrefix(buf, alloc, self.group, self.version);
        if (self.namespaced) {
            const ns = try self.resolveNamespace();
            try buf.appendSlice(alloc, "/namespaces/");
            try buf.appendSlice(alloc, ns);
        }
        try buf.append(alloc, '/');
        try buf.appendSlice(alloc, self.resource);
    }

    /// Append the collection path plus `/{name}` to `buf`. Validates `name`.
    fn appendResourceTo(self: PathBuilder, buf: *std.ArrayList(u8), alloc: std.mem.Allocator, name: []const u8) !void {
        try query.validateName(name);
        try self.appendCollectionTo(buf, alloc);
        try buf.append(alloc, '/');
        try buf.appendSlice(alloc, name);
    }

    /// Append the cross-namespace base path (group/version prefix + resource,
    /// no namespace segment) to `buf`.
    fn appendListAllBaseTo(self: PathBuilder, buf: *std.ArrayList(u8), alloc: std.mem.Allocator) !void {
        try appendGroupVersionPrefix(buf, alloc, self.group, self.version);
        try buf.append(alloc, '/');
        try buf.appendSlice(alloc, self.resource);
    }

    /// Append the resource path plus `/{subresource}` to `buf`.
    fn appendSubresourceTo(self: PathBuilder, buf: *std.ArrayList(u8), alloc: std.mem.Allocator, name: []const u8, subresource: []const u8) !void {
        try self.appendResourceTo(buf, alloc, name);
        try buf.append(alloc, '/');
        try buf.appendSlice(alloc, subresource);
    }

    // Public path methods
    /// Build the collection path for this resource type.
    ///
    /// Returns a path like `/api/v1/namespaces/default/pods` (namespaced)
    /// or `/api/v1/nodes` (cluster-scoped). The caller owns the returned
    /// slice and must free it with the same allocator.
    pub fn collectionPath(self: PathBuilder) ![]const u8 {
        const alloc = self.allocator;
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(alloc);
        try self.appendCollectionTo(&buf, alloc);
        return buf.toOwnedSlice(alloc);
    }

    /// Build the path for a single named resource.
    ///
    /// Returns a path like `/api/v1/namespaces/default/pods/my-pod`.
    /// Validates that `name` is non-empty and contains no slashes.
    /// The caller owns the returned slice.
    pub fn resourcePath(self: PathBuilder, name: []const u8) ![]const u8 {
        const alloc = self.allocator;
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(alloc);
        try self.appendResourceTo(&buf, alloc, name);
        return buf.toOwnedSlice(alloc);
    }

    /// Build the path for a subresource of a named resource.
    ///
    /// Returns a path like `/api/v1/namespaces/default/pods/my-pod/status`.
    /// The caller owns the returned slice.
    pub fn subresourcePath(self: PathBuilder, name: []const u8, subresource: []const u8) ![]const u8 {
        const alloc = self.allocator;
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(alloc);
        try self.appendSubresourceTo(&buf, alloc, name, subresource);
        return buf.toOwnedSlice(alloc);
    }

    /// Build the cross-namespace base path (no namespace segment).
    ///
    /// Returns a path like `/api/v1/pods` or `/apis/apps/v1/deployments`,
    /// used as the base for cluster-wide list and watch operations.
    /// The caller owns the returned slice.
    pub fn listAllBasePath(self: PathBuilder) ![]const u8 {
        const alloc = self.allocator;
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(alloc);
        try self.appendListAllBaseTo(&buf, alloc);
        return buf.toOwnedSlice(alloc);
    }

    /// Build the namespaced list path with query parameters from `opts`.
    ///
    /// Appends label/field selectors, pagination, resource version, and
    /// timeout as query parameters. The caller owns the returned slice.
    pub fn listPath(self: PathBuilder, opts: ListOptions) ![]const u8 {
        const alloc = self.allocator;
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(alloc);
        try self.appendCollectionTo(&buf, alloc);
        try query.appendListQueryTo(&buf, alloc, opts);
        return buf.toOwnedSlice(alloc);
    }

    /// Build the cross-namespace list path with query parameters from `opts`.
    ///
    /// Like `listPath` but omits the namespace segment, listing resources
    /// across all namespaces. The caller owns the returned slice.
    pub fn listAllPath(self: PathBuilder, opts: ListOptions) ![]const u8 {
        const alloc = self.allocator;
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(alloc);
        try self.appendListAllBaseTo(&buf, alloc);
        try query.appendListQueryTo(&buf, alloc, opts);
        return buf.toOwnedSlice(alloc);
    }

    /// Build the namespaced watch path with `?watch=true` and query parameters.
    ///
    /// Appends bookmarks, selectors, resource version, and timeout as
    /// query parameters. The caller owns the returned slice.
    pub fn watchPath(self: PathBuilder, opts: WatchOptions) ![]const u8 {
        const alloc = self.allocator;
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(alloc);
        try self.appendCollectionTo(&buf, alloc);
        try query.appendWatchQueryTo(&buf, alloc, opts);
        return buf.toOwnedSlice(alloc);
    }

    /// Build the cross-namespace watch path with `?watch=true` and query parameters.
    ///
    /// Like `watchPath` but omits the namespace segment, watching resources
    /// across all namespaces. The caller owns the returned slice.
    pub fn watchAllPath(self: PathBuilder, opts: WatchOptions) ![]const u8 {
        const alloc = self.allocator;
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(alloc);
        try self.appendListAllBaseTo(&buf, alloc);
        try query.appendWatchQueryTo(&buf, alloc, opts);
        return buf.toOwnedSlice(alloc);
    }

    /// Build the path for a create (POST) request.
    ///
    /// Returns the collection path with optional `dryRun` and `fieldManager`
    /// query parameters. The caller owns the returned slice.
    pub fn createPath(self: PathBuilder, opts: WriteOptions) ![]const u8 {
        const alloc = self.allocator;
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(alloc);
        try self.appendCollectionTo(&buf, alloc);
        try query.appendDryRunFieldManagerTo(&buf, alloc, opts.dry_run, opts.field_manager);
        return buf.toOwnedSlice(alloc);
    }

    /// Build the path for an update (PUT) request on a named resource.
    ///
    /// Returns the resource path with optional `dryRun` and `fieldManager`
    /// query parameters. The caller owns the returned slice.
    pub fn updatePath(self: PathBuilder, name: []const u8, opts: WriteOptions) ![]const u8 {
        const alloc = self.allocator;
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(alloc);
        try self.appendResourceTo(&buf, alloc, name);
        try query.appendDryRunFieldManagerTo(&buf, alloc, opts.dry_run, opts.field_manager);
        return buf.toOwnedSlice(alloc);
    }

    /// Build the path for a patch request on a named resource.
    ///
    /// Returns the resource path with optional `fieldManager` and `force`
    /// query parameters. The caller owns the returned slice.
    pub fn patchPath(self: PathBuilder, name: []const u8, opts: PatchOptions) ![]const u8 {
        const alloc = self.allocator;
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(alloc);
        try self.appendResourceTo(&buf, alloc, name);
        try query.appendPatchQueryTo(&buf, alloc, opts);
        return buf.toOwnedSlice(alloc);
    }

    /// Build the path for a patch request on a subresource (e.g. `/status`, `/scale`).
    ///
    /// Returns the subresource path with optional `fieldManager` and `force`
    /// query parameters. The caller owns the returned slice.
    pub fn subresourcePatchPath(self: PathBuilder, name: []const u8, subresource: []const u8, opts: PatchOptions) ![]const u8 {
        const alloc = self.allocator;
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(alloc);
        try self.appendSubresourceTo(&buf, alloc, name, subresource);
        try query.appendPatchQueryTo(&buf, alloc, opts);
        return buf.toOwnedSlice(alloc);
    }

    /// Build the path for a pod log request (`/log` subresource).
    ///
    /// Appends log-specific query parameters when set. The caller owns the
    /// returned slice.
    pub fn logPath(self: PathBuilder, name: []const u8, opts: LogOptions) ![]const u8 {
        const alloc = self.allocator;
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(alloc);
        try self.appendSubresourceTo(&buf, alloc, name, "log");
        try query.appendLogQueryTo(&buf, alloc, opts);
        return buf.toOwnedSlice(alloc);
    }
};

fn namespacedCorePB() PathBuilder {
    return .{
        .allocator = testing.allocator,
        .group = "",
        .version = "v1",
        .resource = "pods",
        .namespaced = true,
        .namespace = "default",
    };
}

fn clusterCorePB() PathBuilder {
    return .{
        .allocator = testing.allocator,
        .group = "",
        .version = "v1",
        .resource = "nodes",
        .namespaced = false,
        .namespace = null,
    };
}

fn namespacedNamedGroupPB() PathBuilder {
    return .{
        .allocator = testing.allocator,
        .group = "apps",
        .version = "v1",
        .resource = "deployments",
        .namespaced = true,
        .namespace = "kube-system",
    };
}

fn customCrdPB() PathBuilder {
    return .{
        .allocator = testing.allocator,
        .group = "stable.example.com",
        .version = "v1",
        .resource = "crontabs",
        .namespaced = true,
        .namespace = "default",
    };
}

fn clusterNamedGroupPB() PathBuilder {
    return .{
        .allocator = testing.allocator,
        .group = "rbac.authorization.k8s.io",
        .version = "v1",
        .resource = "clusterroles",
        .namespaced = false,
        .namespace = null,
    };
}

// collectionPath tests
test "collectionPath: namespaced core resource" {
    // Arrange
    const pb = namespacedCorePB();

    // Act
    const result = try pb.collectionPath();
    defer testing.allocator.free(result);

    // Assert
    try testing.expectEqualStrings("/api/v1/namespaces/default/pods", result);
}

test "collectionPath: cluster-scoped core resource" {
    // Arrange
    const pb = clusterCorePB();

    // Act
    const result = try pb.collectionPath();
    defer testing.allocator.free(result);

    // Assert
    try testing.expectEqualStrings("/api/v1/nodes", result);
}

test "collectionPath: namespaced named group resource" {
    // Arrange
    const pb = namespacedNamedGroupPB();

    // Act
    const result = try pb.collectionPath();
    defer testing.allocator.free(result);

    // Assert
    try testing.expectEqualStrings("/apis/apps/v1/namespaces/kube-system/deployments", result);
}

test "collectionPath: cluster-scoped named group resource" {
    // Arrange
    const pb = clusterNamedGroupPB();

    // Act
    const result = try pb.collectionPath();
    defer testing.allocator.free(result);

    // Assert
    try testing.expectEqualStrings("/apis/rbac.authorization.k8s.io/v1/clusterroles", result);
}

test "collectionPath: custom CRD group" {
    // Arrange
    const pb = customCrdPB();

    // Act
    const result = try pb.collectionPath();
    defer testing.allocator.free(result);

    // Assert
    try testing.expectEqualStrings("/apis/stable.example.com/v1/namespaces/default/crontabs", result);
}

test "collectionPath: namespaced without namespace returns error" {
    // Arrange
    var pb = namespacedCorePB();
    pb.namespace = null;

    // Act / Assert
    try testing.expectError(error.NamespaceRequired, pb.collectionPath());
}

// resourcePath tests
test "resourcePath: namespaced resource" {
    // Arrange
    var pb = namespacedCorePB();

    // Act
    const path = try pb.resourcePath("my-pod");
    defer testing.allocator.free(path);

    // Assert
    try testing.expectEqualStrings("/api/v1/namespaces/default/pods/my-pod", path);
}

test "resourcePath: cluster-scoped resource" {
    // Arrange
    const pb = clusterCorePB();

    // Act
    const path = try pb.resourcePath("node-1");
    defer testing.allocator.free(path);

    // Assert
    try testing.expectEqualStrings("/api/v1/nodes/node-1", path);
}

test "resourcePath: named group resource" {
    // Arrange
    var pb = namespacedNamedGroupPB();
    pb.namespace = "production";

    // Act
    const path = try pb.resourcePath("nginx");
    defer testing.allocator.free(path);

    // Assert
    try testing.expectEqualStrings("/apis/apps/v1/namespaces/production/deployments/nginx", path);
}

test "resourcePath: custom CRD group" {
    // Arrange
    const pb = customCrdPB();

    // Act
    const path = try pb.resourcePath("my-cron");
    defer testing.allocator.free(path);

    // Assert
    try testing.expectEqualStrings("/apis/stable.example.com/v1/namespaces/default/crontabs/my-cron", path);
}

test "resourcePath: empty name returns error" {
    // Arrange
    const pb = namespacedCorePB();

    // Act / Assert
    try testing.expectError(error.InvalidResourceName, pb.resourcePath(""));
}

test "resourcePath: name with slash returns error" {
    // Arrange
    const pb = namespacedCorePB();

    // Act / Assert
    try testing.expectError(error.InvalidResourceName, pb.resourcePath("foo/bar"));
}

// subresourcePath tests
test "subresourcePath: namespaced resource /status" {
    // Arrange
    const pb = namespacedCorePB();

    // Act
    const path = try pb.subresourcePath("my-pod", "status");
    defer testing.allocator.free(path);

    // Assert
    try testing.expectEqualStrings("/api/v1/namespaces/default/pods/my-pod/status", path);
}

test "subresourcePath: cluster-scoped resource /status" {
    // Arrange
    const pb = clusterCorePB();

    // Act
    const path = try pb.subresourcePath("node-1", "status");
    defer testing.allocator.free(path);

    // Assert
    try testing.expectEqualStrings("/api/v1/nodes/node-1/status", path);
}

test "subresourcePath: named group resource /scale" {
    // Arrange
    var pb = namespacedNamedGroupPB();
    pb.namespace = "production";

    // Act
    const path = try pb.subresourcePath("nginx", "scale");
    defer testing.allocator.free(path);

    // Assert
    try testing.expectEqualStrings("/apis/apps/v1/namespaces/production/deployments/nginx/scale", path);
}

test "subresourcePath: namespaced resource /eviction" {
    // Arrange
    const pb = namespacedCorePB();

    // Act
    const path = try pb.subresourcePath("my-pod", "eviction");
    defer testing.allocator.free(path);

    // Assert
    try testing.expectEqualStrings("/api/v1/namespaces/default/pods/my-pod/eviction", path);
}

// listAllBasePath tests
test "listAllBasePath: namespaced core resource" {
    // Arrange
    const pb = namespacedCorePB();

    // Act
    const path = try pb.listAllBasePath();
    defer testing.allocator.free(path);

    // Assert
    try testing.expectEqualStrings("/api/v1/pods", path);
}

test "listAllBasePath: named group resource" {
    // Arrange
    const pb = namespacedNamedGroupPB();

    // Act
    const path = try pb.listAllBasePath();
    defer testing.allocator.free(path);

    // Assert
    try testing.expectEqualStrings("/apis/apps/v1/deployments", path);
}

// listPath tests
test "listPath: no options" {
    // Arrange
    const pb = namespacedCorePB();

    // Act
    const path = try pb.listPath(.{});
    defer testing.allocator.free(path);

    // Assert
    try testing.expectEqualStrings("/api/v1/namespaces/default/pods", path);
}

test "listPath: label selector" {
    // Arrange
    const pb = namespacedCorePB();

    // Act
    const path = try pb.listPath(.{ .label_selector = "app=nginx" });
    defer testing.allocator.free(path);

    // Assert
    try testing.expectEqualStrings("/api/v1/namespaces/default/pods?labelSelector=app%3Dnginx", path);
}

test "listPath: both selectors" {
    // Arrange
    const pb = namespacedCorePB();

    // Act
    const path = try pb.listPath(.{ .label_selector = "app=nginx", .field_selector = "status.phase=Running" });
    defer testing.allocator.free(path);

    // Assert
    try testing.expectEqualStrings("/api/v1/namespaces/default/pods?labelSelector=app%3Dnginx&fieldSelector=status.phase%3DRunning", path);
}

test "listPath: timeout_seconds" {
    // Arrange
    const pb = namespacedCorePB();

    // Act
    const path = try pb.listPath(.{ .timeout_seconds = 30 });
    defer testing.allocator.free(path);

    // Assert
    try testing.expectEqualStrings("/api/v1/namespaces/default/pods?timeoutSeconds=30", path);
}

test "listPath: resourceVersion" {
    // Arrange
    const pb = namespacedCorePB();

    // Act
    const path = try pb.listPath(.{ .resource_version = "12345" });
    defer testing.allocator.free(path);

    // Assert
    try testing.expectEqualStrings("/api/v1/namespaces/default/pods?resourceVersion=12345", path);
}

test "listPath: resourceVersion with resourceVersionMatch" {
    // Arrange
    const pb = namespacedCorePB();

    // Act
    const path = try pb.listPath(.{ .resource_version = "12345", .resource_version_match = .exact });
    defer testing.allocator.free(path);

    // Assert
    try testing.expectEqualStrings("/api/v1/namespaces/default/pods?resourceVersion=12345&resourceVersionMatch=Exact", path);
}

test "listPath: resourceVersionMatch not_older_than" {
    // Arrange
    const pb = namespacedCorePB();

    // Act
    const path = try pb.listPath(.{ .resource_version = "100", .resource_version_match = .not_older_than });
    defer testing.allocator.free(path);

    // Assert
    try testing.expectEqualStrings("/api/v1/namespaces/default/pods?resourceVersion=100&resourceVersionMatch=NotOlderThan", path);
}

test "listPath: limit" {
    // Arrange
    const pb = namespacedCorePB();

    // Act
    const path = try pb.listPath(.{ .limit = 100 });
    defer testing.allocator.free(path);

    // Assert
    try testing.expectEqualStrings("/api/v1/namespaces/default/pods?limit=100", path);
}

test "listPath: continue token" {
    // Arrange
    const pb = namespacedCorePB();

    // Act
    const path = try pb.listPath(.{ .continue_token = "abc123" });
    defer testing.allocator.free(path);

    // Assert
    try testing.expectEqualStrings("/api/v1/namespaces/default/pods?continue=abc123", path);
}

test "listPath: pagination with limit and continue" {
    // Arrange
    const pb = namespacedCorePB();

    // Act
    const path = try pb.listPath(.{ .limit = 50, .continue_token = "eyJ2Ijoib" });
    defer testing.allocator.free(path);

    // Assert
    try testing.expectEqualStrings("/api/v1/namespaces/default/pods?limit=50&continue=eyJ2Ijoib", path);
}

test "listPath: all options combined" {
    // Arrange
    const pb = namespacedCorePB();

    // Act
    const path = try pb.listPath(.{
        .label_selector = "app=nginx",
        .field_selector = "status.phase=Running",
        .resource_version = "999",
        .resource_version_match = .not_older_than,
        .limit = 10,
        .timeout_seconds = 60,
    });
    defer testing.allocator.free(path);

    // Assert
    try testing.expectEqualStrings(
        "/api/v1/namespaces/default/pods?labelSelector=app%3Dnginx&fieldSelector=status.phase%3DRunning&resourceVersion=999&resourceVersionMatch=NotOlderThan&limit=10&timeoutSeconds=60",
        path,
    );
}

test "listPath: cluster-scoped with pagination" {
    // Arrange
    const pb = clusterCorePB();

    // Act
    const path = try pb.listPath(.{ .limit = 25, .timeout_seconds = 120 });
    defer testing.allocator.free(path);

    // Assert
    try testing.expectEqualStrings("/api/v1/nodes?limit=25&timeoutSeconds=120", path);
}

// createPath tests
test "createPath: no options" {
    // Arrange
    const pb = namespacedCorePB();

    // Act
    const path = try pb.createPath(.{});
    defer testing.allocator.free(path);

    // Assert
    try testing.expectEqualStrings("/api/v1/namespaces/default/pods", path);
}

test "createPath: dry run" {
    // Arrange
    const pb = namespacedCorePB();

    // Act
    const path = try pb.createPath(.{ .dry_run = true });
    defer testing.allocator.free(path);

    // Assert
    try testing.expectEqualStrings("/api/v1/namespaces/default/pods?dryRun=All", path);
}

test "createPath: field manager" {
    // Arrange
    const pb = namespacedCorePB();

    // Act
    const path = try pb.createPath(.{ .field_manager = "my-controller" });
    defer testing.allocator.free(path);

    // Assert
    try testing.expectEqualStrings("/api/v1/namespaces/default/pods?fieldManager=my-controller", path);
}

test "createPath: both dry_run and field_manager" {
    // Arrange
    const pb = namespacedCorePB();

    // Act
    const path = try pb.createPath(.{ .dry_run = true, .field_manager = "ctl" });
    defer testing.allocator.free(path);

    // Assert
    try testing.expectEqualStrings("/api/v1/namespaces/default/pods?dryRun=All&fieldManager=ctl", path);
}

// updatePath tests
test "updatePath: no options" {
    // Arrange
    const pb = namespacedCorePB();

    // Act
    const path = try pb.updatePath("my-pod", .{});
    defer testing.allocator.free(path);

    // Assert
    try testing.expectEqualStrings("/api/v1/namespaces/default/pods/my-pod", path);
}

test "updatePath: dry run" {
    // Arrange
    const pb = namespacedCorePB();

    // Act
    const path = try pb.updatePath("my-pod", .{ .dry_run = true });
    defer testing.allocator.free(path);

    // Assert
    try testing.expectEqualStrings("/api/v1/namespaces/default/pods/my-pod?dryRun=All", path);
}

test "updatePath: field manager" {
    // Arrange
    const pb = namespacedCorePB();

    // Act
    const path = try pb.updatePath("my-pod", .{ .field_manager = "my-controller" });
    defer testing.allocator.free(path);

    // Assert
    try testing.expectEqualStrings("/api/v1/namespaces/default/pods/my-pod?fieldManager=my-controller", path);
}

test "updatePath: both dry_run and field_manager" {
    // Arrange
    const pb = namespacedCorePB();

    // Act
    const path = try pb.updatePath("my-pod", .{ .dry_run = true, .field_manager = "ctl" });
    defer testing.allocator.free(path);

    // Assert
    try testing.expectEqualStrings("/api/v1/namespaces/default/pods/my-pod?dryRun=All&fieldManager=ctl", path);
}

// patchPath tests
test "patchPath: no query params" {
    // Arrange
    const pb = namespacedCorePB();

    // Act
    const path = try pb.patchPath("my-pod", .{});
    defer testing.allocator.free(path);

    // Assert
    try testing.expectEqualStrings("/api/v1/namespaces/default/pods/my-pod", path);
}

test "patchPath: fieldManager only" {
    // Arrange
    const pb = namespacedCorePB();

    // Act
    const path = try pb.patchPath("my-pod", .{ .field_manager = "my-controller" });
    defer testing.allocator.free(path);

    // Assert
    try testing.expectEqualStrings("/api/v1/namespaces/default/pods/my-pod?fieldManager=my-controller", path);
}

test "patchPath: force only" {
    // Arrange
    const pb = namespacedCorePB();

    // Act
    const path = try pb.patchPath("my-pod", .{ .force = true });
    defer testing.allocator.free(path);

    // Assert
    try testing.expectEqualStrings("/api/v1/namespaces/default/pods/my-pod?force=true", path);
}

test "patchPath: force=false does not append query param" {
    // Arrange
    const pb = namespacedCorePB();

    // Act
    const path = try pb.patchPath("my-pod", .{ .force = false });
    defer testing.allocator.free(path);

    // Assert
    try testing.expectEqualStrings("/api/v1/namespaces/default/pods/my-pod", path);
}

test "patchPath: both fieldManager and force" {
    // Arrange
    const pb = namespacedCorePB();

    // Act
    const path = try pb.patchPath("my-pod", .{ .field_manager = "my-controller", .force = true });
    defer testing.allocator.free(path);

    // Assert
    try testing.expectEqualStrings("/api/v1/namespaces/default/pods/my-pod?fieldManager=my-controller&force=true", path);
}

test "patchPath: fieldManager with special characters is percent-encoded" {
    // Arrange
    const pb = namespacedCorePB();

    // Act
    const path = try pb.patchPath("my-pod", .{ .field_manager = "my controller&v=2" });
    defer testing.allocator.free(path);

    // Assert
    try testing.expectEqualStrings("/api/v1/namespaces/default/pods/my-pod?fieldManager=my%20controller%26v%3D2", path);
}

test "patchPath: cluster-scoped resource" {
    // Arrange
    const pb = clusterCorePB();

    // Act
    const path = try pb.patchPath("node-1", .{ .field_manager = "ctl" });
    defer testing.allocator.free(path);

    // Assert
    try testing.expectEqualStrings("/api/v1/nodes/node-1?fieldManager=ctl", path);
}

test "patchPath: named group resource" {
    // Arrange
    var pb = namespacedNamedGroupPB();
    pb.namespace = "production";

    // Act
    const path = try pb.patchPath("nginx", .{ .patch_type = .apply, .field_manager = "ctl", .force = true });
    defer testing.allocator.free(path);

    // Assert
    try testing.expectEqualStrings("/apis/apps/v1/namespaces/production/deployments/nginx?fieldManager=ctl&force=true", path);
}

// subresourcePatchPath tests
test "subresourcePatchPath: no query params" {
    // Arrange
    const pb = namespacedCorePB();

    // Act
    const path = try pb.subresourcePatchPath("my-pod", "status", .{});
    defer testing.allocator.free(path);

    // Assert
    try testing.expectEqualStrings("/api/v1/namespaces/default/pods/my-pod/status", path);
}

test "subresourcePatchPath: with fieldManager and force" {
    // Arrange
    var pb = namespacedNamedGroupPB();
    pb.namespace = "production";

    // Act
    const path = try pb.subresourcePatchPath("nginx", "scale", .{ .field_manager = "ctl", .force = true });
    defer testing.allocator.free(path);

    // Assert
    try testing.expectEqualStrings("/apis/apps/v1/namespaces/production/deployments/nginx/scale?fieldManager=ctl&force=true", path);
}

// watchPath tests
test "watchPath: namespaced resource, no options" {
    // Arrange
    const pb = namespacedCorePB();

    // Act
    const path = try pb.watchPath(.{});
    defer testing.allocator.free(path);

    // Assert
    try testing.expectEqualStrings("/api/v1/namespaces/default/pods?watch=true&allowWatchBookmarks=true", path);
}

test "watchPath: with resource version" {
    // Arrange
    const pb = namespacedCorePB();

    // Act
    const path = try pb.watchPath(.{ .resource_version = "12345" });
    defer testing.allocator.free(path);

    // Assert
    try testing.expectEqualStrings("/api/v1/namespaces/default/pods?watch=true&allowWatchBookmarks=true&resourceVersion=12345", path);
}

test "watchPath: cluster-scoped resource" {
    // Arrange
    const pb = clusterCorePB();

    // Act
    const path = try pb.watchPath(.{});
    defer testing.allocator.free(path);

    // Assert
    try testing.expectEqualStrings("/api/v1/nodes?watch=true&allowWatchBookmarks=true", path);
}

test "watchPath: with label selector and timeout" {
    // Arrange
    const pb = namespacedCorePB();

    // Act
    const path = try pb.watchPath(.{ .label_selector = "app=nginx", .timeout_seconds = 300 });
    defer testing.allocator.free(path);

    // Assert
    try testing.expectEqualStrings("/api/v1/namespaces/default/pods?watch=true&allowWatchBookmarks=true&labelSelector=app%3Dnginx&timeoutSeconds=300", path);
}

test "watchPath: bookmarks disabled" {
    // Arrange
    const pb = namespacedCorePB();

    // Act
    const path = try pb.watchPath(.{ .allow_bookmarks = false });
    defer testing.allocator.free(path);

    // Assert
    try testing.expectEqualStrings("/api/v1/namespaces/default/pods?watch=true", path);
}

test "watchPath: named group resource" {
    // Arrange
    var pb = namespacedNamedGroupPB();
    pb.namespace = "production";

    // Act
    const path = try pb.watchPath(.{});
    defer testing.allocator.free(path);

    // Assert
    try testing.expectEqualStrings("/apis/apps/v1/namespaces/production/deployments?watch=true&allowWatchBookmarks=true", path);
}

test "watchPath: all options combined" {
    // Arrange
    const pb = namespacedCorePB();

    // Act
    const path = try pb.watchPath(.{
        .label_selector = "app=nginx",
        .field_selector = "status.phase=Running",
        .resource_version = "999",
        .timeout_seconds = 60,
        .allow_bookmarks = true,
    });
    defer testing.allocator.free(path);

    // Assert
    try testing.expectEqualStrings(
        "/api/v1/namespaces/default/pods?watch=true&allowWatchBookmarks=true&labelSelector=app%3Dnginx&fieldSelector=status.phase%3DRunning&resourceVersion=999&timeoutSeconds=60",
        path,
    );
}

// watchAllPath tests
test "watchAllPath: cross-namespace" {
    // Arrange
    const pb = namespacedCorePB();

    // Act
    const path = try pb.watchAllPath(.{});
    defer testing.allocator.free(path);

    // Assert
    try testing.expectEqualStrings("/api/v1/pods?watch=true&allowWatchBookmarks=true", path);
}

test "watchAllPath: with field selector" {
    // Arrange
    const pb = namespacedCorePB();

    // Act
    const path = try pb.watchAllPath(.{ .field_selector = "status.phase=Running" });
    defer testing.allocator.free(path);

    // Assert
    try testing.expectEqualStrings("/api/v1/pods?watch=true&allowWatchBookmarks=true&fieldSelector=status.phase%3DRunning", path);
}

// logPath tests
test "logPath: no options" {
    // Arrange
    const pb = namespacedCorePB();

    // Act
    const path = try pb.logPath("my-pod", .{});
    defer testing.allocator.free(path);

    // Assert
    try testing.expectEqualStrings("/api/v1/namespaces/default/pods/my-pod/log", path);
}

test "logPath: container only" {
    // Arrange
    const pb = namespacedCorePB();

    // Act
    const path = try pb.logPath("my-pod", .{ .container = "nginx" });
    defer testing.allocator.free(path);

    // Assert
    try testing.expectEqualStrings("/api/v1/namespaces/default/pods/my-pod/log?container=nginx", path);
}

test "logPath: multiple options" {
    // Arrange
    const pb = namespacedCorePB();

    // Act
    const path = try pb.logPath("my-pod", .{
        .container = "app",
        .tail_lines = 100,
        .timestamps = true,
        .previous = false,
    });
    defer testing.allocator.free(path);

    // Assert
    try testing.expectEqualStrings("/api/v1/namespaces/default/pods/my-pod/log?container=app&tailLines=100&timestamps=true&previous=false", path);
}

test "logPath: all options" {
    // Arrange
    const pb = namespacedCorePB();

    // Act
    const path = try pb.logPath("my-pod", .{
        .container = "sidecar",
        .follow = false,
        .tail_lines = 50,
        .since_seconds = 3600,
        .timestamps = true,
        .previous = true,
        .limit_bytes = 1048576,
    });
    defer testing.allocator.free(path);

    // Assert
    try testing.expectEqualStrings("/api/v1/namespaces/default/pods/my-pod/log?container=sidecar&follow=false&tailLines=50&sinceSeconds=3600&timestamps=true&previous=true&limitBytes=1048576", path);
}

// Namespace validation tests
test "collectionPath: namespace with slash returns InvalidNamespace" {
    // Arrange
    var pb = namespacedCorePB();
    pb.namespace = "evil/ns";

    // Act / Assert
    try testing.expectError(error.InvalidNamespace, pb.collectionPath());
}

test "collectionPath: namespace with path traversal returns InvalidNamespace" {
    // Arrange
    var pb = namespacedCorePB();
    pb.namespace = "../../../etc";

    // Act / Assert
    try testing.expectError(error.InvalidNamespace, pb.collectionPath());
}

test "resourcePath: namespace with slash returns InvalidNamespace" {
    // Arrange
    var pb = namespacedCorePB();
    pb.namespace = "ns/traversal";

    // Act / Assert
    try testing.expectError(error.InvalidNamespace, pb.resourcePath("my-pod"));
}

test "resourcePath: namespace with dot-dot-slash returns InvalidNamespace" {
    // Arrange
    var pb = namespacedCorePB();
    pb.namespace = "../secret";

    // Act / Assert
    try testing.expectError(error.InvalidNamespace, pb.resourcePath("my-pod"));
}
