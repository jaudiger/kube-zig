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
const TransportError = Client.TransportError;
const StreamTransportError = Client.StreamTransportError;

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
/// var c = mock.client(io);
/// defer c.deinit(io);
///
/// const result = try c.get(io, SomeType, "/api/v1/pods", ctx);
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
    /// When `fail_error` is set, sendImpl returns that error instead of an
    /// HTTP response; `status` and `body` are ignored.
    /// When `body_owned` is true, the body slice was allocated by this mock
    /// and will be freed when the response is consumed or the mock is deinited.
    pub const MockResponse = struct {
        status: http.Status,
        body: []const u8,
        retry_after_ns: ?u64 = null,
        fail_error: ?TransportError = null,
        flow_schema_uid: ?[]const u8 = null,
        priority_level_uid: ?[]const u8 = null,
        body_owned: bool = false,

        pub fn deinit(self: MockResponse, allocator: std.mem.Allocator) void {
            if (self.body_owned) allocator.free(self.body);
        }
    };

    /// A canned stream response to return from sendStream().
    /// When `body_owned` is true, the body slice will be freed when consumed.
    pub const MockStreamResponse = struct {
        status: http.Status,
        body: []const u8,
        body_owned: bool = false,

        pub fn deinit(self: MockStreamResponse, allocator: std.mem.Allocator) void {
            if (self.body_owned) allocator.free(self.body);
        }
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
        deadline_ns: ?i128,

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
        for (self.responses.items) |resp| resp.deinit(self.allocator);
        self.responses.deinit(self.allocator);
        for (self.stream_responses.items) |resp| resp.deinit(self.allocator);
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
    pub fn client(self: *MockTransport, io: std.Io) error{OutOfMemory}!Client {
        return self.clientWithTracer(io, @import("../util/tracing.zig").TracerProvider.noop);
    }

    /// Create a `Client` wired to this mock transport with a custom tracer.
    pub fn clientWithTracer(self: *MockTransport, io: std.Io, tracer: @import("../util/tracing.zig").TracerProvider) error{OutOfMemory}!Client {
        return .{
            .allocator = self.allocator,
            .base_url = try self.allocator.dupe(u8, "http://mock"),
            .transport = self.transport(),
            .auth = AuthProvider.none(self.allocator),
            .retry_policy = RetryPolicy.disabled,
            .rate_limiter = RateLimiter.init(io, RateLimiter.Config.disabled) catch null,
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
    pub fn respondWith(self: *MockTransport, status: http.Status, body: []const u8) error{OutOfMemory}!void {
        try self.responses.append(self.allocator, .{
            .status = status,
            .body = body,
        });
    }

    /// Enqueue a canned response with a Retry-After hint in nanoseconds.
    pub fn respondWithRetryAfterNs(self: *MockTransport, status: http.Status, body: []const u8, retry_after_ns: u64) error{OutOfMemory}!void {
        try self.responses.append(self.allocator, .{
            .status = status,
            .body = body,
            .retry_after_ns = retry_after_ns,
        });
    }

    /// Enqueue a slot that returns a generic `HttpRequestFailed` error.
    pub fn respondWithTransportError(self: *MockTransport) error{OutOfMemory}!void {
        return self.respondWithTransportErrorKind(error.HttpRequestFailed);
    }

    /// Enqueue a slot that returns the given transport error.
    pub fn respondWithTransportErrorKind(self: *MockTransport, err: TransportError) error{OutOfMemory}!void {
        try self.responses.append(self.allocator, .{
            .status = .internal_server_error,
            .body = "",
            .fail_error = err,
        });
    }

    /// Enqueue a canned response by serializing a value to JSON.
    pub fn respondWithJson(self: *MockTransport, status: http.Status, value: anytype) error{OutOfMemory}!void {
        const body = try std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(value, .{
            .emit_null_optional_fields = false,
        })});
        errdefer self.allocator.free(body);
        try self.responses.append(self.allocator, .{
            .status = status,
            .body = body,
            .body_owned = true,
        });
    }

    /// Enqueue a canned response with APF flow-control header values.
    pub fn respondWithFlowControl(
        self: *MockTransport,
        status: http.Status,
        body: []const u8,
        flow_schema_uid: ?[]const u8,
        priority_level_uid: ?[]const u8,
    ) error{OutOfMemory}!void {
        try self.responses.append(self.allocator, .{
            .status = status,
            .body = body,
            .flow_schema_uid = flow_schema_uid,
            .priority_level_uid = priority_level_uid,
        });
    }

    /// Enqueue a canned stream response.
    pub fn respondWithStream(self: *MockTransport, status: http.Status, body: []const u8) error{OutOfMemory}!void {
        try self.stream_responses.append(self.allocator, .{
            .status = status,
            .body = body,
        });
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
    fn vtableSend(ptr: *anyopaque, _: std.Io, opts: RequestOptions, body: ?BodySerializer, allocator: std.mem.Allocator) TransportError!TransportResponse {
        const self: *MockTransport = @ptrCast(@alignCast(ptr));
        return self.sendImpl(opts, body, allocator);
    }

    fn vtableSendStream(ptr: *anyopaque, _: std.Io, opts: RequestOptions, allocator: std.mem.Allocator) StreamTransportError!StreamResponse {
        const self: *MockTransport = @ptrCast(@alignCast(ptr));
        return self.sendStreamImpl(opts, allocator);
    }

    fn vtableDeinit(_: *anyopaque, _: std.Io) void {
        // MockTransport is stack-allocated; nothing to free here.
        // The caller owns and deinits the MockTransport directly.
    }

    fn vtablePoolStats(_: *anyopaque, _: std.Io) client_mod.PoolStats {
        return .{ .pool_size = 0, .free_connections = 0, .active_connections = 0 };
    }

    fn sendImpl(self: *MockTransport, opts: RequestOptions, body: ?BodySerializer, allocator: std.mem.Allocator) TransportError!TransportResponse {
        // Record the request.
        var serialized_body: ?[]const u8 = null;
        if (body) |b| {
            // Serialize the body into a buffer to capture it for inspection.
            var buf_writer = Io.Writer.Allocating.init(self.allocator);
            errdefer buf_writer.deinit();
            b.write(&buf_writer.writer) catch return error.ConnectionResetByPeer;
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
            .deadline_ns = opts.deadline_ns,
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

        if (resp.fail_error) |e| return e;

        // Return a copy of the body owned by the caller's allocator,
        // matching real transport behavior.
        const body_copy = try allocator.dupe(u8, resp.body);
        errdefer allocator.free(body_copy);
        // Free the body if it was allocated by respondWithJson.
        if (resp.body_owned) self.allocator.free(resp.body);

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
        errdefer if (pl_uid) |uid| allocator.free(uid);

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

    fn sendStreamImpl(self: *MockTransport, opts: RequestOptions, allocator: std.mem.Allocator) StreamTransportError!StreamResponse {
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
            .deadline_ns = opts.deadline_ns,
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
            if (resp.body_owned) self.allocator.free(resp.body);
            if (resp.status == .gone) return error.HttpGone;
            return error.HttpRequestFailed;
        }

        // Create a MockStreamBacking that holds the data and a Reader.
        const backing = try allocator.create(MockStreamBacking);
        errdefer allocator.destroy(backing);

        const body_copy = try allocator.dupe(u8, resp.body);
        errdefer allocator.free(body_copy);
        if (resp.body_owned) self.allocator.free(resp.body);

        backing.* = .{
            .allocator = allocator,
            .data = body_copy,
            .reader = Io.Reader.fixed(body_copy),
        };

        // Build a StreamState. We don't have a real http.Client.Request,
        // so we use deinit_fn and extra to handle cleanup correctly.
        const state = try allocator.create(StreamState);
        state.* = .{
            .allocator = allocator,
            .request = undefined,
            .redirect_buf = undefined,
            .transfer_buf = undefined,
            .response = null,
            .reader = &backing.reader,
            .deinit_fn = mockStreamDeinit,
            // extra holds the backing pointer; redirect_buf is left undefined
            // because deinit_fn shadows the default cleanup that would touch it.
            .extra = @ptrCast(backing),
        };

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
        const backing: *MockStreamBacking = @ptrCast(@alignCast(state.extra.?));
        backing.allocator.free(backing.data);
        backing.allocator.destroy(backing);
        state.allocator.destroy(state);
    }
};

test "MockTransport: send returns canned response and records request" {
    // Arrange
    const io = std.testing.io;
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    // Act
    try mock.respondWith(.ok, "{\"items\":[]}");

    // Assert
    var c = try mock.client(io);
    defer c.deinit(io);
    const ctx = c.context();

    const result = try c.get(io, struct { items: ?[]const u8 = null }, "/api/v1/pods", ctx);
    defer result.deinit();

    try testing.expectEqual(1, mock.requestCount());
    const req = mock.getRequest(0).?;
    try testing.expectEqual(http.Method.GET, req.method);
    try testing.expect(std.mem.find(u8, req.path, "/api/v1/pods") != null);
}

test "MockTransport: empty queue returns error" {
    // Arrange
    const io = std.testing.io;
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    // Act
    var c = try mock.client(io);
    defer c.deinit(io);
    const ctx = c.context();

    // Assert
    const result = c.get(io, struct {}, "/api/v1/pods", ctx);
    try testing.expectError(error.HttpRequestFailed, result);
}

test "MockTransport: flow control headers are surfaced on client" {
    // Arrange
    const io = std.testing.io;
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    // Act
    try mock.respondWithFlowControl(.ok, "{\"items\":[]}", "fs-uid-123", "pl-uid-456");

    // Assert
    var c = try mock.client(io);
    defer c.deinit(io);
    const ctx = c.context();

    const result = try c.get(io, struct { items: ?[]const u8 = null }, "/api/v1/pods", ctx);
    defer result.deinit();

    const fc1 = try c.flowControl(testing.allocator, io);
    defer fc1.deinit();
    try testing.expectEqualStrings("fs-uid-123", fc1.flow_schema_uid.?);
    try testing.expectEqualStrings("pl-uid-456", fc1.priority_level_uid.?);
}

test "MockTransport: flow control headers are null when absent" {
    // Arrange
    const io = std.testing.io;
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    // Act
    try mock.respondWith(.ok, "{\"items\":[]}");

    // Assert
    var c = try mock.client(io);
    defer c.deinit(io);
    const ctx = c.context();

    const result = try c.get(io, struct { items: ?[]const u8 = null }, "/api/v1/pods", ctx);
    defer result.deinit();

    const fc = try c.flowControl(testing.allocator, io);
    defer fc.deinit();
    try testing.expect(fc.flow_schema_uid == null);
    try testing.expect(fc.priority_level_uid == null);
}

test "MockTransport: flow control headers are updated on each request" {
    // Arrange
    const io = std.testing.io;
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    // Act
    try mock.respondWithFlowControl(.ok, "{}", "fs-1", "pl-1");
    try mock.respondWithFlowControl(.ok, "{}", "fs-2", null);

    // Assert
    var c = try mock.client(io);
    defer c.deinit(io);
    const ctx = c.context();

    const r1 = try c.get(io, struct {}, "/first", ctx);
    defer r1.deinit();
    const fc1 = try c.flowControl(testing.allocator, io);
    defer fc1.deinit();
    try testing.expectEqualStrings("fs-1", fc1.flow_schema_uid.?);
    try testing.expectEqualStrings("pl-1", fc1.priority_level_uid.?);

    const r2 = try c.get(io, struct {}, "/second", ctx);
    defer r2.deinit();
    const fc2 = try c.flowControl(testing.allocator, io);
    defer fc2.deinit();
    try testing.expectEqualStrings("fs-2", fc2.flow_schema_uid.?);
    try testing.expect(fc2.priority_level_uid == null);
}

test "MockTransport: noop tracer does not add traceparent header" {
    // Arrange
    const io = std.testing.io;
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    // Act
    try mock.respondWith(.ok, "{\"items\":[]}");

    // Assert
    var c = try mock.client(io); // uses noop tracer by default
    defer c.deinit(io);
    const ctx = c.context();

    const result = try c.get(io, struct { items: ?[]const u8 = null }, "/api/v1/pods", ctx);
    defer result.deinit();

    try testing.expectEqual(1, mock.requestCount());
    const req = mock.getRequest(0).?;
    try testing.expect(req.traceparent == null);
}

test "MockTransport: test tracer adds traceparent header and calls startSpan/endSpan" {
    // Arrange
    const io = std.testing.io;
    const tracing = @import("../util/tracing.zig");

    const TestTracer = struct {
        start_count: u32 = 0,
        end_count: u32 = 0,
        last_status: tracing.SpanStatus = .unset,
        last_kind: tracing.SpanKind = .internal,
        generated_ctx: tracing.SpanContext = tracing.SpanContext.invalid,
        io: std.Io,

        fn startSpan(raw: ?*anyopaque, _: []const u8, _: ?tracing.SpanContext, kind: tracing.SpanKind, _: ?[]const tracing.Attribute) tracing.SpanContext {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.start_count += 1;
            self.last_kind = kind;
            self.generated_ctx = .{
                .trace_id = tracing.TraceId.generate(self.io),
                .span_id = tracing.SpanId.generate(self.io),
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

    var tracer = TestTracer{ .io = io };
    const provider: tracing.TracerProvider = .{ .ptr = @ptrCast(&tracer), .vtable = &TestTracer.vtable };

    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    try mock.respondWith(.ok, "{\"items\":[]}");

    var c = try mock.clientWithTracer(io, provider);
    defer c.deinit(io);
    const ctx = c.context();

    // Act
    const result = try c.get(io, struct { items: ?[]const u8 = null }, "/api/v1/pods", ctx);
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
    const io = std.testing.io;
    const tracing = @import("../util/tracing.zig");

    const TestTracer = struct {
        end_count: u32 = 0,
        last_status: tracing.SpanStatus = .unset,
        io: std.Io,

        fn startSpan(raw: ?*anyopaque, _: []const u8, _: ?tracing.SpanContext, _: tracing.SpanKind, _: ?[]const tracing.Attribute) tracing.SpanContext {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return .{
                .trace_id = tracing.TraceId.generate(self.io),
                .span_id = tracing.SpanId.generate(self.io),
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

    var tracer = TestTracer{ .io = io };
    const provider: tracing.TracerProvider = .{ .ptr = @ptrCast(&tracer), .vtable = &TestTracer.vtable };

    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    try mock.respondWith(.not_found, "{\"message\":\"not found\"}");

    var c = try mock.clientWithTracer(io, provider);
    defer c.deinit(io);
    const ctx = c.context();

    // Act
    const result = try c.get(io, struct {}, "/api/v1/pods/missing", ctx);
    defer result.deinit();

    // Assert
    try testing.expectEqual(1, tracer.end_count);
    try testing.expectEqual(tracing.SpanStatus.@"error", tracer.last_status);
}
