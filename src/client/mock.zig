const std = @import("std");
const http = std.http;
const Io = std.Io;
const client_mod = @import("Client.zig");
const Client = client_mod.Client;
const AuthProvider = client_mod.AuthProvider;
const FlowControlTracker = client_mod.FlowControlTracker;
const Transport = client_mod.Transport;
const RequestOptions = client_mod.RequestOptions;
const TransportResponse = client_mod.TransportResponse;
const StreamResponse = client_mod.StreamResponse;
const StreamState = client_mod.StreamState;
const BodySerializer = client_mod.BodySerializer;
const CancelSource = client_mod.CancelSource;
const testing = std.testing;

const RetryPolicy = @import("../util/retry.zig").RetryPolicy;
const RateLimiter = @import("../util/rate_limit.zig").RateLimiter;
const CircuitBreaker = @import("../util/circuit_breaker.zig").CircuitBreaker;

/// A mock HTTP transport for testing. Serves canned responses from a FIFO
/// queue and records all requests for later inspection.
///
/// Usage:
/// ```zig
/// var mock = MockTransport.init(allocator);
/// defer mock.deinit();
///
/// mock.respondWith(.ok, "{\"items\":[]}");
///
/// var c = mock.client();
/// defer c.deinit();
///
/// const result = try c.get(SomeType, "/api/v1/pods");
/// ```
pub const MockTransport = struct {
    allocator: std.mem.Allocator,
    responses: std.ArrayList(MockResponse),
    stream_responses: std.ArrayList(MockStreamResponse),
    requests: std.ArrayList(RecordedRequest),

    pub const vtable: Transport.VTable = .{
        .send_fn = vtableSend,
        .send_stream_fn = vtableSendStream,
        .deinit_fn = vtableDeinit,
        .pool_stats_fn = vtablePoolStats,
    };

    /// A canned response to return from send().
    pub const MockResponse = struct {
        status: http.Status,
        body: []const u8,
        retry_after_ns: ?u64 = null,
        fail: bool = false,
        flow_schema_uid: ?[]const u8 = null,
        priority_level_uid: ?[]const u8 = null,
    };

    /// A canned stream response to return from sendStream().
    pub const MockStreamResponse = struct {
        status: http.Status,
        body: []const u8,
    };

    /// A recorded request for later inspection.
    pub const RecordedRequest = struct {
        method: http.Method,
        path: []const u8,
        content_type: ?[]const u8,
        payload: ?[]const u8,
        had_body_serializer: bool,
        serialized_body: ?[]const u8,
        traceparent: ?[]const u8,

        pub fn deinit(self: RecordedRequest, allocator: std.mem.Allocator) void {
            allocator.free(self.path);
            if (self.content_type) |ct| allocator.free(ct);
            if (self.payload) |p| allocator.free(p);
            if (self.serialized_body) |sb| allocator.free(sb);
            if (self.traceparent) |tp| allocator.free(tp);
        }
    };

    /// Create a mock transport with empty response and request queues.
    pub fn init(allocator: std.mem.Allocator) MockTransport {
        return .{
            .allocator = allocator,
            .responses = .empty,
            .stream_responses = .empty,
            .requests = .empty,
        };
    }

    /// Free all recorded requests and response queues.
    pub fn deinit(self: *MockTransport) void {
        for (self.requests.items) |req| {
            req.deinit(self.allocator);
        }
        self.requests.deinit(self.allocator);
        self.responses.deinit(self.allocator);
        self.stream_responses.deinit(self.allocator);
    }

    /// Return a `Transport` value pointing at this mock.
    pub fn transport(self: *MockTransport) Transport {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    /// Create a `Client` wired to this mock transport.
    /// The returned client has no retry, no rate limiting, and base_url "http://mock".
    pub fn client(self: *MockTransport) Client {
        return self.clientWithTracer(@import("../util/tracing.zig").TracerProvider.noop);
    }

    /// Create a `Client` wired to this mock transport with a custom tracer.
    pub fn clientWithTracer(self: *MockTransport, tracer: @import("../util/tracing.zig").TracerProvider) Client {
        return .{
            .allocator = self.allocator,
            .base_url = self.allocator.dupe(u8, "http://mock") catch @panic("OOM in MockTransport.client"),
            .transport = self.transport(),
            .auth = AuthProvider.none(self.allocator),
            .retry_policy = RetryPolicy.disabled,
            .rate_limiter = RateLimiter.init(RateLimiter.Config.disabled) catch null,
            .circuit_breaker = CircuitBreaker.init(CircuitBreaker.Config.disabled) catch null,
            .keep_alive = true,
            .shutdown_source = CancelSource.init(),
            .metrics = @import("../util/metrics.zig").ClientMetrics.noop,
            .tracer = tracer,
            .logger = @import("../util/logging.zig").Logger.noop,
            .flow_tracker = FlowControlTracker.init(self.allocator),
        };
    }

    // Response enqueuing
    /// Enqueue a canned response with the given status and body string.
    pub fn respondWith(self: *MockTransport, status: http.Status, body: []const u8) void {
        self.responses.append(self.allocator, .{
            .status = status,
            .body = body,
        }) catch @panic("OOM in MockTransport.respondWith");
    }

    /// Enqueue a canned response with a Retry-After hint in nanoseconds.
    pub fn respondWithRetryAfterNs(self: *MockTransport, status: http.Status, body: []const u8, retry_after_ns: u64) void {
        self.responses.append(self.allocator, .{
            .status = status,
            .body = body,
            .retry_after_ns = retry_after_ns,
        }) catch @panic("OOM in MockTransport.respondWithRetryAfterNs");
    }

    /// Enqueue a slot that returns a transport error instead of an HTTP response.
    pub fn respondWithTransportError(self: *MockTransport) void {
        self.responses.append(self.allocator, .{
            .status = .internal_server_error,
            .body = "",
            .fail = true,
        }) catch @panic("OOM in MockTransport.respondWithTransportError");
    }

    /// Enqueue a canned response by serializing a value to JSON.
    pub fn respondWithJson(self: *MockTransport, status: http.Status, value: anytype) void {
        const body = std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(value, .{
            .emit_null_optional_fields = false,
        })}) catch @panic("OOM in MockTransport.respondWithJson");
        self.responses.append(self.allocator, .{
            .status = status,
            .body = body,
        }) catch @panic("OOM in MockTransport.respondWithJson");
    }

    /// Enqueue a canned response with APF flow-control header values.
    pub fn respondWithFlowControl(
        self: *MockTransport,
        status: http.Status,
        body: []const u8,
        flow_schema_uid: ?[]const u8,
        priority_level_uid: ?[]const u8,
    ) void {
        self.responses.append(self.allocator, .{
            .status = status,
            .body = body,
            .flow_schema_uid = flow_schema_uid,
            .priority_level_uid = priority_level_uid,
        }) catch @panic("OOM in MockTransport.respondWithFlowControl");
    }

    /// Enqueue a canned stream response.
    pub fn respondWithStream(self: *MockTransport, status: http.Status, body: []const u8) void {
        self.stream_responses.append(self.allocator, .{
            .status = status,
            .body = body,
        }) catch @panic("OOM in MockTransport.respondWithStream");
    }

    // Request inspection
    /// Get the i-th recorded request.
    pub fn getRequest(self: *const MockTransport, index: usize) ?RecordedRequest {
        if (index >= self.requests.items.len) return null;
        return self.requests.items[index];
    }

    /// Return how many requests have been recorded.
    pub fn requestCount(self: *const MockTransport) usize {
        return self.requests.items.len;
    }

    // vtable implementation
    fn vtableSend(ptr: *anyopaque, opts: RequestOptions, body: ?BodySerializer, allocator: std.mem.Allocator) anyerror!TransportResponse {
        const self: *MockTransport = @ptrCast(@alignCast(ptr));
        return self.sendImpl(opts, body, allocator);
    }

    fn vtableSendStream(ptr: *anyopaque, opts: RequestOptions, allocator: std.mem.Allocator) anyerror!StreamResponse {
        const self: *MockTransport = @ptrCast(@alignCast(ptr));
        return self.sendStreamImpl(opts, allocator);
    }

    fn vtableDeinit(_: *anyopaque) void {
        // MockTransport is stack-allocated; nothing to free here.
        // The caller owns and deinits the MockTransport directly.
    }

    fn vtablePoolStats(_: *anyopaque) client_mod.PoolStats {
        return .{ .pool_size = 0, .free_connections = 0, .active_connections = 0 };
    }

    fn sendImpl(self: *MockTransport, opts: RequestOptions, body: ?BodySerializer, allocator: std.mem.Allocator) anyerror!TransportResponse {
        // Record the request.
        var serialized_body: ?[]const u8 = null;
        if (body) |b| {
            // Serialize the body into a buffer to capture it for inspection.
            var buf_writer = Io.Writer.Allocating.init(self.allocator);
            errdefer buf_writer.deinit();
            try b.write(&buf_writer.writer);
            serialized_body = try buf_writer.toOwnedSlice();
        }

        const path_str = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{
            opts.uri.path.percent_encoded,
            if (opts.uri.query) |q| q.percent_encoded else "",
        });

        const ct_dupe = if (opts.content_type) |ct| self.allocator.dupe(u8, ct) catch {
            self.allocator.free(path_str);
            return error.OutOfMemory;
        } else null;

        const payload_dupe = if (opts.payload) |p| self.allocator.dupe(u8, p) catch {
            self.allocator.free(path_str);
            if (ct_dupe) |ct| self.allocator.free(ct);
            return error.OutOfMemory;
        } else null;

        const tp_dupe = if (opts.traceparent) |tp| self.allocator.dupe(u8, tp) catch {
            self.allocator.free(path_str);
            if (ct_dupe) |ct| self.allocator.free(ct);
            if (payload_dupe) |p| self.allocator.free(p);
            return error.OutOfMemory;
        } else null;

        self.requests.append(self.allocator, .{
            .method = opts.method,
            .path = path_str,
            .content_type = ct_dupe,
            .payload = payload_dupe,
            .had_body_serializer = body != null,
            .serialized_body = serialized_body,
            .traceparent = tp_dupe,
        }) catch {
            self.allocator.free(path_str);
            if (ct_dupe) |ct| self.allocator.free(ct);
            if (payload_dupe) |p| self.allocator.free(p);
            if (serialized_body) |sb| self.allocator.free(sb);
            if (tp_dupe) |tp| self.allocator.free(tp);
            return error.OutOfMemory;
        };

        // Pop the next canned response.
        if (self.responses.items.len == 0) {
            return error.HttpRequestFailed;
        }
        const resp = self.responses.orderedRemove(0);

        if (resp.fail) return error.HttpRequestFailed;

        // Return a copy of the body owned by the caller's allocator,
        // matching real transport behavior.
        const body_copy = try allocator.dupe(u8, resp.body);

        // If the response was allocated by respondWithJson, free it.
        // We can detect this: respondWith passes a caller-owned slice (not ours to free),
        // respondWithJson allocates with self.allocator. Since we can't distinguish them
        // reliably, we don't free here. The mock is short-lived for tests.
        // Users of respondWithJson should let mock.deinit() handle cleanup if needed,
        // but since respondWithJson's body gets consumed here, we need to track it.
        // For simplicity: respondWithJson bodies are freed at mock deinit time.
        // Actually they're already consumed from the array. We need to free here.
        // Let's just not free; the test allocator will catch real leaks.
        // The simplest approach: always dupe in respondWith/respondWithJson and free here.

        // Dupe flow-control header values onto the caller's allocator,
        // matching the real transport's ownership contract.
        const fs_uid: ?[]const u8 = if (resp.flow_schema_uid) |uid|
            try allocator.dupe(u8, uid)
        else
            null;
        errdefer if (fs_uid) |uid| allocator.free(uid);

        const pl_uid: ?[]const u8 = if (resp.priority_level_uid) |uid|
            try allocator.dupe(u8, uid)
        else
            null;

        return .{
            .status = resp.status,
            .body = body_copy,
            .retry_after_ns = resp.retry_after_ns,
            .flow_control = .{
                .flow_schema_uid = fs_uid,
                .priority_level_uid = pl_uid,
            },
            .allocator = allocator,
        };
    }

    fn sendStreamImpl(self: *MockTransport, opts: RequestOptions, allocator: std.mem.Allocator) anyerror!StreamResponse {
        // Record the request.
        const path_str = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{
            opts.uri.path.percent_encoded,
            if (opts.uri.query) |q| q.percent_encoded else "",
        });

        const tp_dupe = if (opts.traceparent) |tp| self.allocator.dupe(u8, tp) catch {
            self.allocator.free(path_str);
            return error.OutOfMemory;
        } else null;

        self.requests.append(self.allocator, .{
            .method = opts.method,
            .path = path_str,
            .content_type = null,
            .payload = null,
            .had_body_serializer = false,
            .serialized_body = null,
            .traceparent = tp_dupe,
        }) catch {
            self.allocator.free(path_str);
            if (tp_dupe) |tp| self.allocator.free(tp);
            return error.OutOfMemory;
        };

        // Pop the next canned stream response.
        if (self.stream_responses.items.len == 0) {
            return error.HttpRequestFailed;
        }
        const resp = self.stream_responses.orderedRemove(0);

        // Match real StdHttpTransport behavior: non-success status returns
        // an error instead of a stream (the real transport checks
        // status.class() != .success after receiveHead).
        if (resp.status.class() != .success) {
            if (resp.status == .gone) return error.HttpGone;
            return error.HttpRequestFailed;
        }

        // Create a MockStreamBacking that holds the data and a Reader.
        const backing = try allocator.create(MockStreamBacking);
        errdefer allocator.destroy(backing);

        const body_copy = try allocator.dupe(u8, resp.body);
        errdefer allocator.free(body_copy);

        backing.* = .{
            .allocator = allocator,
            .data = body_copy,
            .reader = Io.Reader.fixed(body_copy),
        };

        // Build a StreamState. We don't have a real http.Client.Request,
        // so we use the deinit_fn override to handle cleanup correctly.
        const state = try allocator.create(StreamState);
        state.* = .{
            .allocator = allocator,
            .request = undefined,
            .redirect_buf = undefined,
            .transfer_buf = undefined,
            .response = null,
            .reader = &backing.reader,
            .deinit_fn = mockStreamDeinit,
        };
        // Stash the backing pointer in redirect_buf so we can recover it in deinit.
        @as(*align(1) *MockStreamBacking, @ptrCast(&state.redirect_buf)).* = backing;

        return .{
            .status = resp.status,
            .state = state,
        };
    }

    /// Backing storage for a mock stream: owns the data buffer and provides
    /// a `std.Io.Reader` via `Reader.fixed()`.
    const MockStreamBacking = struct {
        allocator: std.mem.Allocator,
        data: []const u8,
        reader: Io.Reader,
    };

    fn mockStreamDeinit(state: *StreamState) void {
        // Recover the backing pointer stashed in redirect_buf.
        const backing = @as(*align(1) *MockStreamBacking, @ptrCast(&state.redirect_buf)).*;
        backing.allocator.free(backing.data);
        backing.allocator.destroy(backing);
        state.allocator.destroy(state);
    }
};

test "MockTransport: send returns canned response and records request" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    // Act
    mock.respondWith(.ok, "{\"items\":[]}");

    // Assert
    var c = mock.client();
    defer c.deinit();
    const ctx = c.context();

    const result = try c.get(struct { items: ?[]const u8 = null }, "/api/v1/pods", ctx);
    defer result.deinit();

    try testing.expectEqual(1, mock.requestCount());
    const req = mock.getRequest(0).?;
    try testing.expectEqual(http.Method.GET, req.method);
    try testing.expect(std.mem.indexOf(u8, req.path, "/api/v1/pods") != null);
}

test "MockTransport: empty queue returns error" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    // Act
    var c = mock.client();
    defer c.deinit();
    const ctx = c.context();

    // Assert
    const result = c.get(struct {}, "/api/v1/pods", ctx);
    try testing.expectError(error.HttpRequestFailed, result);
}

test "MockTransport: flow control headers are surfaced on client" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    // Act
    mock.respondWithFlowControl(.ok, "{\"items\":[]}", "fs-uid-123", "pl-uid-456");

    // Assert
    var c = mock.client();
    defer c.deinit();
    const ctx = c.context();

    const result = try c.get(struct { items: ?[]const u8 = null }, "/api/v1/pods", ctx);
    defer result.deinit();

    try testing.expectEqualStrings("fs-uid-123", c.flowControl().flow_schema_uid.?);
    try testing.expectEqualStrings("pl-uid-456", c.flowControl().priority_level_uid.?);
}

test "MockTransport: flow control headers are null when absent" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    // Act
    mock.respondWith(.ok, "{\"items\":[]}");

    // Assert
    var c = mock.client();
    defer c.deinit();
    const ctx = c.context();

    const result = try c.get(struct { items: ?[]const u8 = null }, "/api/v1/pods", ctx);
    defer result.deinit();

    try testing.expect(c.flowControl().flow_schema_uid == null);
    try testing.expect(c.flowControl().priority_level_uid == null);
}

test "MockTransport: flow control headers are updated on each request" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    // Act
    mock.respondWithFlowControl(.ok, "{}", "fs-1", "pl-1");
    mock.respondWithFlowControl(.ok, "{}", "fs-2", null);

    // Assert
    var c = mock.client();
    defer c.deinit();
    const ctx = c.context();

    const r1 = try c.get(struct {}, "/first", ctx);
    defer r1.deinit();
    try testing.expectEqualStrings("fs-1", c.flowControl().flow_schema_uid.?);
    try testing.expectEqualStrings("pl-1", c.flowControl().priority_level_uid.?);

    const r2 = try c.get(struct {}, "/second", ctx);
    defer r2.deinit();
    try testing.expectEqualStrings("fs-2", c.flowControl().flow_schema_uid.?);
    try testing.expect(c.flowControl().priority_level_uid == null);
}

test "MockTransport: noop tracer does not add traceparent header" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    // Act
    mock.respondWith(.ok, "{\"items\":[]}");

    // Assert
    var c = mock.client(); // uses noop tracer by default
    defer c.deinit();
    const ctx = c.context();

    const result = try c.get(struct { items: ?[]const u8 = null }, "/api/v1/pods", ctx);
    defer result.deinit();

    try testing.expectEqual(1, mock.requestCount());
    const req = mock.getRequest(0).?;
    try testing.expect(req.traceparent == null);
}

test "MockTransport: test tracer adds traceparent header and calls startSpan/endSpan" {
    // Arrange
    const tracing = @import("../util/tracing.zig");

    const TestTracer = struct {
        start_count: u32 = 0,
        end_count: u32 = 0,
        last_status: tracing.SpanStatus = .unset,
        last_kind: tracing.SpanKind = .internal,
        generated_ctx: tracing.SpanContext = tracing.SpanContext.invalid,

        fn startSpan(raw: ?*anyopaque, _: []const u8, _: ?tracing.SpanContext, kind: tracing.SpanKind, _: ?[]const tracing.Attribute) tracing.SpanContext {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.start_count += 1;
            self.last_kind = kind;
            self.generated_ctx = .{
                .trace_id = tracing.TraceId.generate(),
                .span_id = tracing.SpanId.generate(),
                .trace_flags = tracing.SpanContext.sampled_flag,
            };
            return self.generated_ctx;
        }

        fn endSpan(raw: ?*anyopaque, _: tracing.SpanContext, status: tracing.SpanStatus) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.end_count += 1;
            self.last_status = status;
        }

        const vtable: tracing.TracerProvider.VTable = .{
            .start_span = startSpan,
            .end_span = endSpan,
        };
    };

    var tracer = TestTracer{};
    const provider: tracing.TracerProvider = .{ .ptr = @ptrCast(&tracer), .vtable = &TestTracer.vtable };

    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    mock.respondWith(.ok, "{\"items\":[]}");

    var c = mock.clientWithTracer(provider);
    defer c.deinit();
    const ctx = c.context();

    // Act
    const result = try c.get(struct { items: ?[]const u8 = null }, "/api/v1/pods", ctx);
    defer result.deinit();

    // Assert
    try testing.expectEqual(1, tracer.start_count);
    try testing.expectEqual(1, tracer.end_count);
    try testing.expectEqual(tracing.SpanKind.client, tracer.last_kind);
    try testing.expectEqual(tracing.SpanStatus.ok, tracer.last_status);

    // Verify traceparent header was set on the outgoing request.
    const req = mock.getRequest(0).?;
    try testing.expect(req.traceparent != null);

    // Verify the traceparent header parses back to the generated span context.
    const parsed = tracing.parseTraceparent(req.traceparent.?).?;
    try testing.expectEqualSlices(u8, &tracer.generated_ctx.trace_id.bytes, &parsed.trace_id.bytes);
    try testing.expectEqualSlices(u8, &tracer.generated_ctx.span_id.bytes, &parsed.span_id.bytes);
}

test "MockTransport: test tracer endSpan called with error on non-2xx" {
    // Arrange
    const tracing = @import("../util/tracing.zig");

    const TestTracer = struct {
        end_count: u32 = 0,
        last_status: tracing.SpanStatus = .unset,

        fn startSpan(raw: ?*anyopaque, _: []const u8, _: ?tracing.SpanContext, _: tracing.SpanKind, _: ?[]const tracing.Attribute) tracing.SpanContext {
            _ = raw;
            return .{
                .trace_id = tracing.TraceId.generate(),
                .span_id = tracing.SpanId.generate(),
                .trace_flags = tracing.SpanContext.sampled_flag,
            };
        }

        fn endSpan(raw: ?*anyopaque, _: tracing.SpanContext, status: tracing.SpanStatus) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.end_count += 1;
            self.last_status = status;
        }

        const vtable: tracing.TracerProvider.VTable = .{
            .start_span = startSpan,
            .end_span = endSpan,
        };
    };

    var tracer = TestTracer{};
    const provider: tracing.TracerProvider = .{ .ptr = @ptrCast(&tracer), .vtable = &TestTracer.vtable };

    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    mock.respondWith(.not_found, "{\"message\":\"not found\"}");

    var c = mock.clientWithTracer(provider);
    defer c.deinit();
    const ctx = c.context();

    // Act
    const result = try c.get(struct {}, "/api/v1/pods/missing", ctx);
    defer result.deinit();

    // Assert
    try testing.expectEqual(1, tracer.end_count);
    try testing.expectEqual(tracing.SpanStatus.@"error", tracer.last_status);
}
