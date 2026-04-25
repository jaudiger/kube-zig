// Namespace Inventory: queries several resource types in a namespace using
// comptime dispatch and prints a summary table followed by per-kind details.

const std = @import("std");
const kube_zig = @import("kube-zig");
const k8s = kube_zig.types;

/// Comptime resource descriptors: label + Kubernetes type.
const resources = .{
    .{ "Deployments", k8s.AppsV1Deployment },
    .{ "StatefulSets", k8s.AppsV1StatefulSet },
    .{ "DaemonSets", k8s.AppsV1DaemonSet },
    .{ "Services", k8s.CoreV1Service },
    .{ "ConfigMaps", k8s.CoreV1ConfigMap },
    .{ "Secrets", k8s.CoreV1Secret },
    .{ "Jobs", k8s.BatchV1Job },
};

const ResourceEntry = struct {
    kind: []const u8,
    names: std.ArrayList([]const u8),
    failed: bool,

    fn init(kind: []const u8) ResourceEntry {
        return .{
            .kind = kind,
            .names = .empty,
            .failed = false,
        };
    }

    fn deinit(self: *ResourceEntry, allocator: std.mem.Allocator) void {
        for (self.names.items) |name| {
            allocator.free(name);
        }
        self.names.deinit(allocator);
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug_allocator.deinit() == .ok);
    const allocator = debug_allocator.allocator();

    const config = kube_zig.ProxyConfig.init(init.environ_map);
    var text_logger = kube_zig.TextStdoutLogger.init(io, .info);

    const logger = text_logger.logger();
    var client = try kube_zig.Client.init(allocator, io, config.base_url, .{ .logger = logger });
    defer client.deinit(io);

    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    const w = &stdout.interface;
    defer w.flush() catch {};

    const namespace = config.namespace;

    try w.print("Namespace Inventory: {s}\n", .{namespace});
    try w.print("Connecting to: {s}\n\n", .{config.base_url});

    // Query each resource type via comptime dispatch.
    var entries: [resources.len]ResourceEntry = undefined;
    inline for (resources, 0..) |res, i| {
        entries[i] = ResourceEntry.init(res[0]);
    }
    defer for (&entries) |*e| e.deinit(allocator);

    inline for (resources, 0..) |res, i| {
        queryAndCollect(res[1], &client, io, namespace, allocator, &entries[i], logger);
    }

    // Print summary table.
    try w.print("{s:<20} {s:>6}\n", .{ "Resource", "Count" });
    try w.print("{s:<20} {s:>6}\n", .{ "-" ** 20, "-" ** 6 });

    var total: usize = 0;
    for (&entries) |*entry| {
        if (entry.failed) {
            try w.print("{s:<20} {s:>6}\n", .{ entry.kind, "error" });
        } else {
            try w.print("{s:<20} {d:>6}\n", .{ entry.kind, entry.names.items.len });
            total += entry.names.items.len;
        }
    }

    try w.print("{s:<20} {s:>6}\n", .{ "-" ** 20, "-" ** 6 });
    try w.print("{s:<20} {d:>6}\n\n", .{ "Total", total });

    // Print details per resource kind.
    for (&entries) |*entry| {
        if (entry.failed or entry.names.items.len == 0) continue;

        try w.print("{s}:\n", .{entry.kind});
        for (entry.names.items) |name| {
            try w.print("  - {s}\n", .{name});
        }
        try w.print("\n", .{});
    }
}

fn queryAndCollect(
    comptime T: type,
    client: *kube_zig.Client,
    io: std.Io,
    namespace: []const u8,
    allocator: std.mem.Allocator,
    entry: *ResourceEntry,
    logger: kube_zig.Logger,
) void {
    const api = kube_zig.Api(T).init(client, client.context(), namespace);
    const result = api.list(io, .{}) catch |err| {
        logger.err("failed to list resources", &.{ kube_zig.LogField.string("kind", entry.kind), kube_zig.LogField.err("error", err) });
        entry.failed = true;
        return;
    };
    const parsed = result.value() catch |err| {
        logger.err("failed to parse response", &.{ kube_zig.LogField.string("kind", entry.kind), kube_zig.LogField.err("error", err) });
        entry.failed = true;
        return;
    };
    defer parsed.deinit();

    const items = parsed.value.items;
    if (items.len == 0) return;

    for (items) |item| {
        const name = kube_zig.metadata.getName(T, item) orelse "(unnamed)";
        // Dupe the name so it survives parsed.deinit().
        const owned = allocator.dupe(u8, name) catch continue;
        entry.names.append(allocator, owned) catch {
            allocator.free(owned);
            continue;
        };
    }
}
