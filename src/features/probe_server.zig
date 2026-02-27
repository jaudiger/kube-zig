const std = @import("std");
const health_check_mod = @import("../util/health_check.zig");
const testing = std.testing;
pub const HealthCheck = health_check_mod.HealthCheck;

/// Lightweight HTTP probe server for Kubernetes liveness and readiness checks.
///
/// Listens on a configurable TCP port and serves two endpoints:
/// - `GET /healthz`: liveness probe (200 when alive, 503 when broken)
/// - `GET /readyz`: readiness probe (200 when ready, 503 otherwise)
///
/// Usage:
/// ```zig
/// const kube_zig = @import("kube-zig");
///
/// var mgr = kube_zig.ControllerManager.init(allocator, .{});
/// // ... add controllers ...
///
/// var probes = try kube_zig.ProbeServer.init(allocator, .{ .port = 8080 });
/// defer probes.deinit();
///
/// try probes.addReadinessCheck(mgr.healthCheck());
/// try probes.addLivenessCheck(client.healthCheck());
///
/// try probes.start();
/// defer probes.stop();
///
/// try mgr.run();
/// ```
pub const ProbeServer = struct {
    allocator: std.mem.Allocator,
    server: std.net.Server,
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
    pub fn init(allocator: std.mem.Allocator, opts: Options) !ProbeServer {
        const address = try std.net.Address.resolveIp(opts.listen_address, opts.port);
        const server = try address.listen(.{ .reuse_address = true });
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
    pub fn start(self: *ProbeServer) !void {
        self.thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
    }

    /// Signal the accept loop to stop and join the thread.
    pub fn stop(self: *ProbeServer) void {
        self.stop_flag.store(true, .release);
        if (!self.closed) {
            self.server.deinit();
            self.closed = true;
        }
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    /// Release all resources. Must call stop() first if started.
    pub fn deinit(self: *ProbeServer) void {
        std.debug.assert(self.thread == null);
        if (!self.closed) {
            self.server.deinit();
            self.closed = true;
        }
        self.liveness_checks.deinit(self.allocator);
        self.readiness_checks.deinit(self.allocator);
    }

    // Accept loop
    fn acceptLoop(self: *ProbeServer) void {
        while (!self.stop_flag.load(.acquire)) {
            const conn = self.server.accept() catch {
                if (self.stop_flag.load(.acquire)) break;
                continue;
            };
            defer conn.stream.close();
            setReadTimeout(conn.stream, self.read_timeout_ms);
            self.handleConnection(conn.stream);
        }
    }

    /// Set SO_RCVTIMEO on the stream socket. Errors are ignored because
    /// this option is best-effort and may not be supported on all platforms.
    fn setReadTimeout(stream: std.net.Stream, timeout_ms: u32) void {
        const tv = std.c.timeval{
            .sec = @intCast(timeout_ms / 1000),
            .usec = @intCast(@as(u32, timeout_ms % 1000) * 1000),
        };
        std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
    }

    fn handleConnection(self: *ProbeServer, stream: std.net.Stream) void {
        var buf: [1024]u8 = undefined;
        var total: usize = 0;

        // Read until the request line terminator is found or the buffer is full.
        while (total < buf.len) {
            const n = stream.read(buf[total..]) catch return;
            if (n == 0) break;
            total += n;
            if (std.mem.indexOf(u8, buf[0..total], "\r\n") != null) break;
        }
        if (total == 0) return;

        const request = buf[0..total];

        // Parse request line: "GET /healthz HTTP/1.1\r\n..."
        const line_end = std.mem.indexOf(u8, request, "\r\n") orelse return;
        const request_line = request[0..line_end];

        // Split into method and path.
        var iter = std.mem.splitScalar(u8, request_line, ' ');
        const method = iter.next() orelse return;
        const path = iter.next() orelse return;

        // Only GET is supported.
        if (!std.mem.eql(u8, method, "GET")) {
            writeResponse(stream, "405 Method Not Allowed", "method not allowed\n");
            return;
        }

        if (std.mem.eql(u8, path, "/healthz")) {
            if (runChecks(self.liveness_checks.items)) {
                writeResponse(stream, "200 OK", "ok\n");
            } else {
                writeResponse(stream, "503 Service Unavailable", "not alive\n");
            }
        } else if (std.mem.eql(u8, path, "/readyz")) {
            if (runChecks(self.readiness_checks.items)) {
                writeResponse(stream, "200 OK", "ok\n");
            } else {
                writeResponse(stream, "503 Service Unavailable", "not ready\n");
            }
        } else {
            writeResponse(stream, "404 Not Found", "not found\n");
        }
    }

    fn runChecks(checks: []const HealthCheck) bool {
        for (checks) |check| {
            if (!check.check_fn(check.ctx)) return false;
        }
        return true;
    }

    fn writeResponse(stream: std.net.Stream, status: []const u8, body: []const u8) void {
        var header_buf: [256]u8 = undefined;
        const header = std.fmt.bufPrint(
            &header_buf,
            "HTTP/1.1 {s}\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
            .{ status, body.len },
        ) catch return;
        stream.writeAll(header) catch return;
        stream.writeAll(body) catch return;
    }
};

test "init/deinit without start" {
    // Arrange
    var probes = try ProbeServer.init(testing.allocator, .{ .port = 0, .listen_address = "127.0.0.1" });

    // Act / Assert
    probes.deinit();
}

test "start/stop lifecycle" {
    // Arrange
    var probes = try ProbeServer.init(testing.allocator, .{ .port = 0, .listen_address = "127.0.0.1" });

    // Act
    try probes.start();

    // Assert
    probes.stop();
    probes.deinit();
}

fn sendRequest(address: std.net.Address, request: []const u8) !struct { data: [1024]u8, len: usize } {
    const stream = try std.net.tcpConnectToAddress(address);
    defer stream.close();
    try stream.writeAll(request);
    var result: struct { data: [1024]u8, len: usize } = undefined;
    result.len = try stream.read(&result.data);
    return result;
}

test "probe responses: /healthz 200 no checks" {
    // Arrange
    var probes = try ProbeServer.init(testing.allocator, .{ .port = 0, .listen_address = "127.0.0.1" });
    defer probes.deinit();
    try probes.start();
    defer probes.stop();

    // Act
    const result = try sendRequest(probes.server.listen_address, "GET /healthz HTTP/1.1\r\nHost: localhost\r\n\r\n");
    const response = result.data[0..result.len];

    // Assert
    try testing.expect(std.mem.indexOf(u8, response, "200 OK") != null);
    try testing.expect(std.mem.indexOf(u8, response, "ok\n") != null);
}

test "probe responses: /readyz 200 no checks" {
    // Arrange
    var probes = try ProbeServer.init(testing.allocator, .{ .port = 0, .listen_address = "127.0.0.1" });
    defer probes.deinit();
    try probes.start();
    defer probes.stop();

    // Act
    const result = try sendRequest(probes.server.listen_address, "GET /readyz HTTP/1.1\r\nHost: localhost\r\n\r\n");
    const response = result.data[0..result.len];

    // Assert
    try testing.expect(std.mem.indexOf(u8, response, "200 OK") != null);
    try testing.expect(std.mem.indexOf(u8, response, "ok\n") != null);
}

test "probe responses: 404 for unknown path" {
    // Arrange
    var probes = try ProbeServer.init(testing.allocator, .{ .port = 0, .listen_address = "127.0.0.1" });
    defer probes.deinit();
    try probes.start();
    defer probes.stop();

    // Act
    const result = try sendRequest(probes.server.listen_address, "GET /notfound HTTP/1.1\r\nHost: localhost\r\n\r\n");
    const response = result.data[0..result.len];

    // Assert
    try testing.expect(std.mem.indexOf(u8, response, "404 Not Found") != null);
    try testing.expect(std.mem.indexOf(u8, response, "not found\n") != null);
}

test "failing check returns 503" {
    // Arrange
    var probes = try ProbeServer.init(testing.allocator, .{ .port = 0, .listen_address = "127.0.0.1" });
    defer probes.deinit();

    // Act
    const Ctx = struct { val: bool };
    var ctx = Ctx{ .val = false };
    try probes.addReadinessCheck(HealthCheck.fromTypedCtx(Ctx, &ctx, struct {
        fn f(c: *Ctx) bool {
            return c.val;
        }
    }.f));

    // Assert
    try probes.start();
    defer probes.stop();

    const result = try sendRequest(probes.server.listen_address, "GET /readyz HTTP/1.1\r\nHost: localhost\r\n\r\n");
    const response = result.data[0..result.len];

    try testing.expect(std.mem.indexOf(u8, response, "503") != null);
    try testing.expect(std.mem.indexOf(u8, response, "not ready\n") != null);

    const result2 = try sendRequest(probes.server.listen_address, "GET /healthz HTTP/1.1\r\nHost: localhost\r\n\r\n");
    const response2 = result2.data[0..result2.len];

    try testing.expect(std.mem.indexOf(u8, response2, "200 OK") != null);
}

test "multiple checks: all must pass" {
    // Arrange
    var probes = try ProbeServer.init(testing.allocator, .{ .port = 0, .listen_address = "127.0.0.1" });
    defer probes.deinit();

    // Act
    const Ctx = struct { val: bool };
    var ctx1 = Ctx{ .val = true };
    var ctx2 = Ctx{ .val = false };
    try probes.addReadinessCheck(HealthCheck.fromTypedCtx(Ctx, &ctx1, struct {
        fn f(c: *Ctx) bool {
            return c.val;
        }
    }.f));
    try probes.addReadinessCheck(HealthCheck.fromTypedCtx(Ctx, &ctx2, struct {
        fn f(c: *Ctx) bool {
            return c.val;
        }
    }.f));

    // Assert
    try probes.start();
    defer probes.stop();

    const result = try sendRequest(probes.server.listen_address, "GET /readyz HTTP/1.1\r\nHost: localhost\r\n\r\n");
    const response = result.data[0..result.len];

    try testing.expect(std.mem.indexOf(u8, response, "503") != null);

    ctx2.val = true;
    const result2 = try sendRequest(probes.server.listen_address, "GET /readyz HTTP/1.1\r\nHost: localhost\r\n\r\n");
    const response2 = result2.data[0..result2.len];

    try testing.expect(std.mem.indexOf(u8, response2, "200 OK") != null);
}

test "POST returns 405" {
    // Arrange
    var probes = try ProbeServer.init(testing.allocator, .{ .port = 0, .listen_address = "127.0.0.1" });
    defer probes.deinit();
    try probes.start();
    defer probes.stop();

    // Act
    const result = try sendRequest(probes.server.listen_address, "POST /healthz HTTP/1.1\r\nHost: localhost\r\n\r\n");
    const response = result.data[0..result.len];

    // Assert
    try testing.expect(std.mem.indexOf(u8, response, "405") != null);
    try testing.expect(std.mem.indexOf(u8, response, "method not allowed\n") != null);
}

test "fragmented request: split across multiple reads" {
    // Arrange
    var probes = try ProbeServer.init(testing.allocator, .{ .port = 0, .listen_address = "127.0.0.1" });
    defer probes.deinit();
    try probes.start();
    defer probes.stop();

    // Act
    const stream = try std.net.tcpConnectToAddress(probes.server.listen_address);
    defer stream.close();
    try stream.writeAll("GET /he");
    std.Thread.sleep(10 * std.time.ns_per_ms);
    try stream.writeAll("althz HTTP/1.1\r\nHost: localhost\r\n\r\n");
    var result_data: [1024]u8 = undefined;
    const result_len = try stream.read(&result_data);
    const response = result_data[0..result_len];

    // Assert
    try testing.expect(std.mem.indexOf(u8, response, "200 OK") != null);
    try testing.expect(std.mem.indexOf(u8, response, "ok\n") != null);
}

test "slow client: read timeout unblocks accept loop" {
    // Arrange
    var probes = try ProbeServer.init(testing.allocator, .{
        .port = 0,
        .listen_address = "127.0.0.1",
        .read_timeout_ms = 100,
    });
    defer probes.deinit();
    try probes.start();
    defer probes.stop();

    // Act: connect a client that sends nothing (stalls).
    const stalling = try std.net.tcpConnectToAddress(probes.server.listen_address);
    defer stalling.close();

    // After the read timeout expires, the server should accept the next connection.
    std.Thread.sleep(200 * std.time.ns_per_ms);
    const result = try sendRequest(probes.server.listen_address, "GET /healthz HTTP/1.1\r\nHost: localhost\r\n\r\n");
    const response = result.data[0..result.len];

    // Assert
    try testing.expect(std.mem.indexOf(u8, response, "200 OK") != null);
}

test "addLivenessCheck: OOM on allocation does not corrupt server" {
    // Arrange
    var fa = std.testing.FailingAllocator.init(testing.allocator, .{});
    var probes = try ProbeServer.init(fa.allocator(), .{ .port = 0, .listen_address = "127.0.0.1" });
    defer probes.deinit();

    // Act
    const Ctx = struct { val: bool };
    var ctx = Ctx{ .val = true };
    const check = HealthCheck.fromTypedCtx(Ctx, &ctx, struct {
        fn f(c: *Ctx) bool {
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
    var fa = std.testing.FailingAllocator.init(testing.allocator, .{});
    var probes = try ProbeServer.init(fa.allocator(), .{ .port = 0, .listen_address = "127.0.0.1" });
    defer probes.deinit();

    // Act
    const Ctx = struct { val: bool };
    var ctx = Ctx{ .val = true };
    const check = HealthCheck.fromTypedCtx(Ctx, &ctx, struct {
        fn f(c: *Ctx) bool {
            return c.val;
        }
    }.f);

    // Assert
    fa.fail_index = fa.alloc_index;

    try testing.expectError(error.OutOfMemory, probes.addReadinessCheck(check));

    try testing.expectEqual(0, probes.readiness_checks.items.len);
}
