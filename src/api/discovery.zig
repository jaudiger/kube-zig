//! Kubernetes API discovery client for querying server metadata.
//!
//! Provides `DiscoveryClient`, which wraps an HTTP client and exposes
//! methods for fetching available API groups, resources, and server
//! version. Convenience methods use a TTL-based cache to avoid
//! redundant HTTP requests to the API server.

const std = @import("std");
const client_mod = @import("../client/Client.zig");
const Client = client_mod.Client;
const Context = client_mod.Context;
const types = @import("types");
const logging_mod = @import("../util/logging.zig");
const LogField = logging_mod.Field;
const testing = std.testing;

/// Configuration options for the DiscoveryClient.
pub const DiscoveryOptions = struct {
    /// TTL for cached discovery responses in nanoseconds.
    /// Default: 10 minutes. Set to 0 to disable caching.
    cache_ttl_ns: u64 = 10 * 60 * std.time.ns_per_s,

    /// Maximum number of cached resource entries (group/version pairs).
    /// Limit memory growth in clusters with many CRDs. When the cache
    /// is full, expired entries are evicted first, then the oldest entry.
    /// Default: 100. Set to 0 for unlimited.
    max_resource_cache_entries: u32 = 100,
};

/// Client for Kubernetes API discovery operations.
///
/// Wrap a `Client` pointer and provide methods for querying API server
/// metadata: available groups, resources, and server version.
///
/// Convenience methods (`hasResource`, `hasGroup`, `findPreferredVersion`,
/// `resourceMeta`, `isResourceNamespaced`) use a TTL-based cache to avoid
/// redundant HTTP requests. Core query methods (`serverVersion`,
/// `coreAPIVersions`, `apiGroups`, `coreResources`, `groupResources`) always
/// make a fresh HTTP request.
///
/// Example:
/// ```zig
/// var discovery = kube_zig.DiscoveryClient.init(
///     allocator, &client, client.context(), .{},
/// );
/// defer discovery.deinit();
///
/// const has_crd = try discovery.hasResource("stable.example.com", "v1", "crontabs");
/// ```
pub const DiscoveryClient = struct {
    client: *Client,
    ctx: Context,
    allocator: std.mem.Allocator,
    options: DiscoveryOptions,
    mu: std.Io.Mutex,
    groups_cache: ?CachedGroups,
    resources_cache: std.StringArrayHashMapUnmanaged(CachedResources),

    const CachedGroups = struct {
        parsed: std.json.Parsed(types.MetaV1APIGroupList),
        fetched_at: std.Io.Clock.Timestamp,
    };

    const CachedResources = struct {
        parsed: std.json.Parsed(types.MetaV1APIResourceList),
        fetched_at: std.Io.Clock.Timestamp,
    };

    const EnsureResult = enum { cached, not_found };

    /// Create a new DiscoveryClient with the given allocator, HTTP client, and options.
    pub fn init(allocator: std.mem.Allocator, client: *Client, ctx: Context, options: DiscoveryOptions) DiscoveryClient {
        return .{
            .client = client,
            .ctx = ctx,
            .allocator = allocator,
            .options = options,
            .mu = .init,
            .groups_cache = null,
            .resources_cache = .empty,
        };
    }

    /// Release all cached data and associated memory.
    pub fn deinit(self: *DiscoveryClient, io: std.Io) void {
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        self.clearGroupsCacheLocked();
        self.clearAllResourcesCacheLocked();
    }

    // Core query methods
    /// Fetch the Kubernetes server version (GET /version).
    pub fn serverVersion(self: *DiscoveryClient) !Client.ApiResult(std.json.Parsed(types.PkgVersionInfo)) {
        self.client.logger.debug("fetching server version", &.{});
        return self.client.get(types.PkgVersionInfo, "/version", self.ctx);
    }

    /// Fetch the core API versions (GET /api).
    /// The core group always includes "v1".
    pub fn coreAPIVersions(self: *DiscoveryClient, io: std.Io) !Client.ApiResult(std.json.Parsed(types.MetaV1APIVersions)) {
        return self.client.get(io, types.MetaV1APIVersions, "/api", self.ctx);
    }

    /// Fetch all named API groups (GET /apis).
    /// Returns apps, batch, networking.k8s.io, etc.
    /// Does NOT include the core group; use `coreAPIVersions()` for that.
    pub fn apiGroups(self: *DiscoveryClient, io: std.Io) !Client.ApiResult(std.json.Parsed(types.MetaV1APIGroupList)) {
        self.client.logger.debug("fetching api groups", &.{});
        return self.client.get(io, types.MetaV1APIGroupList, "/apis", self.ctx);
    }

    /// Fetch all resources in the core API group v1 (GET /api/v1).
    /// Returns pods, services, nodes, configmaps, etc.
    pub fn coreResources(self: *DiscoveryClient, io: std.Io) !Client.ApiResult(std.json.Parsed(types.MetaV1APIResourceList)) {
        self.client.logger.debug("fetching core resources", &.{});
        return self.client.get(io, types.MetaV1APIResourceList, "/api/v1", self.ctx);
    }

    /// Fetch all resources for a named API group and version (GET /apis/{group}/{version}).
    /// Example: `groupResources("apps", "v1")` returns deployments, replicasets, statefulsets, etc.
    pub fn groupResources(self: *DiscoveryClient, io: std.Io, group: []const u8, version: []const u8) !Client.ApiResult(std.json.Parsed(types.MetaV1APIResourceList)) {
        self.client.logger.debug("fetching group resources", &.{
            LogField.string("group", group),
            LogField.string("version", version),
        });
        const path = try std.fmt.allocPrint(self.client.allocator, "/apis/{s}/{s}", .{ group, version });
        defer self.client.allocator.free(path);
        return self.client.get(io, types.MetaV1APIResourceList, path, self.ctx);
    }

    // Convenience methods
    /// Check if a specific resource type exists on this API server.
    ///
    /// `group` is the API group ("" for core, "apps", "batch", etc.).
    /// `version` is the API version ("v1", "v1beta1", etc.).
    /// `resource` is the plural resource name ("pods", "deployments", "crontabs").
    ///
    /// Return true if found, false if the group/version exists but the resource
    /// is not in it, or if the group/version itself does not exist (404).
    pub fn hasResource(self: *DiscoveryClient, io: std.Io, group: []const u8, version: []const u8, resource: []const u8) !bool {
        if (try self.ensureResourcesCached(io, group, version) == .not_found) return false;
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        return self.findResourceInCacheLocked(group, version, resource) != null;
    }

    /// Check if a specific API group exists on this server.
    /// Return true for "" (core group always exists).
    pub fn hasGroup(self: *DiscoveryClient, io: std.Io, group: []const u8) !bool {
        if (group.len == 0) return true;
        try self.ensureGroupsCached(io);
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        return self.findGroupInCacheLocked(group) != null;
    }

    /// Find the preferred (server-recommended) version string for a given API group.
    ///
    /// Return an owned copy of the version string (e.g. "v1"), allocated into
    /// `out_allocator`. The caller must free the returned slice.
    /// Return null if the group is not found.
    /// For "" (core group), always return "v1".
    pub fn findPreferredVersion(self: *DiscoveryClient, io: std.Io, out_allocator: std.mem.Allocator, group: []const u8) !?[]const u8 {
        if (group.len == 0) return try out_allocator.dupe(u8, "v1");
        try self.ensureGroupsCached(io);
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        const g = self.findGroupInCacheLocked(group) orelse return null;
        if (g.preferredVersion) |pv| {
            return try out_allocator.dupe(u8, pv.version);
        }
        if (g.versions.len > 0) {
            return try out_allocator.dupe(u8, g.versions[0].version);
        }
        return null;
    }

    /// Discover a resource and build a `ResourceMeta` for use with `DynamicApi`.
    ///
    /// Query the API server, find the resource, and return a `ResourceMeta`
    /// with the correct group, version, resource name, and namespaced flag.
    /// Return null if the resource is not found.
    ///
    /// The returned `ResourceMeta` contains the same `group`, `version`, and
    /// `resource` slices that were passed in (not copies from the parsed response),
    /// so their lifetime must outlive the `ResourceMeta`.
    pub fn resourceMeta(
        self: *DiscoveryClient,
        io: std.Io,
        group: []const u8,
        version: []const u8,
        resource: []const u8,
    ) !?@import("dynamic.zig").ResourceMeta {
        if (try self.ensureResourcesCached(io, group, version) == .not_found) return null;
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        const r = self.findResourceInCacheLocked(group, version, resource) orelse return null;
        return .{
            .group = group,
            .version = version,
            .resource = resource,
            .namespaced = r.namespaced,
        };
    }

    /// Check if a specific resource is namespaced.
    /// Return null if the resource is not found.
    pub fn isResourceNamespaced(self: *DiscoveryClient, io: std.Io, group: []const u8, version: []const u8, resource: []const u8) !?bool {
        if (try self.ensureResourcesCached(io, group, version) == .not_found) return null;
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        const r = self.findResourceInCacheLocked(group, version, resource) orelse return null;
        return r.namespaced;
    }

    // Cache invalidation
    /// Clear all cached discovery data, forcing re-fetches on next access.
    pub fn invalidateCache(self: *DiscoveryClient, io: std.Io) void {
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        self.clearGroupsCacheLocked();
        self.clearAllResourcesCacheLocked();
    }

    /// Clear cached API groups, forcing a re-fetch on next access.
    pub fn invalidateGroupsCache(self: *DiscoveryClient, io: std.Io) void {
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        self.clearGroupsCacheLocked();
    }

    /// Clear cached resources for a specific group/version.
    pub fn invalidateResourceCache(self: *DiscoveryClient, io: std.Io, group: []const u8, version: []const u8) void {
        const key = self.makeCacheKey(group, version) catch return;
        defer self.allocator.free(key);
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        self.removeResourceCacheEntryLocked(key);
    }

    // Private: cache population
    fn ensureGroupsCached(self: *DiscoveryClient, io: std.Io) !void {
        if (self.options.cache_ttl_ns == 0) {
            // Caching disabled: fetch, populate cache for current call, return.
            const result = try self.apiGroups(io);
            switch (result) {
                .ok => |parsed| {
                    self.mu.lockUncancelable(io);
                    defer self.mu.unlock(io);
                    self.clearGroupsCacheLocked();
                    self.groups_cache = .{
                        .parsed = parsed,
                        .fetched_at = .now(io, .awake),
                    };
                    return;
                },
                .api_error => |e| {
                    defer e.deinit();
                    return e.statusError();
                },
            }
        }

        // Check if cache is valid.
        {
            self.mu.lockUncancelable(io);
            defer self.mu.unlock(io);
            if (self.groups_cache) |cached| {
                if (isCacheValid(io, cached.fetched_at, self.options.cache_ttl_ns)) return;
            }
        }

        // Cache miss or expired: fetch without lock.
        const result = try self.apiGroups(io);
        switch (result) {
            .ok => |parsed| {
                self.mu.lockUncancelable(io);
                defer self.mu.unlock(io);
                self.clearGroupsCacheLocked();
                self.groups_cache = .{
                    .parsed = parsed,
                    .fetched_at = .now(io, .awake),
                };
            },
            .api_error => |e| {
                defer e.deinit();
                return e.statusError();
            },
        }
    }

    fn ensureResourcesCached(self: *DiscoveryClient, io: std.Io, group: []const u8, version: []const u8) !EnsureResult {
        const key = try self.makeCacheKey(group, version);
        defer self.allocator.free(key);

        if (self.options.cache_ttl_ns == 0) {
            // Caching disabled: fetch, populate, return.
            const result = try self.fetchResources(io, group, version);
            switch (result) {
                .ok => |parsed| {
                    self.mu.lockUncancelable(io);
                    defer self.mu.unlock(io);
                    self.removeResourceCacheEntryLocked(key);
                    self.evictIfNeededLocked(io);
                    const owned_key = self.allocator.dupe(u8, key) catch {
                        parsed.deinit();
                        return error.OutOfMemory;
                    };
                    self.resources_cache.put(self.allocator, owned_key, .{
                        .parsed = parsed,
                        .fetched_at = .now(io, .awake),
                    }) catch {
                        self.allocator.free(owned_key);
                        parsed.deinit();
                        return error.OutOfMemory;
                    };
                    return .cached;
                },
                .api_error => |e| {
                    defer e.deinit();
                    if (e.status == .not_found) return .not_found;
                    return e.statusError();
                },
            }
        }

        // Check if cache is valid.
        {
            self.mu.lockUncancelable(io);
            defer self.mu.unlock(io);
            if (self.resources_cache.get(key)) |cached| {
                if (isCacheValid(io, cached.fetched_at, self.options.cache_ttl_ns)) return .cached;
            }
        }

        // Cache miss or expired: fetch without lock.
        const result = try self.fetchResources(io, group, version);
        switch (result) {
            .ok => |parsed| {
                self.mu.lockUncancelable(io);
                defer self.mu.unlock(io);
                self.removeResourceCacheEntryLocked(key);
                self.evictIfNeededLocked(io);
                const owned_key = self.allocator.dupe(u8, key) catch {
                    parsed.deinit();
                    return error.OutOfMemory;
                };
                self.resources_cache.put(self.allocator, owned_key, .{
                    .parsed = parsed,
                    .fetched_at = .now(io, .awake),
                }) catch {
                    self.allocator.free(owned_key);
                    parsed.deinit();
                    return error.OutOfMemory;
                };
                return .cached;
            },
            .api_error => |e| {
                defer e.deinit();
                if (e.status == .not_found) return .not_found;
                return e.statusError();
            },
        }
    }

    // Private: cache lookup helpers
    fn findGroupInCacheLocked(self: *DiscoveryClient, group: []const u8) ?types.MetaV1APIGroup {
        const cached = self.groups_cache orelse return null;
        for (cached.parsed.value.groups) |g| {
            if (std.mem.eql(u8, g.name, group)) return g;
        }
        return null;
    }

    fn findResourceInCacheLocked(self: *DiscoveryClient, group: []const u8, version: []const u8, resource: []const u8) ?types.MetaV1APIResource {
        const key = self.makeCacheKey(group, version) catch return null;
        defer self.allocator.free(key);
        const cached = self.resources_cache.get(key) orelse return null;
        for (cached.parsed.value.resources) |r| {
            if (std.mem.eql(u8, r.name, resource)) return r;
        }
        return null;
    }

    // Private: cache management
    fn clearGroupsCacheLocked(self: *DiscoveryClient) void {
        if (self.groups_cache) |cached| {
            cached.parsed.deinit();
            self.groups_cache = null;
        }
    }

    fn clearAllResourcesCacheLocked(self: *DiscoveryClient) void {
        for (self.resources_cache.keys(), self.resources_cache.values()) |key, cached| {
            cached.parsed.deinit();
            self.allocator.free(key);
        }
        self.resources_cache.deinit(self.allocator);
        self.resources_cache = .empty;
    }

    fn removeResourceCacheEntryLocked(self: *DiscoveryClient, key: []const u8) void {
        if (self.resources_cache.fetchOrderedRemove(key)) |entry| {
            entry.value.parsed.deinit();
            self.allocator.free(entry.key);
        }
    }

    fn evictIfNeededLocked(self: *DiscoveryClient, io: std.Io) void {
        const max = self.options.max_resource_cache_entries;
        if (max == 0) return;
        if (self.resources_cache.count() < max) return;

        self.evictExpiredLocked(io);

        while (self.resources_cache.count() >= max) {
            const keys = self.resources_cache.keys();
            if (keys.len == 0) break;
            if (self.resources_cache.fetchOrderedRemove(keys[0])) |entry| {
                entry.value.parsed.deinit();
                self.allocator.free(entry.key);
            }
        }
    }

    fn evictExpiredLocked(self: *DiscoveryClient, io: std.Io) void {
        if (self.options.cache_ttl_ns == 0) return;

        var i: usize = self.resources_cache.count();
        while (i > 0) {
            i -= 1;
            if (!isCacheValid(io, self.resources_cache.values()[i].fetched_at, self.options.cache_ttl_ns)) {
                if (self.resources_cache.fetchOrderedRemove(self.resources_cache.keys()[i])) |entry| {
                    entry.value.parsed.deinit();
                    self.allocator.free(entry.key);
                }
            }
        }
    }

    fn makeCacheKey(self: *DiscoveryClient, group: []const u8, version: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "{s}\x00{s}", .{ group, version });
    }

    fn isCacheValid(io: std.Io, fetched_at: std.Io.Clock.Timestamp, ttl_ns: u64) bool {
        const elapsed_ns: i96 = fetched_at.untilNow(io).raw.nanoseconds;
        if (elapsed_ns < 0) return false;
        return @as(u64, @intCast(elapsed_ns)) < ttl_ns;
    }

    // Private: fetch helpers
    /// Fetch the resource list for the given group/version.
    /// Core group (empty string) uses `/api/v1`.
    /// Named groups use `/apis/{group}/{version}`.
    fn fetchResources(self: *DiscoveryClient, io: std.Io, group: []const u8, version: []const u8) !Client.ApiResult(std.json.Parsed(types.MetaV1APIResourceList)) {
        if (group.len == 0) {
            return self.coreResources(io);
        }
        return self.groupResources(io, group, version);
    }
};

// DiscoveryClient struct shape
test "DiscoveryClient: has expected declarations and fields" {
    // Act / Assert
    try testing.expect(@hasField(DiscoveryClient, "client"));
    try testing.expect(@hasField(DiscoveryClient, "allocator"));
    try testing.expect(@hasField(DiscoveryClient, "options"));
    try testing.expect(@hasField(DiscoveryClient, "mu"));
    try testing.expect(@hasField(DiscoveryClient, "groups_cache"));
    try testing.expect(@hasField(DiscoveryClient, "resources_cache"));
    try testing.expect(@hasDecl(DiscoveryClient, "serverVersion"));
    try testing.expect(@hasDecl(DiscoveryClient, "coreAPIVersions"));
    try testing.expect(@hasDecl(DiscoveryClient, "apiGroups"));
    try testing.expect(@hasDecl(DiscoveryClient, "coreResources"));
    try testing.expect(@hasDecl(DiscoveryClient, "groupResources"));
    try testing.expect(@hasDecl(DiscoveryClient, "hasResource"));
    try testing.expect(@hasDecl(DiscoveryClient, "hasGroup"));
    try testing.expect(@hasDecl(DiscoveryClient, "findPreferredVersion"));
    try testing.expect(@hasDecl(DiscoveryClient, "resourceMeta"));
    try testing.expect(@hasDecl(DiscoveryClient, "isResourceNamespaced"));
    try testing.expect(@hasDecl(DiscoveryClient, "invalidateCache"));
    try testing.expect(@hasDecl(DiscoveryClient, "invalidateGroupsCache"));
    try testing.expect(@hasDecl(DiscoveryClient, "invalidateResourceCache"));
    try testing.expect(@hasDecl(DiscoveryClient, "deinit"));
}

// MetaV1APIGroupList parsing
test "MetaV1APIGroupList: parse sample JSON with one group" {
    // Arrange
    const allocator = testing.allocator;
    const json_str =
        \\{"kind":"APIGroupList","apiVersion":"v1","groups":[{"name":"apps","versions":[{"groupVersion":"apps/v1","version":"v1"}],"preferredVersion":{"groupVersion":"apps/v1","version":"v1"},"serverAddressByClientCIDRs":null}]}
    ;

    // Act
    const parsed = try std.json.parseFromSlice(
        types.MetaV1APIGroupList,
        allocator,
        json_str,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    // Assert
    try testing.expectEqual(@as(usize, 1), parsed.value.groups.len);
    try testing.expectEqualStrings("apps", parsed.value.groups[0].name);
    try testing.expectEqualStrings("v1", parsed.value.groups[0].preferredVersion.?.version);
}

test "MetaV1APIGroupList: parse with empty groups array" {
    // Arrange
    const allocator = testing.allocator;
    const json_str =
        \\{"kind":"APIGroupList","apiVersion":"v1","groups":[]}
    ;

    // Act
    const parsed = try std.json.parseFromSlice(
        types.MetaV1APIGroupList,
        allocator,
        json_str,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    // Assert
    try testing.expectEqual(@as(usize, 0), parsed.value.groups.len);
}

test "MetaV1APIGroupList: parse with multiple groups" {
    // Arrange
    const allocator = testing.allocator;
    const json_str =
        \\{"kind":"APIGroupList","apiVersion":"v1","groups":[{"name":"apps","versions":[{"groupVersion":"apps/v1","version":"v1"}],"preferredVersion":{"groupVersion":"apps/v1","version":"v1"}},{"name":"batch","versions":[{"groupVersion":"batch/v1","version":"v1"}],"preferredVersion":{"groupVersion":"batch/v1","version":"v1"}}]}
    ;

    // Act
    const parsed = try std.json.parseFromSlice(
        types.MetaV1APIGroupList,
        allocator,
        json_str,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    // Assert
    try testing.expectEqual(@as(usize, 2), parsed.value.groups.len);
    try testing.expectEqualStrings("apps", parsed.value.groups[0].name);
    try testing.expectEqualStrings("batch", parsed.value.groups[1].name);
}

test "MetaV1APIGroupList: parse with missing preferredVersion" {
    // Arrange
    const allocator = testing.allocator;
    const json_str =
        \\{"kind":"APIGroupList","apiVersion":"v1","groups":[{"name":"apps","versions":[{"groupVersion":"apps/v1","version":"v1"}]}]}
    ;

    // Act
    const parsed = try std.json.parseFromSlice(
        types.MetaV1APIGroupList,
        allocator,
        json_str,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    // Assert
    try testing.expectEqual(@as(usize, 1), parsed.value.groups.len);
    try testing.expectEqualStrings("apps", parsed.value.groups[0].name);
    try testing.expect(parsed.value.groups[0].preferredVersion == null);
}

test "MetaV1APIGroupList: parse with unicode group name" {
    // Arrange
    const allocator = testing.allocator;
    const json_str =
        \\{"kind":"APIGroupList","apiVersion":"v1","groups":[{"name":"t\u00e9st.example.com","versions":[{"groupVersion":"t\u00e9st.example.com/v1","version":"v1"}]}]}
    ;

    // Act
    const parsed = try std.json.parseFromSlice(
        types.MetaV1APIGroupList,
        allocator,
        json_str,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    // Assert
    try testing.expectEqual(@as(usize, 1), parsed.value.groups.len);
    try testing.expect(parsed.value.groups[0].name.len > 0);
}

test "MetaV1APIGroupList: malformed JSON returns error" {
    // Arrange
    const allocator = testing.allocator;

    // Act / Assert
    const result = std.json.parseFromSlice(
        types.MetaV1APIGroupList,
        allocator,
        "not valid json",
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    try testing.expect(if (result) |_| false else |_| true);
}

test "MetaV1APIGroupList: empty string returns error" {
    // Arrange
    const allocator = testing.allocator;

    // Act / Assert
    const result = std.json.parseFromSlice(
        types.MetaV1APIGroupList,
        allocator,
        "",
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    try testing.expect(if (result) |_| false else |_| true);
}

// MetaV1APIResourceList parsing
test "MetaV1APIResourceList: parse sample JSON with subresource" {
    // Arrange
    const allocator = testing.allocator;
    const json_str =
        \\{"kind":"APIResourceList","apiVersion":"v1","groupVersion":"v1","resources":[{"name":"pods","singularName":"pod","namespaced":true,"kind":"Pod","verbs":["get","list","watch","create","delete"]},{"name":"pods/status","singularName":"","namespaced":true,"kind":"Pod","verbs":["get","patch","update"]}]}
    ;

    // Act
    const parsed = try std.json.parseFromSlice(
        types.MetaV1APIResourceList,
        allocator,
        json_str,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    // Assert
    try testing.expectEqualStrings("v1", parsed.value.groupVersion);
    try testing.expectEqual(@as(usize, 2), parsed.value.resources.len);
    try testing.expectEqualStrings("pods", parsed.value.resources[0].name);
    try testing.expect(parsed.value.resources[0].namespaced);
    try testing.expectEqualStrings("Pod", parsed.value.resources[0].kind);
    try testing.expect(std.mem.find(u8, parsed.value.resources[1].name, "/") != null);
}

test "MetaV1APIResourceList: parse with empty resources array" {
    // Arrange
    const allocator = testing.allocator;
    const json_str =
        \\{"kind":"APIResourceList","apiVersion":"v1","groupVersion":"v1","resources":[]}
    ;

    // Act
    const parsed = try std.json.parseFromSlice(
        types.MetaV1APIResourceList,
        allocator,
        json_str,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    // Assert
    try testing.expectEqualStrings("v1", parsed.value.groupVersion);
    try testing.expectEqual(@as(usize, 0), parsed.value.resources.len);
}

test "MetaV1APIResourceList: malformed JSON returns error" {
    // Arrange
    const allocator = testing.allocator;

    // Act / Assert
    const result = std.json.parseFromSlice(
        types.MetaV1APIResourceList,
        allocator,
        "{invalid",
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    try testing.expect(if (result) |_| false else |_| true);
}

// MetaV1APIVersions parsing
test "MetaV1APIVersions: parse sample JSON" {
    // Arrange
    const allocator = testing.allocator;
    const json_str =
        \\{"kind":"APIVersions","versions":["v1"],"serverAddressByClientCIDRs":[{"clientCIDR":"0.0.0.0/0","serverAddress":"10.0.0.1:6443"}]}
    ;

    // Act
    const parsed = try std.json.parseFromSlice(
        types.MetaV1APIVersions,
        allocator,
        json_str,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    // Assert
    try testing.expectEqual(@as(usize, 1), parsed.value.versions.len);
    try testing.expectEqualStrings("v1", parsed.value.versions[0]);
}

// PkgVersionInfo parsing
test "PkgVersionInfo: parse sample JSON with all fields" {
    // Arrange
    const allocator = testing.allocator;
    const json_str =
        \\{"major":"1","minor":"30","gitVersion":"v1.30.0","gitCommit":"abc","gitTreeState":"clean","buildDate":"2024-01-01T00:00:00Z","goVersion":"go1.22.2","compiler":"gc","platform":"linux/amd64"}
    ;

    // Act
    const parsed = try std.json.parseFromSlice(
        types.PkgVersionInfo,
        allocator,
        json_str,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    // Assert
    try testing.expectEqualStrings("1", parsed.value.major);
    try testing.expectEqualStrings("30", parsed.value.minor);
    try testing.expectEqualStrings("v1.30.0", parsed.value.gitVersion);
    try testing.expectEqualStrings("linux/amd64", parsed.value.platform);
}

test "PkgVersionInfo: malformed JSON returns error" {
    // Arrange
    const allocator = testing.allocator;

    // Act / Assert
    const result = std.json.parseFromSlice(
        types.PkgVersionInfo,
        allocator,
        "not json",
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    try testing.expect(if (result) |_| false else |_| true);
}
