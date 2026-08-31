//! Task-oriented Kubernetes pod log streaming.
//!
//! `LogStream` opens its HTTP connection when `run` is called and delivers
//! borrowed lines to a callback sink.

const std = @import("std");
const client_mod = @import("../client/Client.zig");
const Client = client_mod.Client;
const Context = client_mod.Context;
const StreamState = client_mod.StreamState;
const Io = std.Io;

/// Options for log streaming.
pub const LogStreamOptions = struct {
    /// Maximum bytes allowed for a single log line (default: 1 MiB).
    max_line_size: usize = 1024 * 1024,
};

/// A callback sink for lines delivered by `LogStream.run`.
pub const LineSink = struct {
    ctx: ?*anyopaque,
    call: *const fn (?*anyopaque, Io, []const u8) anyerror!void,

    pub fn fromFn(comptime func: *const fn (Io, []const u8) anyerror!void) LineSink {
        const Wrapper = struct {
            fn call(_: ?*anyopaque, io: Io, line: []const u8) anyerror!void {
                return func(io, line);
            }
        };
        return .{ .ctx = null, .call = Wrapper.call };
    }

    pub fn fromTypedCtx(comptime Ctx: type, ctx: *Ctx, comptime func: *const fn (*Ctx, Io, []const u8) anyerror!void) LineSink {
        const Wrapper = struct {
            fn call(raw: ?*anyopaque, io: Io, line: []const u8) anyerror!void {
                return func(@ptrCast(@alignCast(raw.?)), io, line);
            }
        };
        return .{ .ctx = @ptrCast(ctx), .call = Wrapper.call };
    }

    fn emit(self: LineSink, io: Io, line: []const u8) anyerror!void {
        return self.call(self.ctx, io, line);
    }
};

/// Configuration for a task-oriented Kubernetes pod log stream.
/// The path is owned by the stream and must be released with `deinit`.
const LineSinkType = LineSink;
pub const LogStream = struct {
    pub const LineSink = LineSinkType;
    pub const Sink = LineSinkType;
    allocator: std.mem.Allocator,
    client: *Client,
    ctx: Context,
    path: []u8,
    max_line_size: usize,

    pub fn init(client_ptr: *Client, ctx: Context, path: []const u8, opts: LogStreamOptions) !LogStream {
        const owned_path = try client_ptr.allocator.dupe(u8, path);
        return .{
            .allocator = client_ptr.allocator,
            .client = client_ptr,
            .ctx = ctx,
            .path = owned_path,
            .max_line_size = opts.max_line_size,
        };
    }

    pub fn deinit(self: *LogStream) void {
        self.allocator.free(self.path);
        self.path = &.{};
    }

    /// Open the log stream and deliver borrowed lines to `sink`.
    pub fn run(self: *LogStream, io: Io, sink: LineSinkType) anyerror!void {
        const stream_resp = try self.client.logStream(io, self.path, self.ctx);
        defer stream_resp.state.deinit();
        const reader = stream_resp.state.reader orelse return;

        while (true) {
            try self.ctx.check(io);
            var line_writer = Io.Writer.Allocating.init(self.allocator);
            defer line_writer.deinit();

            _ = reader.streamDelimiterLimit(&line_writer.writer, '\n', Io.Limit.limited(self.max_line_size)) catch |err| switch (err) {
                error.ReadFailed => {
                    io.checkCancel() catch return error.Canceled;
                    return error.ConnectionResetByPeer;
                },
                error.WriteFailed => return error.OutOfMemory,
                error.StreamTooLong => return error.LineTooLong,
            };

            if (reader.bufferedLen() == 0) return;
            reader.toss(1);
            const line = line_writer.toOwnedSlice() catch return error.OutOfMemory;
            defer self.allocator.free(line);
            try sink.emit(io, line);
        }
    }
};
