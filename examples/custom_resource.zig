// Custom Resource (Typed): defines a CronTab CRD type with resource_meta
// and performs typed CRUD operations using Api(T).
//
// This example demonstrates how to use kube-zig with Custom Resource Definitions
// (CRDs) by defining Zig struct types with comptime resource_meta, giving you
// full type safety for your custom resources.
//
// Prerequisites:
//   1. A running cluster with `kubectl proxy` on :8001
//   2. The CronTab CRD installed:
//
//      kubectl apply -f - <<'EOF'
//      apiVersion: apiextensions.k8s.io/v1
//      kind: CustomResourceDefinition
//      metadata:
//        name: crontabs.stable.example.com
//      spec:
//        group: stable.example.com
//        versions:
//          - name: v1
//            served: true
//            storage: true
//            schema:
//              openAPIV3Schema:
//                type: object
//                properties:
//                  spec:
//                    type: object
//                    properties:
//                      cronSpec:
//                        type: string
//                      image:
//                        type: string
//                      replicas:
//                        type: integer
//                  status:
//                    type: object
//                    properties:
//                      active:
//                        type: boolean
//                      lastSchedule:
//                        type: string
//            subresources:
//              status: {}
//        scope: Namespaced
//        names:
//          plural: crontabs
//          singular: crontab
//          kind: CronTab
//          shortNames:
//            - ct
//      EOF

const std = @import("std");
const kube_zig = @import("kube-zig");

// CRD type definitions
//
// These mirror the CRD schema above. All fields are optional with null
// default to match Kubernetes JSON conventions (the API may omit any field).

/// List wrapper for CronTab resources.
pub const CronTabList = struct {
    apiVersion: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    metadata: ?ListMetadata = null,
    items: []const CronTab = &.{},
};

pub const ListMetadata = struct {
    resourceVersion: ?[]const u8 = null,
    @"continue": ?[]const u8 = null,
};

/// A CronTab custom resource.
pub const CronTab = struct {
    /// Comptime resource metadata. This is what makes Api(T) work.
    /// The six fields are: group, version, kind, resource (plural), namespaced, and list_kind.
    pub const resource_meta = .{
        .group = "stable.example.com",
        .version = "v1",
        .kind = "CronTab",
        .resource = "crontabs",
        .namespaced = true,
        .list_kind = CronTabList,
    };

    apiVersion: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    metadata: ?Metadata = null,
    spec: ?CronTabSpec = null,
    status: ?CronTabStatus = null,
};

pub const Metadata = struct {
    name: ?[]const u8 = null,
    namespace: ?[]const u8 = null,
    resourceVersion: ?[]const u8 = null,
    uid: ?[]const u8 = null,
    creationTimestamp: ?[]const u8 = null,
    labels: ?std.json.ArrayHashMap([]const u8) = null,
    annotations: ?std.json.ArrayHashMap([]const u8) = null,
};

pub const CronTabSpec = struct {
    cronSpec: ?[]const u8 = null,
    image: ?[]const u8 = null,
    replicas: ?i32 = null,
};

pub const CronTabStatus = struct {
    active: ?bool = null,
    lastSchedule: ?[]const u8 = null,
};

// Type alias for convenience
const CronTabApi = kube_zig.Api(CronTab);

const crontab_name = "example-crontab";

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug_allocator.deinit() == .ok);
    const allocator = debug_allocator.allocator();

    const config = kube_zig.ProxyConfig.init();
    var text_logger = kube_zig.TextStdoutLogger.init(.info);

    var client = try kube_zig.Client.init(allocator, config.base_url, .{ .logger = text_logger.logger() });
    defer client.deinit();

    var buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);
    const w = &stdout.interface;
    defer w.flush() catch {};

    const namespace = config.namespace;

    try w.print("Custom Resource (Typed) Example\n", .{});
    try w.print("Connecting to: {s}\n\n", .{config.base_url});

    const crontabs = CronTabApi.init(&client, client.context(), namespace);

    // 1. Create a CronTab (using SSA apply, idempotent)
    try w.print("-- Creating CronTab --\n", .{});

    const create_result = crontabs.apply(crontab_name, .{
        .metadata = .{
            .name = crontab_name,
            .namespace = namespace,
        },
        .spec = .{
            .cronSpec = "*/5 * * * *",
            .image = "my-awesome-image:v1",
            .replicas = 3,
        },
    }, .{ .field_manager = "custom-resource-example", .force = true }) catch |err| {
        try w.print("  Failed to apply CronTab: {}\n", .{err});
        return;
    };
    const created = create_result.value() catch |err| {
        try w.print("  API error applying CronTab: {}\n", .{err});
        return;
    };
    defer created.deinit();

    const created_name = kube_zig.metadata.getName(CronTab, created.value) orelse "?";
    try w.print("  Created: {s}\n", .{created_name});
    if (created.value.spec) |spec| {
        try w.print("  Spec: cronSpec={s}  image={s}  replicas={d}\n\n", .{
            spec.cronSpec orelse "?",
            spec.image orelse "?",
            spec.replicas orelse 0,
        });
    }

    // 2. List CronTabs
    try w.print("-- Listing CronTabs --\n", .{});

    const list_result = crontabs.list(.{}) catch |err| {
        try w.print("  Failed to list CronTabs: {}\n", .{err});
        cleanup(crontabs, w);
        return;
    };
    const list_parsed = list_result.value() catch |err| {
        try w.print("  API error listing CronTabs: {}\n", .{err});
        cleanup(crontabs, w);
        return;
    };
    defer list_parsed.deinit();

    try w.print("  Found {d} CronTab(s):\n", .{list_parsed.value.items.len});
    for (list_parsed.value.items) |item| {
        const name = kube_zig.metadata.getName(CronTab, item) orelse "?";
        const cron = if (item.spec) |s| (s.cronSpec orelse "?") else "?";
        try w.print("    - {s} (schedule: {s})\n", .{ name, cron });
    }
    try w.print("\n", .{});

    // 3. Get by name
    try w.print("-- Getting CronTab by name --\n", .{});

    const get_result = crontabs.get(crontab_name) catch |err| {
        try w.print("  Failed to get CronTab: {}\n", .{err});
        cleanup(crontabs, w);
        return;
    };
    const fetched = get_result.value() catch |err| {
        try w.print("  API error getting CronTab: {}\n", .{err});
        cleanup(crontabs, w);
        return;
    };
    defer fetched.deinit();

    const fetched_name = kube_zig.metadata.getName(CronTab, fetched.value) orelse "?";
    const rv = kube_zig.metadata.getResourceVersion(CronTab, fetched.value) orelse "?";
    try w.print("  Got: {s}\n", .{fetched_name});
    try w.print("  resourceVersion: {s}\n\n", .{rv});

    // 4. Update (change replicas via SSA apply)
    try w.print("-- Updating CronTab --\n", .{});

    const update_result = crontabs.apply(crontab_name, .{
        .metadata = .{
            .name = crontab_name,
            .namespace = namespace,
        },
        .spec = .{
            .cronSpec = "*/5 * * * *",
            .image = "my-awesome-image:v2",
            .replicas = 5,
        },
    }, .{ .field_manager = "custom-resource-example", .force = true }) catch |err| {
        try w.print("  Failed to update CronTab: {}\n", .{err});
        cleanup(crontabs, w);
        return;
    };
    const updated = update_result.value() catch |err| {
        try w.print("  API error updating CronTab: {}\n", .{err});
        cleanup(crontabs, w);
        return;
    };
    defer updated.deinit();

    if (updated.value.spec) |spec| {
        try w.print("  Updated: image={s}  replicas={d}\n\n", .{
            spec.image orelse "?",
            spec.replicas orelse 0,
        });
    }

    // 5. Delete
    cleanup(crontabs, w);

    try w.print("\nDone.\n", .{});
}

fn cleanup(crontabs: CronTabApi, w: *std.Io.Writer) void {
    w.print("-- Deleting CronTab {s} --\n", .{crontab_name}) catch return;
    const result = crontabs.delete(crontab_name, .{}) catch |err| {
        w.print("  Failed to delete: {}\n", .{err}) catch {};
        return;
    };
    result.deinit();
    w.print("  Deleted.\n", .{}) catch {};
}
