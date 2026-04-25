// Custom Resource (Dynamic): uses DynamicApi with runtime ResourceMeta
// to perform CRUD operations on a CRD without any type definitions.
//
// This example demonstrates the dynamic/untyped approach for working with
// Custom Resource Definitions. Instead of defining Zig structs, you provide
// resource metadata at runtime and work with raw JSON (std.json.Value).
//
// This approach is useful when:
//   - The CRD schema is not known at compile time
//   - You are building generic tooling that works with any resource type
//   - You want a quick script without defining full type hierarchies
//
// Prerequisites:
//   1. A running cluster with `kubectl proxy` on :8001
//   2. The CronTab CRD installed (see custom_resource.zig for the YAML)

const std = @import("std");
const kube_zig = @import("kube-zig");

const crontab_name = "dynamic-crontab";

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug_allocator.deinit() == .ok);
    const allocator = debug_allocator.allocator();

    const config = kube_zig.ProxyConfig.init(init.environ_map);
    var text_logger = kube_zig.TextStdoutLogger.init(io, .info);

    var client = try kube_zig.Client.init(allocator, io, config.base_url, .{ .logger = text_logger.logger() });
    defer client.deinit(io);

    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    const w = &stdout.interface;
    defer w.flush() catch {};

    const namespace = config.namespace;

    try w.print("Custom Resource (Dynamic) Example\n", .{});
    try w.print("Connecting to: {s}\n\n", .{config.base_url});

    // Initialize DynamicApi with runtime metadata
    // No list_kind needed: responses are untyped json.Value.
    const crontabs = try kube_zig.DynamicApi.init(&client, client.context(), .{
        .group = "stable.example.com",
        .version = "v1",
        .kind = "CronTab",
        .resource = "crontabs",
        .namespaced = true,
    }, namespace);

    // 1. Create a CronTab from a JSON string
    try w.print("-- Creating CronTab --\n", .{});

    const create_body = std.fmt.comptimePrint(
        \\{{"apiVersion":"stable.example.com/v1","kind":"CronTab","metadata":{{"name":"{s}","namespace":"{s}"}},"spec":{{"cronSpec":"*/10 * * * *","image":"dynamic-image:v1","replicas":2}}}}
    , .{ crontab_name, "default" });

    const create_result = crontabs.create(io, create_body, .{}) catch |err| {
        try w.print("  Failed to create CronTab: {}\n", .{err});
        return;
    };
    const created = create_result.value() catch |err| {
        try w.print("  API error creating CronTab: {}\n", .{err});
        return;
    };
    defer created.deinit();

    // Navigate the json.Value tree to extract fields.
    const created_obj = created.value.object;
    if (created_obj.get("metadata")) |meta| {
        if (meta.object.get("name")) |name_val| {
            try w.print("  Created: {s}\n", .{name_val.string});
        }
    }
    if (created_obj.get("spec")) |spec| {
        const cron = if (spec.object.get("cronSpec")) |v| v.string else "?";
        const image = if (spec.object.get("image")) |v| v.string else "?";
        try w.print("  Spec: cronSpec={s}  image={s}\n\n", .{ cron, image });
    }

    // 2. List CronTabs
    try w.print("-- Listing CronTabs --\n", .{});

    const list_result = crontabs.list(io, .{}) catch |err| {
        try w.print("  Failed to list CronTabs: {}\n", .{err});
        cleanup(crontabs, io, w);
        return;
    };
    const list_parsed = list_result.value() catch |err| {
        try w.print("  API error listing CronTabs: {}\n", .{err});
        cleanup(crontabs, io, w);
        return;
    };
    defer list_parsed.deinit();

    // Items come back as a json.Value array.
    if (list_parsed.value.object.get("items")) |items_val| {
        const items = items_val.array.items;
        try w.print("  Found {d} CronTab(s):\n", .{items.len});
        for (items) |item| {
            const name = if (item.object.get("metadata")) |m|
                (if (m.object.get("name")) |n| n.string else "?")
            else
                "?";
            const cron = if (item.object.get("spec")) |s|
                (if (s.object.get("cronSpec")) |c| c.string else "?")
            else
                "?";
            try w.print("    - {s} (schedule: {s})\n", .{ name, cron });
        }
    }
    try w.print("\n", .{});

    // 3. Get by name
    try w.print("-- Getting CronTab by name --\n", .{});

    const get_result = crontabs.get(io, crontab_name) catch |err| {
        try w.print("  Failed to get CronTab: {}\n", .{err});
        cleanup(crontabs, io, w);
        return;
    };
    const fetched = get_result.value() catch |err| {
        try w.print("  API error getting CronTab: {}\n", .{err});
        cleanup(crontabs, io, w);
        return;
    };
    defer fetched.deinit();

    const fetched_obj = fetched.value.object;
    if (fetched_obj.get("metadata")) |meta| {
        if (meta.object.get("name")) |name_val| {
            try w.print("  Got: {s}\n", .{name_val.string});
        }
        if (meta.object.get("resourceVersion")) |rv| {
            try w.print("  resourceVersion: {s}\n\n", .{rv.string});
        }
    }

    // 4. Patch (merge patch to update image)
    try w.print("-- Patching CronTab --\n", .{});

    const patch_body =
        \\{"spec":{"image":"dynamic-image:v2","replicas":4}}
    ;

    const patch_result = crontabs.patch(io, crontab_name, patch_body, .{
        .patch_type = .merge_patch,
    }) catch |err| {
        try w.print("  Failed to patch CronTab: {}\n", .{err});
        cleanup(crontabs, io, w);
        return;
    };
    const patched = patch_result.value() catch |err| {
        try w.print("  API error patching CronTab: {}\n", .{err});
        cleanup(crontabs, io, w);
        return;
    };
    defer patched.deinit();

    if (patched.value.object.get("spec")) |spec| {
        const image = if (spec.object.get("image")) |v| v.string else "?";
        try w.print("  Patched: image={s}\n\n", .{image});
    }

    // 5. Delete
    cleanup(crontabs, io, w);

    try w.print("\nDone.\n", .{});
}

fn cleanup(crontabs: kube_zig.DynamicApi, io: std.Io, w: *std.Io.Writer) void {
    w.print("-- Deleting CronTab {s} --\n", .{crontab_name}) catch return;
    const result = crontabs.delete(io, crontab_name, .{}) catch |err| {
        w.print("  Failed to delete: {}\n", .{err}) catch {};
        return;
    };
    result.deinit();
    w.print("  Deleted.\n", .{}) catch {};
}
