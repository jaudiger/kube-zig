// Cluster Health Report: lists all nodes and prints system info, addresses,
// conditions, and capacity vs allocatable resources for each one, ending with
// a healthy/unhealthy summary.

const std = @import("std");
const kube_zig = @import("kube-zig");
const k8s = kube_zig.types;

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

    try w.print("Cluster Health Report\n", .{});
    try w.print("Connecting to: {s}\n\n", .{config.base_url});

    // List all nodes (cluster-scoped, no namespace needed).
    const nodes_api = kube_zig.Api(k8s.CoreV1Node).init(&client, client.context(), null);
    const parsed = try (try nodes_api.list(.{})).value();
    defer parsed.deinit();

    const items = parsed.value.items;
    if (items.len == 0) {
        try w.print("No nodes found in the cluster.\n", .{});
        return;
    }

    try w.print("Found {d} node(s)\n", .{items.len});
    try w.print("{s}\n\n", .{"=" ** 72});

    var healthy_count: usize = 0;
    var unhealthy_count: usize = 0;

    for (items) |node| {
        const name = kube_zig.metadata.getName(k8s.CoreV1Node, node) orelse "(unnamed)";
        try w.print("Node: {s}\n", .{name});
        try w.print("{s}\n", .{"-" ** 72});

        if (node.status) |status| {
            // System info
            if (status.nodeInfo) |info| {
                try w.print("  OS:                {s} {s}\n", .{
                    info.operatingSystem,
                    info.osImage,
                });
                try w.print("  Architecture:      {s}\n", .{info.architecture});
                try w.print("  Kernel:            {s}\n", .{info.kernelVersion});
                try w.print("  Container runtime: {s}\n", .{info.containerRuntimeVersion});
                try w.print("  Kubelet:           {s}\n", .{info.kubeletVersion});
            }

            // Addresses
            if (status.addresses) |addrs| {
                for (addrs) |addr| {
                    try w.print("  {s}: {s}\n", .{
                        addr.type,
                        addr.address,
                    });
                }
            }

            try w.print("\n  Conditions:\n", .{});

            // Conditions: use library helpers for health determination.
            const conds = status.conditions;
            const ready = kube_zig.conditions.isConditionTrue(@TypeOf(conds), conds, "Ready");
            const disk_pressure = kube_zig.conditions.isConditionTrue(@TypeOf(conds), conds, "DiskPressure");
            const mem_pressure = kube_zig.conditions.isConditionTrue(@TypeOf(conds), conds, "MemoryPressure");
            const pid_pressure = kube_zig.conditions.isConditionTrue(@TypeOf(conds), conds, "PIDPressure");
            const node_healthy = ready and !disk_pressure and !mem_pressure and !pid_pressure;

            if (conds) |conditions| {
                for (conditions) |cond| {
                    const cond_type = cond.type;
                    const cond_status = cond.status;

                    const is_problem = if (std.mem.eql(u8, cond_type, "Ready"))
                        !std.mem.eql(u8, cond_status, "True")
                    else
                        std.mem.eql(u8, cond_status, "True");

                    try w.print("    {s} {s}: {s}", .{
                        if (is_problem) @as([]const u8, "[!]") else "   ",
                        cond_type,
                        cond_status,
                    });
                    if (cond.message) |msg| {
                        try w.print("  ({s}{s})", .{
                            msg[0..@min(msg.len, 60)],
                            if (msg.len > 60) "..." else "",
                        });
                    }
                    try w.print("\n", .{});
                }
            } else {
                try w.print("    (no conditions reported)\n", .{});
            }

            if (node_healthy) {
                healthy_count += 1;
            } else {
                unhealthy_count += 1;
            }

            // Capacity vs allocatable resources.
            const resource_keys = [_][]const u8{ "cpu", "memory", "ephemeral-storage", "pods" };

            if (status.capacity != null or status.allocatable != null) {
                try w.print("\n  Resources:\n", .{});
                try w.print("    {s:<24} {s:>12} {s:>12}\n", .{ "Resource", "Capacity", "Allocatable" });
                try w.print("    {s:<24} {s:>12} {s:>12}\n", .{ "-" ** 24, "-" ** 12, "-" ** 12 });

                for (resource_keys) |key| {
                    const cap = if (status.capacity) |c| (c.map.get(key) orelse "-") else "-";
                    const alloc = if (status.allocatable) |a| (a.map.get(key) orelse "-") else "-";
                    try w.print("    {s:<24} {s:>12} {s:>12}\n", .{ key, cap, alloc });
                }
            }
        } else {
            try w.print("  (no status available)\n", .{});
            unhealthy_count += 1;
        }

        try w.print("\n", .{});
    }

    // Summary
    try w.print("{s}\n", .{"=" ** 72});
    try w.print("Summary: {d} healthy, {d} unhealthy, {d} total\n", .{
        healthy_count,
        unhealthy_count,
        items.len,
    });
}
