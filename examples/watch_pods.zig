// Watch Pods: streams pod events (ADDED, MODIFIED, DELETED, BOOKMARK)
// from a Kubernetes cluster via kubectl proxy.
//
// Usage:
//   kubectl proxy &
//   zig build run-watch-pods

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

    try w.print("Watching pods in namespace '{s}'...\n", .{config.namespace});
    try w.print("Connecting to: {s}\n\n", .{config.base_url});
    try w.flush();

    const pods = kube_zig.Api(k8s.CoreV1Pod).init(&client, client.context(), config.namespace);

    var stream = try pods.watch(.{ .timeout_seconds = 300 });
    defer stream.close();

    while (try stream.next()) |event| {
        defer event.deinit();
        switch (event.event) {
            .added => |pod| {
                const name = kube_zig.metadata.getName(k8s.CoreV1Pod, pod) orelse "(unnamed)";
                const phase = if (pod.status) |s| (s.phase orelse "Unknown") else "Unknown";
                try w.print("ADDED    {s}  (phase: {s})\n", .{ name, phase });
            },
            .modified => |pod| {
                const name = kube_zig.metadata.getName(k8s.CoreV1Pod, pod) orelse "(unnamed)";
                const phase = if (pod.status) |s| (s.phase orelse "Unknown") else "Unknown";
                try w.print("MODIFIED {s}  (phase: {s})\n", .{ name, phase });
            },
            .deleted => |pod| {
                const name = kube_zig.metadata.getName(k8s.CoreV1Pod, pod) orelse "(unnamed)";
                try w.print("DELETED  {s}\n", .{name});
            },
            .bookmark => {
                const rv = stream.resourceVersion() orelse "(unknown)";
                try w.print("BOOKMARK (resourceVersion: {s})\n", .{rv});
            },
            .api_error => |api_err| {
                const code = if (api_err.code) |c| c else 0;
                const reason = api_err.reason orelse "Unknown";
                try w.print("ERROR    code={d} reason={s}\n", .{ code, reason });
            },
        }
        try w.flush();
    }

    try w.print("\nWatch stream ended.\n", .{});
    if (stream.resourceVersion()) |rv| {
        try w.print("Last resourceVersion: {s}\n", .{rv});
        try w.print("(Use this value to resume watching without replaying history)\n", .{});
    }
}
