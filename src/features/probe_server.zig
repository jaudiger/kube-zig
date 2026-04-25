//! Lightweight HTTP probe server for Kubernetes liveness and readiness checks.
//!
//! Listens on a configurable TCP port and serves two endpoints:
//! - `GET /healthz`: liveness probe (200 when alive, 503 when broken)
//! - `GET /readyz`: readiness probe (200 when ready, 503 otherwise)

const std = @import("std");
const net = std.Io.net;
const health_check_mod = @import("../util/health_check.zig");
const testing = std.testing;
pub const HealthCheck = health_check_mod.HealthCheck;

/// Lightweight HTTP probe server for Kubernetes liveness and readiness checks.
///
/// Usage:
/// ```zig
/// var probes = try kube_zig.ProbeServer.init(allocator, io, .{ .port = 8080 });
/// defer probes.deinit(io);
///
/// try probes.addReadinessCheck(mgr.healthCheck());
/// try probes.addLivenessCheck(client.healthCheck());
///
/// try probes.start(io);
/// defer probes.stop(io);
/// ```
pub const ProbeServer = struct {
    allocator: std.mem.Allocator,
    server: net.Server,
    thread: ?std.Thread,
    stop_flag: std.atomic.Value(bool),
    liveness_checks: std.ArrayList(HealthCheck),
    readiness_checks: std.ArrayList(HealthCheck),
    read_timeout_ms: u32,
    closed: bool,

    pub const Options = struct {
        /// TCP port to listen on (default 8080).
        port: u16 = 8080,
        /// Listen address (default "0.0.0.0", all interfaces).
        /// Use "127.0.0.1" to restrict to localhost.
        listen_address: []const u8 = "0.0.0.0",
        /// Read timeout in milliseconds for accepted connections (default 5000).
        /// Prevents slow or stalled clients from blocking the accept loop.
        read_timeout_ms: u32 = 5000,
    };

    /// Bind the TCP listener but do not start accepting yet.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, opts: Options) !ProbeServer {
        const address = try net.IpAddress.parse(opts.listen_address, opts.port);
        const server = try address.listen(io, .{ .reuse_address = true });
        return .{
            .allocator = allocator,
            .server = server,
            .thread = null,
            .stop_flag = std.atomic.Value(bool).init(false),
            .liveness_checks = .empty,
            .readiness_checks = .empty,
            .read_timeout_ms = opts.read_timeout_ms,
            .closed = false,
        };
    }

    /// Register a liveness check. All must return true for /healthz to return 200.
    pub fn addLivenessCheck(self: *ProbeServer, check: HealthCheck) !void {
        try self.liveness_checks.append(self.allocator, check);
    }

    /// Register a readiness check. All must return true for /readyz to return 200.
    pub fn addReadinessCheck(self: *ProbeServer, check: HealthCheck) !void {
        try self.readiness_checks.append(self.allocator, check);
    }

    /// Spawn the background accept-loop thread.
    pub fn start(self: *ProbeServer, io: std.Io) !void {
        self.thread = try std.Thread.spawn(.{}, acceptLoop, .{ self, io });
    }

    /// Signal the accept loop to stop and join the thread.
    pub fn stop(self: *ProbeServer, io: std.Io) void {
        self.stop_flag.store(true, .release);
        // Closing the listening socket causes accept() to fail; the loop
        // checks stop_flag and exits.
        if (!self.closed) {
            self.server.deinit(io);
            self.closed = true;
        }
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    /// Release all resources. Must call stop() first if started.
    pub fn deinit(self: *ProbeServer, io: std.Io) void {
        std.debug.assert(self.thread == null);
        if (!self.closed) {
            self.server.deinit(io);
            self.closed = true;
        }
        self.liveness_checks.deinit(self.allocator);
        self.readiness_checks.deinit(self.allocator);
    }

    fn acceptLoop(self: *ProbeServer, io: std.Io) void {
        while (!self.stop_flag.load(.acquire)) {
            var stream = self.server.accept(io) catch {
                if (self.stop_flag.load(.acquire)) return;
                continue;
            };
            defer stream.close(io);
            setReadTimeout(stream, self.read_timeout_ms);
            self.handleConnection(io, stream);
        }
    }

    /// Set SO_RCVTIMEO on the stream socket. Errors are ignored because
    /// this option is best-effort and may not be supported on all platforms.
    /// std.Io has no equivalent socket-option API in 0.16, so this drops to posix.
    fn setReadTimeout(stream: net.Stream, timeout_ms: u32) void {
        const tv = std.posix.timeval{
            .sec = @intCast(timeout_ms / 1000),
            .usec = @intCast(@as(u32, timeout_ms % 1000) * 1000),
        };
        std.posix.setsockopt(
            stream.socket.handle,
            std.posix.SOL.SOCKET,
            std.posix.SO.RCVTIMEO,
            std.mem.asBytes(&tv),
        ) catch {};
    }

    fn handleConnection(self: *ProbeServer, io: std.Io, stream: net.Stream) void {
        var read_buf: [1024]u8 = undefined;
        var rd = stream.reader(io, &read_buf);

        // Read the request line, terminated by "\r\n". takeDelimiterExclusive
        // returns the bytes up to (not including) the delimiter; we then strip
        // the trailing '\r' if present.
        const line_with_cr = rd.interface.takeDelimiterExclusive('\n') catch return;
        const request_line = if (line_with_cr.len > 0 and line_with_cr[line_with_cr.len - 1] == '\r')
            line_with_cr[0 .. line_with_cr.len - 1]
        else
            line_with_cr;

        var iter = std.mem.splitScalar(u8, request_line, ' ');
        const method = iter.next() orelse return;
        const path = iter.next() orelse return;

        if (!std.mem.eql(u8, method, "GET")) {
            writeResponse(io, stream, "405 Method Not Allowed", "method not allowed\n");
            return;
        }

        if (std.mem.eql(u8, path, "/healthz")) {
            if (runChecks(io, self.liveness_checks.items)) {
                writeResponse(io, stream, "200 OK", "ok\n");
            } else {
                writeResponse(io, stream, "503 Service Unavailable", "not alive\n");
            }
        } else if (std.mem.eql(u8, path, "/readyz")) {
            if (runChecks(io, self.readiness_checks.items)) {
                writeResponse(io, stream, "200 OK", "ok\n");
            } else {
                writeResponse(io, stream, "503 Service Unavailable", "not ready\n");
            }
        } else {
            writeResponse(io, stream, "404 Not Found", "not found\n");
        }
    }

    fn runChecks(io: std.Io, checks: []const HealthCheck) bool {
        for (checks) |check| {
            if (!check.check_fn(check.ctx, io)) return false;
        }
        return true;
    }

    fn writeResponse(io: std.Io, stream: net.Stream, status: []const u8, body: []const u8) void {
        var write_buf: [512]u8 = undefined;
        var wr = stream.writer(io, &write_buf);
        const w = &wr.interface;
        w.print(
            "HTTP/1.1 {s}\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
            .{ status, body.len },
        ) catch return;
        w.writeAll(body) catch return;
        w.flush() catch return;
    }
};

test "init/deinit without start" {
    // Arrange
    const io = std.testing.io;
    var probes = try ProbeServer.init(testing.allocator, io, .{ .port = 0, .listen_address = "127.0.0.1" });

    // Act / Assert
    probes.deinit(io);
}

test "start/stop lifecycle" {
    // Arrange
    const io = std.testing.io;
    var probes = try ProbeServer.init(testing.allocator, io, .{ .port = 0, .listen_address = "127.0.0.1" });

    // Act
    try probes.start(io);

    // Assert
    probes.stop(io);
    probes.deinit(io);
}

const RequestResult = struct { data: [1024]u8, len: usize };

fn sendRequest(io: std.Io, address: net.IpAddress, request: []const u8) !RequestResult {
    var addr = address;
    var stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var write_buf: [256]u8 = undefined;
    var wr = stream.writer(io, &write_buf);
    try wr.interface.writeAll(request);
    try wr.interface.flush();

    var read_buf: [16]u8 = undefined;
    var rd = stream.reader(io, &read_buf);
    var result: RequestResult = undefined;
    var total: usize = 0;
    while (total < result.data.len) {
        const slice = rd.interface.readSliceShort(result.data[total..]) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (slice == 0) break;
        total += slice;
    }
    result.len = total;
    return result;
}

test "probe responses: /healthz 200 no checks" {
    // Arrange
    const io = std.testing.io;
    var probes = try ProbeServer.init(testing.allocator, io, .{ .port = 0, .listen_address = "127.0.0.1" });
    defer probes.deinit(io);
    try probes.start(io);
    defer probes.stop(io);

    // Act
    const result = try sendRequest(io, probes.server.socket.address, "GET /healthz HTTP/1.1\r\nHost: localhost\r\n\r\n");
    const response = result.data[0..result.len];

    // Assert
    try testing.expect(std.mem.indexOf(u8, response, "200 OK") != null);
    try testing.expect(std.mem.indexOf(u8, response, "ok\n") != null);
}

test "probe responses: /readyz 200 no checks" {
    // Arrange
    const io = std.testing.io;
    var probes = try ProbeServer.init(testing.allocator, io, .{ .port = 0, .listen_address = "127.0.0.1" });
    defer probes.deinit(io);
    try probes.start(io);
    defer probes.stop(io);

    // Act
    const result = try sendRequest(io, probes.server.socket.address, "GET /readyz HTTP/1.1\r\nHost: localhost\r\n\r\n");
    const response = result.data[0..result.len];

    // Assert
    try testing.expect(std.mem.indexOf(u8, response, "200 OK") != null);
    try testing.expect(std.mem.indexOf(u8, response, "ok\n") != null);
}

test "probe responses: 404 for unknown path" {
    // Arrange
    const io = std.testing.io;
    var probes = try ProbeServer.init(testing.allocator, io, .{ .port = 0, .listen_address = "127.0.0.1" });
    defer probes.deinit(io);
    try probes.start(io);
    defer probes.stop(io);

    // Act
    const result = try sendRequest(io, probes.server.socket.address, "GET /notfound HTTP/1.1\r\nHost: localhost\r\n\r\n");
    const response = result.data[0..result.len];

    // Assert
    try testing.expect(std.mem.indexOf(u8, response, "404 Not Found") != null);
    try testing.expect(std.mem.indexOf(u8, response, "not found\n") != null);
}

test "failing check returns 503" {
    // Arrange
    const io = std.testing.io;
    var probes = try ProbeServer.init(testing.allocator, io, .{ .port = 0, .listen_address = "127.0.0.1" });
    defer probes.deinit(io);

    // Act
    const Ctx = struct { val: bool };
    var ctx = Ctx{ .val = false };
    try probes.addReadinessCheck(HealthCheck.fromTypedCtx(Ctx, &ctx, struct {
        fn f(c: *Ctx, _: std.Io) bool {
            return c.val;
        }
    }.f));

    // Assert
    try probes.start(io);
    defer probes.stop(io);

    const result = try sendRequest(io, probes.server.socket.address, "GET /readyz HTTP/1.1\r\nHost: localhost\r\n\r\n");
    const response = result.data[0..result.len];

    try testing.expect(std.mem.indexOf(u8, response, "503") != null);
    try testing.expect(std.mem.indexOf(u8, response, "not ready\n") != null);

    const result2 = try sendRequest(io, probes.server.socket.address, "GET /healthz HTTP/1.1\r\nHost: localhost\r\n\r\n");
    const response2 = result2.data[0..result2.len];

    try testing.expect(std.mem.indexOf(u8, response2, "200 OK") != null);
}

test "multiple checks: all must pass" {
    // Arrange
    const io = std.testing.io;
    var probes = try ProbeServer.init(testing.allocator, io, .{ .port = 0, .listen_address = "127.0.0.1" });
    defer probes.deinit(io);

    // Act
    const Ctx = struct { val: bool };
    var ctx1 = Ctx{ .val = true };
    var ctx2 = Ctx{ .val = false };
    try probes.addReadinessCheck(HealthCheck.fromTypedCtx(Ctx, &ctx1, struct {
        fn f(c: *Ctx, _: std.Io) bool {
            return c.val;
        }
    }.f));
    try probes.addReadinessCheck(HealthCheck.fromTypedCtx(Ctx, &ctx2, struct {
        fn f(c: *Ctx, _: std.Io) bool {
            return c.val;
        }
    }.f));

    // Assert
    try probes.start(io);
    defer probes.stop(io);

    const result = try sendRequest(io, probes.server.socket.address, "GET /readyz HTTP/1.1\r\nHost: localhost\r\n\r\n");
    const response = result.data[0..result.len];

    try testing.expect(std.mem.indexOf(u8, response, "503") != null);

    ctx2.val = true;
    const result2 = try sendRequest(io, probes.server.socket.address, "GET /readyz HTTP/1.1\r\nHost: localhost\r\n\r\n");
    const response2 = result2.data[0..result2.len];

    try testing.expect(std.mem.indexOf(u8, response2, "200 OK") != null);
}

test "POST returns 405" {
    // Arrange
    const io = std.testing.io;
    var probes = try ProbeServer.init(testing.allocator, io, .{ .port = 0, .listen_address = "127.0.0.1" });
    defer probes.deinit(io);
    try probes.start(io);
    defer probes.stop(io);

    // Act
    const result = try sendRequest(io, probes.server.socket.address, "POST /healthz HTTP/1.1\r\nHost: localhost\r\n\r\n");
    const response = result.data[0..result.len];

    // Assert
    try testing.expect(std.mem.indexOf(u8, response, "405") != null);
    try testing.expect(std.mem.indexOf(u8, response, "method not allowed\n") != null);
}

test "addLivenessCheck: OOM on allocation does not corrupt server" {
    // Arrange
    const io = std.testing.io;
    var fa = std.testing.FailingAllocator.init(testing.allocator, .{});
    var probes = try ProbeServer.init(fa.allocator(), io, .{ .port = 0, .listen_address = "127.0.0.1" });
    defer probes.deinit(io);

    // Act
    const Ctx = struct { val: bool };
    var ctx = Ctx{ .val = true };
    const check = HealthCheck.fromTypedCtx(Ctx, &ctx, struct {
        fn f(c: *Ctx, _: std.Io) bool {
            return c.val;
        }
    }.f);

    // Assert
    fa.fail_index = fa.alloc_index;

    try testing.expectError(error.OutOfMemory, probes.addLivenessCheck(check));

    try testing.expectEqual(0, probes.liveness_checks.items.len);
}

test "addReadinessCheck: OOM on allocation does not corrupt server" {
    // Arrange
    const io = std.testing.io;
    var fa = std.testing.FailingAllocator.init(testing.allocator, .{});
    var probes = try ProbeServer.init(fa.allocator(), io, .{ .port = 0, .listen_address = "127.0.0.1" });
    defer probes.deinit(io);

    // Act
    const Ctx = struct { val: bool };
    var ctx = Ctx{ .val = true };
    const check = HealthCheck.fromTypedCtx(Ctx, &ctx, struct {
        fn f(c: *Ctx, _: std.Io) bool {
            return c.val;
        }
    }.f);

    // Assert
    fa.fail_index = fa.alloc_index;

    try testing.expectError(error.OutOfMemory, probes.addReadinessCheck(check));

    try testing.expectEqual(0, probes.readiness_checks.items.len);
}
