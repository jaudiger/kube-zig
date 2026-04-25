// Informer Pods: watches pods using the Informer pattern, maintaining
// a local cache that stays in sync via list+watch.
//
// Usage:
//   kubectl proxy &
//   zig build run-informer-pods

const std = @import("std");
const kube_zig = @import("kube-zig");
const k8s = kube_zig.types;

const Pod = k8s.CoreV1Pod;

const HandlerCtx = struct {
    fn onAdd(_: *HandlerCtx, io: std.Io, obj: *const Pod, is_initial: bool) void {
        const name = podName(obj);
        const phase = podPhase(obj);
        const prefix: []const u8 = if (is_initial) "SYNC" else "ADD ";
        var buf: [4096]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(io, &buf);
        const w = &stdout.interface;
        w.print("{s} {s}  (phase: {s})\n", .{ prefix, name, phase }) catch {};
        w.flush() catch {};
    }

    fn onUpdate(_: *HandlerCtx, io: std.Io, old: *const Pod, new: *const Pod) void {
        const name = podName(new);
        const old_rv = podRV(old);
        const new_rv = podRV(new);
        var buf: [4096]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(io, &buf);
        const w = &stdout.interface;
        w.print("UPD  {s}  rv:{s} -> rv:{s}\n", .{ name, old_rv, new_rv }) catch {};
        w.flush() catch {};
    }

    fn onDelete(_: *HandlerCtx, io: std.Io, obj: *const Pod) void {
        const name = podName(obj);
        var buf: [4096]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(io, &buf);
        const w = &stdout.interface;
        w.print("DEL  {s}\n", .{name}) catch {};
        w.flush() catch {};
    }
};

fn podName(p: *const Pod) []const u8 {
    return kube_zig.metadata.getName(Pod, p.*) orelse "(unnamed)";
}

fn podPhase(p: *const Pod) []const u8 {
    return if (p.status) |s| (s.phase orelse "Unknown") else "Unknown";
}

fn podRV(p: *const Pod) []const u8 {
    return kube_zig.metadata.getResourceVersion(Pod, p.*) orelse "?";
}

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

    var informer = kube_zig.Informer(Pod).init(allocator, &client, client.context(), config.namespace, .{ .logger = logger });
    defer informer.deinit(io);

    var handler_ctx = HandlerCtx{};

    try informer.addEventHandler(kube_zig.EventHandler(Pod).fromTypedCtx(HandlerCtx, &handler_ctx, .{
        .on_add = HandlerCtx.onAdd,
        .on_update = HandlerCtx.onUpdate,
        .on_delete = HandlerCtx.onDelete,
    }));

    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    const w = &stdout.interface;
    try w.print("Starting pod informer in namespace '{s}'...\n", .{config.namespace});
    try w.print("Connecting to: {s}\n\n", .{config.base_url});
    try w.flush();

    try informer.run(io);
}
