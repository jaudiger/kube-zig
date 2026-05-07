//! Log stream iterator for tailing Kubernetes pod logs.
//!
//! Provides `LogStream`, a line-based iterator over a streaming HTTP
//! response that yields raw log lines. Modeled after `WatchStream` but
//! without JSON parsing.

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

/// Iterator over a Kubernetes pod log stream that yields raw log lines.
///
/// Example:
/// ```zig
/// var stream = try api.streamLogs(io, "my-pod", .{}, .{});
/// defer stream.close(io);
/// while (try stream.nextLine(io)) |line| {
///     defer stream.allocator.free(line);
///     // use line
/// }
/// ```
pub const LogStream = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    ctx: Context,
    state: *StreamState,
    closed: bool,
    max_line_size: usize,
    watcher: ?*CancelWatcher,

    /// Background cancellation helper.
    const CancelWatcher = struct {
        io: Io,
        ctx: Context,
        state: *StreamState,
        done: std.atomic.Value(u32),
        thread: std.Thread,

        const poll_ns: u64 = 50 * std.time.ns_per_ms;

        fn run(self: *CancelWatcher) void {
            const timeout: Io.Timeout = .{ .duration = .{
                .clock = .awake,
                .raw = .{ .nanoseconds = poll_ns },
            } };
            while (true) {
                if (self.done.load(.acquire) != 0) return;
                if (self.ctx.isCanceled(self.io)) {
                    self.state.interrupt(self.io);
                    return;
                }
                self.io.futexWaitTimeout(u32, &self.done.raw, 0, timeout) catch {};
            }
        }
    };

    /// Initialize a log stream by opening an HTTP streaming connection.
    pub fn init(client_ptr: *Client, io: std.Io, ctx: Context, path: []const u8, opts: LogStreamOptions) !Self {
        const stream_resp = try client_ptr.logStream(io, path, ctx);
        errdefer stream_resp.state.deinit();

        const watcher = try client_ptr.allocator.create(CancelWatcher);
        errdefer client_ptr.allocator.destroy(watcher);
        watcher.* = .{
            .io = io,
            .ctx = ctx,
            .state = stream_resp.state,
            .done = std.atomic.Value(u32).init(0),
            .thread = undefined,
        };
        watcher.thread = try std.Thread.spawn(.{}, CancelWatcher.run, .{watcher});

        return .{
            .allocator = client_ptr.allocator,
            .ctx = ctx,
            .state = stream_resp.state,
            .closed = false,
            .max_line_size = opts.max_line_size,
            .watcher = watcher,
        };
    }

    /// Read the next log line from the stream.
    /// Return `null` on clean end-of-stream. The returned slice is owned
    /// by `self.allocator`; the caller must free it.
    pub fn nextLine(self: *Self, io: std.Io) !?[]const u8 {
        if (self.closed) return null;
        self.ctx.check(io) catch return error.Canceled;

        const reader = self.state.reader orelse return null;

        var line_writer = Io.Writer.Allocating.init(self.allocator);
        errdefer line_writer.deinit();

        _ = reader.streamDelimiterLimit(&line_writer.writer, '\n', Io.Limit.limited(self.max_line_size)) catch |err| switch (err) {
            error.ReadFailed => return error.ConnectionResetByPeer,
            error.WriteFailed => return error.OutOfMemory,
            error.StreamTooLong => return error.LineTooLong,
        };

        if (reader.bufferedLen() > 0) {
            reader.toss(1);
        } else {
            line_writer.deinit();
            return null;
        }

        return line_writer.toOwnedSlice() catch return error.OutOfMemory;
    }

    /// Close the log stream and release all resources.
    pub fn close(self: *Self, io: Io) void {
        if (self.closed) return;
        self.closed = true;
        if (self.watcher) |w| {
            w.done.store(1, .release);
            io.futexWake(u32, &w.done.raw, std.math.maxInt(u32));
            w.thread.join();
            self.allocator.destroy(w);
            self.watcher = null;
        }
        self.state.deinit();
    }
};
