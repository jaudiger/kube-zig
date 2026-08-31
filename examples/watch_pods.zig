// Watch Pods: streams pod events (ADDED, MODIFIED, DELETED, BOOKMARK)
// from a Kubernetes cluster via kubectl proxy.
//
// Usage:
//   kubectl proxy &
//   zig build run-watch-pods

const std = @import("std");
const kube_zig = @import("kube-zig");
const k8s = kube_zig.types;

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug_allocator.deinit() == .ok);
    const allocator = debug_allocator.allocator();

    const config = kube_zig.ProxyConfig.init(init.environ_map);
    var text_logger = kube_zig.log.TextStdoutLogger.init(io, .info);

    var client = try kube_zig.Client.init(allocator, io, config.base_url, .{ .logger = text_logger.logger() });
    defer client.deinit(io);

    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    const w = &stdout.interface;
    defer w.flush() catch {};

    try w.print("Watching pods in namespace '{s}'...\n", .{config.namespace});
    try w.print("Connecting to: {s}\n\n", .{config.base_url});
    try w.flush();

    const pods = kube_zig.Api(k8s.CoreV1Pod).init(&client, client.context(), config.namespace);

    var stream = try pods.watch(.{ .timeout_seconds = 300 });
    defer stream.deinit();

    const SinkCtx = struct {
        writer: *std.Io.Writer,

        fn receive(ctx: *@This(), _: std.Io, parsed: *const kube_zig.ParsedEvent(k8s.CoreV1Pod)) anyerror!void {
            switch (parsed.event) {
                .added => |pod| {
                    const name = kube_zig.metadata.getName(k8s.CoreV1Pod, pod) orelse "(unnamed)";
                    const phase = if (pod.status) |s| (s.phase orelse "Unknown") else "Unknown";
                    try ctx.writer.print("ADDED    {s}  (phase: {s})\n", .{ name, phase });
                },
                .modified => |pod| {
                    const name = kube_zig.metadata.getName(k8s.CoreV1Pod, pod) orelse "(unnamed)";
                    const phase = if (pod.status) |s| (s.phase orelse "Unknown") else "Unknown";
                    try ctx.writer.print("MODIFIED {s}  (phase: {s})\n", .{ name, phase });
                },
                .deleted => |pod| {
                    const name = kube_zig.metadata.getName(k8s.CoreV1Pod, pod) orelse "(unnamed)";
                    try ctx.writer.print("DELETED  {s}\n", .{name});
                },
                .bookmark => |bookmark| try ctx.writer.print("BOOKMARK (resourceVersion: {s})\n", .{bookmark.resource_version}),
                .api_error => |api_err| {
                    const code = if (api_err.code) |c| c else 0;
                    const reason = api_err.reason orelse "Unknown";
                    try ctx.writer.print("ERROR    code={d} reason={s}\n", .{ code, reason });
                },
            }
            try ctx.writer.flush();
        }
    };
    var sink_ctx = SinkCtx{ .writer = w };
    const sink = kube_zig.EventSink(k8s.CoreV1Pod).fromTypedCtx(SinkCtx, &sink_ctx, SinkCtx.receive);
    var task = try io.concurrent(kube_zig.WatchStream(k8s.CoreV1Pod).run, .{ &stream, io, sink });
    try task.await(io);

    try w.print("\nWatch stream ended.\n", .{});
}
