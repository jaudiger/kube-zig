//! HTTP client for communicating with a Kubernetes API server.
//!
//! Provides a `Client` struct that dispatches HTTP requests through a runtime
//! `Transport` vtable, supporting real HTTP, mocks, and custom transports.
//! Includes retry with exponential backoff, rate limiting, circuit breaking,
//! distributed tracing, and API Priority and Fairness flow-control tracking.

const std = @import("std");
const builtin = @import("builtin");
const HealthCheck = @import("../util/health_check.zig").HealthCheck;
const native_os = builtin.os.tag;
const http = std.http;
const Uri = std.Uri;
const InClusterConfig = @import("incluster.zig").InClusterConfig;
const retry_mod = @import("../util/retry.zig");
const RetryPolicy = retry_mod.RetryPolicy;
const rate_limit_mod = @import("../util/rate_limit.zig");
const RateLimiter = rate_limit_mod.RateLimiter;
const circuit_breaker_mod = @import("../util/circuit_breaker.zig");
const CircuitBreaker = circuit_breaker_mod.CircuitBreaker;
const metrics_mod = @import("../util/metrics.zig");
const ClientMetrics = metrics_mod.ClientMetrics;
const ClientMetricsFactory = ClientMetrics.Factory;
const tracing_mod = @import("../util/tracing.zig");
const TracerProvider = tracing_mod.TracerProvider;
const SpanContext = tracing_mod.SpanContext;
const logging_mod = @import("../util/logging.zig");
const Logger = logging_mod.Logger;
const LogField = logging_mod.Field;
const auth_mod = @import("auth.zig");
const testing = std.testing;
pub const AuthProvider = auth_mod.AuthProvider;
const flow_control_mod = @import("flow_control.zig");
pub const FlowControl = flow_control_mod.FlowControl;
pub const FlowControlTracker = flow_control_mod.FlowControlTracker;
const context_mod = @import("../util/context.zig");
pub const Context = context_mod.Context;
pub const CancelSource = context_mod.CancelSource;

// Transport interface
/// Request options passed from the client to the transport layer.
/// Contains the HTTP method, URI, headers, and optional payload.
pub const RequestOptions = struct {
    method: http.Method,
    uri: Uri,
    content_type: ?[]const u8 = null,
    accept: ?[]const u8 = null,
    auth_header: ?[]const u8 = null,
    traceparent: ?[]const u8 = null,
    keep_alive: bool = true,
    payload: ?[]const u8 = null,
};

/// Response returned by the transport layer.
///
/// The `flow_control` string fields and `body` are heap-allocated via
/// `allocator`. Call `takeBody()` to extract the body with ownership
/// transfer; `deinit()` frees any remaining allocations including an
/// untaken body.
pub const TransportResponse = struct {
    status: http.Status,
    body: ?[]const u8 = null,
    retry_after_ns: ?u64 = null,
    flow_control: FlowControl = .{},
    allocator: ?std.mem.Allocator = null,

    /// Extract and take ownership of the response body.
    /// After this call, `body` is null and `deinit()` will not free it.
    /// Panics if body is already null.
    pub fn takeBody(self: *TransportResponse) []const u8 {
        const b = self.body orelse unreachable;
        self.body = null;
        return b;
    }

    /// Free heap-allocated response data: flow-control header copies and
    /// body (if not already extracted via `takeBody()`).
    pub fn deinit(self: TransportResponse) void {
        const alloc = self.allocator orelse return;
        if (self.body) |b| alloc.free(b);
        if (self.flow_control.flow_schema_uid) |uid| alloc.free(uid);
        if (self.flow_control.priority_level_uid) |uid| alloc.free(uid);
    }
};

/// Connection pool statistics for observability.
pub const PoolStats = struct {
    pool_size: u32,
    free_connections: u32,
    active_connections: u32,
};

/// Type-erased body serializer for streaming JSON to a transport writer.
/// Created by Client methods like `postValue`/`putValue` to avoid pushing
/// comptime type parameters into the transport layer.
pub const BodySerializer = struct {
    context: *const anyopaque,
    writeFn: *const fn (context: *const anyopaque, writer: *std.Io.Writer) anyerror!void,

    /// Serialize the body to the given writer.
    pub fn write(self: BodySerializer, writer: *std.Io.Writer) anyerror!void {
        return self.writeFn(self.context, writer);
    }
};

/// Heap-allocated state that keeps an HTTP connection alive for streaming reads.
/// Owns the `Request` and its associated buffers so their addresses remain stable.
///
/// When `deinit_fn` is set (e.g. by `MockTransport`), it is called instead of
/// the default cleanup, enabling stream mocking without a real HTTP connection.
pub const StreamState = struct {
    allocator: std.mem.Allocator,
    request: http.Client.Request,
    redirect_buf: [8 * 1024]u8,
    transfer_buf: [8192]u8,
    response: ?http.Client.Response,
    reader: ?*std.Io.Reader,
    deinit_fn: ?*const fn (*StreamState) void = null,

    /// Release the stream state and its underlying HTTP connection.
    /// Delegates to `deinit_fn` when set (e.g. by mock transports).
    pub fn deinit(self: *StreamState) void {
        if (self.deinit_fn) |f| {
            f(self);
            return;
        }
        self.request.deinit();
        self.allocator.destroy(self);
    }

    /// Shut down the underlying socket, causing any blocked `read()` to
    /// return immediately.  Safe to call from another thread because the fd
    /// remains valid for the owning thread's subsequent `deinit()`.
    pub fn interrupt(self: *StreamState) void {
        if (self.request.connection) |conn| {
            const fd = conn.stream_writer.getStream().handle;
            std.posix.shutdown(fd, .both) catch {};
        }
    }
};

/// Response from a streaming transport request.
pub const StreamResponse = struct {
    status: http.Status,
    state: *StreamState,
};

/// Runtime transport vtable, following the `std.mem.Allocator` pattern.
/// Allows the `Client` to dispatch HTTP operations through any transport
/// implementation (real HTTP, mock, etc.) via a single indirect call.
pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        send_fn: *const fn (
            ptr: *anyopaque,
            opts: RequestOptions,
            body: ?BodySerializer,
            allocator: std.mem.Allocator,
        ) anyerror!TransportResponse,
        send_stream_fn: *const fn (
            ptr: *anyopaque,
            opts: RequestOptions,
            allocator: std.mem.Allocator,
        ) anyerror!StreamResponse,
        deinit_fn: *const fn (ptr: *anyopaque) void,
        pool_stats_fn: ?*const fn (ptr: *anyopaque) PoolStats = null,
    };

    /// Send a request and return the full response.
    pub fn send(self: Transport, opts: RequestOptions, body: ?BodySerializer, allocator: std.mem.Allocator) anyerror!TransportResponse {
        return self.vtable.send_fn(self.ptr, opts, body, allocator);
    }

    /// Open a streaming connection and return a `StreamResponse`.
    pub fn sendStream(self: Transport, opts: RequestOptions, allocator: std.mem.Allocator) anyerror!StreamResponse {
        return self.vtable.send_stream_fn(self.ptr, opts, allocator);
    }

    /// Release the transport and its resources.
    pub fn deinit(self: Transport) void {
        self.vtable.deinit_fn(self.ptr);
    }

    /// Return connection pool statistics, if supported by this transport.
    pub fn poolStats(self: Transport) ?PoolStats {
        if (self.vtable.pool_stats_fn) |f| return f(self.ptr);
        return null;
    }
};

/// Standard HTTP transport using `std.http.Client`.
pub const StdHttpTransport = struct {
    http_client: http.Client,
    read_timeout_ms: ?u32 = null,
    write_timeout_ms: ?u32 = null,
    watch_read_timeout_ms: ?u32 = null,
    tcp_keepalive: bool = true,
    tcp_keepalive_idle_s: ?u32 = null,
    tcp_keepalive_interval_s: ?u32 = null,
    tcp_keepalive_count: ?u32 = null,
    max_response_bytes: usize = 128 * 1024 * 1024,
    logger: Logger = Logger.noop,
    /// The allocator used to heap-allocate this transport (for self-freeing in deinit).
    self_allocator: ?std.mem.Allocator = null,

    pub const vtable: Transport.VTable = .{
        .send_fn = vtableSend,
        .send_stream_fn = vtableSendStream,
        .deinit_fn = vtableDeinit,
        .pool_stats_fn = vtablePoolStats,
    };

    /// Return a `Transport` value pointing at this instance.
    pub fn transport(self: *StdHttpTransport) Transport {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    fn vtableSend(ptr: *anyopaque, opts: RequestOptions, body: ?BodySerializer, allocator: std.mem.Allocator) anyerror!TransportResponse {
        const self: *StdHttpTransport = @ptrCast(@alignCast(ptr));
        return self.sendImpl(opts, body, allocator);
    }

    fn vtableSendStream(ptr: *anyopaque, opts: RequestOptions, allocator: std.mem.Allocator) anyerror!StreamResponse {
        const self: *StdHttpTransport = @ptrCast(@alignCast(ptr));
        return self.sendStreamImpl(opts, allocator);
    }

    fn vtableDeinit(ptr: *anyopaque) void {
        const self: *StdHttpTransport = @ptrCast(@alignCast(ptr));
        self.http_client.deinit();
        if (self.self_allocator) |alloc| {
            alloc.destroy(self);
        }
    }

    fn vtablePoolStats(ptr: *anyopaque) PoolStats {
        const self: *StdHttpTransport = @ptrCast(@alignCast(ptr));
        self.http_client.connection_pool.mutex.lock();
        defer self.http_client.connection_pool.mutex.unlock();
        var active: u32 = 0;
        var node = self.http_client.connection_pool.used.first;
        while (node) |n| : (node = n.next) {
            active += 1;
        }
        return .{
            .pool_size = @intCast(self.http_client.connection_pool.free_size),
            .free_connections = @intCast(self.http_client.connection_pool.free_len),
            .active_connections = active,
        };
    }

    fn sendImpl(self: *StdHttpTransport, opts: RequestOptions, body: ?BodySerializer, allocator: std.mem.Allocator) !TransportResponse {
        const has_body = opts.payload != null or body != null;
        const accept_header = std.http.Header{ .name = "Accept", .value = opts.accept orelse "application/json" };
        const traceparent_header = std.http.Header{ .name = "traceparent", .value = opts.traceparent orelse "" };
        const extra_with_tp = [_]std.http.Header{ accept_header, traceparent_header };
        const extra_without_tp = [_]std.http.Header{accept_header};
        var req = try self.http_client.request(opts.method, opts.uri, .{
            .keep_alive = opts.keep_alive,
            .headers = if (has_body) .{
                .content_type = .{ .override = opts.content_type orelse "application/json" },
            } else .{},
            .extra_headers = if (opts.traceparent != null)
                &extra_with_tp
            else
                &extra_without_tp,
            .privileged_headers = if (opts.auth_header) |ah|
                &.{.{ .name = "Authorization", .value = ah }}
            else
                &.{},
        });
        defer req.deinit();

        self.configureSocket(&req);

        if (body) |b| {
            // Streaming body via BodySerializer: use chunked transfer encoding.
            req.transfer_encoding = .chunked;
            var body_buf: [1024]u8 = undefined;
            var body_writer = try req.sendBodyUnflushed(&body_buf);
            // Serialization writes to the HTTP body stream. Any failure,
            // whether from the serializer or the underlying socket, is
            // surfaced as a connection error since the request is unrecoverable.
            b.write(&body_writer.writer) catch
                return error.ConnectionResetByPeer;
            try body_writer.end();
            if (req.connection) |conn| try conn.flush();
        } else if (opts.payload) |p| {
            req.transfer_encoding = .{ .content_length = p.len };
            var body_buf: [1024]u8 = undefined;
            var body_writer = try req.sendBodyUnflushed(&body_buf);
            try body_writer.writer.writeAll(p);
            try body_writer.end();
            if (req.connection) |conn| try conn.flush();
        } else {
            try req.sendBodiless();
        }

        return self.receiveResponse(&req, allocator);
    }

    fn sendStreamImpl(self: *StdHttpTransport, opts: RequestOptions, allocator: std.mem.Allocator) !StreamResponse {
        const state = try allocator.create(StreamState);
        errdefer allocator.destroy(state);

        state.* = .{
            .allocator = allocator,
            .request = try self.http_client.request(opts.method, opts.uri, .{
                .keep_alive = false,
                .extra_headers = &.{
                    .{ .name = "Accept", .value = opts.accept orelse "application/json" },
                },
                .privileged_headers = if (opts.auth_header) |ah|
                    &.{.{ .name = "Authorization", .value = ah }}
                else
                    &.{},
            }),
            .redirect_buf = undefined,
            .transfer_buf = undefined,
            .response = null,
            .reader = null,
        };
        errdefer state.request.deinit();

        self.configureSocket(&state.request);

        // Apply watch-specific read timeout (safety net for shutdown).
        const watch_timeout = self.watch_read_timeout_ms orelse self.read_timeout_ms;
        if (watch_timeout) |ms| {
            if (state.request.connection) |conn| {
                const fd = conn.stream_writer.getStream().handle;
                const tv = std.c.timeval{
                    .sec = @intCast(ms / 1000),
                    .usec = @intCast(@as(u32, ms % 1000) * 1000),
                };
                std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {
                    self.logger.warn("setsockopt SO_RCVTIMEO (watch) failed", &.{});
                };
            }
        }

        try state.request.sendBodiless();

        state.response = try state.request.receiveHead(&state.redirect_buf);

        if (state.response.?.head.status.class() != .success) {
            // Return the error and let errdefer handle cleanup of
            // state.request and state itself. Do NOT manually deinit
            // here, as that would double-free when the errdefers fire.
            if (state.response.?.head.status == .gone) return error.HttpGone;
            return error.HttpRequestFailed;
        }

        state.reader = state.response.?.reader(&state.transfer_buf);

        return .{
            .status = state.response.?.head.status,
            .state = state,
        };
    }

    fn receiveResponse(self: *StdHttpTransport, req: *http.Client.Request, allocator: std.mem.Allocator) !TransportResponse {
        var redirect_buf: [8 * 1024]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);

        const retry_after_ns: ?u64 = if (response.head.status.class() != .success) blk: {
            break :blk if (retry_mod.findRetryAfterInBytes(response.head.bytes)) |ra_value|
                retry_mod.parseRetryAfterNs(ra_value)
            else
                null;
        } else null;

        // Extract APF flow-control headers (Kubernetes 1.29+).
        // Dupe the header values onto the heap because the originals live in the
        // stack-local `redirect_buf` which is gone after this function returns.
        const fs_uid: ?[]const u8 = if (findHeaderInBytes(response.head.bytes, "x-kubernetes-pf-flowschema-uid:")) |raw|
            try allocator.dupe(u8, raw)
        else
            null;
        errdefer if (fs_uid) |uid| allocator.free(uid);

        const pl_uid: ?[]const u8 = if (findHeaderInBytes(response.head.bytes, "x-kubernetes-pf-prioritylevel-uid:")) |raw|
            try allocator.dupe(u8, raw)
        else
            null;
        errdefer if (pl_uid) |uid| allocator.free(uid);

        var transfer_buf: [8192]u8 = undefined;
        // Workaround: Zig 0.15.x std.http.Method.responseHasBody() incorrectly
        // returns false for PUT, causing Response.reader() to return an EOF
        // reader that discards the response body. Temporarily override the
        // method for the reader() call so the body is read normally.
        const needs_put_fixup = req.method == .PUT;
        if (needs_put_fixup) req.method = .GET;
        const reader = response.reader(&transfer_buf);
        if (needs_put_fixup) req.method = .PUT;
        const resp_body = try reader.allocRemaining(allocator, std.Io.Limit.limited(self.max_response_bytes));

        // Detect if the response was truncated by the limit. If we read
        // exactly max_response_bytes, check whether the server had more
        // data. A truncated body would cause a confusing JsonParseFailed
        // error downstream, so surface a clear error instead.
        if (resp_body.len == self.max_response_bytes) {
            allocator.free(resp_body);
            return error.ResponseTooLarge;
        }

        return .{
            .status = response.head.status,
            .body = resp_body,
            .retry_after_ns = retry_after_ns,
            .flow_control = .{
                .flow_schema_uid = fs_uid,
                .priority_level_uid = pl_uid,
            },
            .allocator = allocator,
        };
    }

    /// Release the HTTP client and, if heap-allocated, free the transport itself.
    pub fn deinit(self: *StdHttpTransport) void {
        self.http_client.deinit();
        if (self.self_allocator) |alloc| {
            alloc.destroy(self);
        }
    }

    // Socket configuration
    // TCP idle time option name differs by platform.
    const TCP_KEEPIDLE_OPTION: u32 = if (native_os.isDarwin())
        std.posix.TCP.KEEPALIVE
    else if (@hasDecl(std.posix.TCP, "KEEPIDLE"))
        std.posix.TCP.KEEPIDLE
    else
        0;

    /// Configure socket-level options (timeouts, keepalive).
    /// These options are best-effort and may not be supported on all
    /// platforms; failures are logged as warnings rather than propagated.
    fn configureSocket(self: *StdHttpTransport, req: *http.Client.Request) void {
        const conn = req.connection orelse return;
        const fd = conn.stream_writer.getStream().handle;

        if (self.read_timeout_ms) |ms| {
            const tv = std.c.timeval{
                .sec = @intCast(ms / 1000),
                .usec = @intCast(@as(u32, ms % 1000) * 1000),
            };
            std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {
                self.logger.warn("setsockopt SO_RCVTIMEO failed", &.{});
            };
        }

        if (self.write_timeout_ms) |ms| {
            const tv = std.c.timeval{
                .sec = @intCast(ms / 1000),
                .usec = @intCast(@as(u32, ms % 1000) * 1000),
            };
            std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&tv)) catch {
                self.logger.warn("setsockopt SO_SNDTIMEO failed", &.{});
            };
        }

        if (self.tcp_keepalive) {
            const enable = std.mem.toBytes(@as(c_int, 1));
            std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.KEEPALIVE, &enable) catch {
                self.logger.warn("setsockopt SO_KEEPALIVE failed", &.{});
            };
        }

        if (self.tcp_keepalive_idle_s) |secs| {
            if (TCP_KEEPIDLE_OPTION != 0) {
                const val = std.mem.toBytes(@as(c_int, @intCast(secs)));
                std.posix.setsockopt(fd, std.posix.IPPROTO.TCP, TCP_KEEPIDLE_OPTION, &val) catch {
                    self.logger.warn("setsockopt TCP_KEEPIDLE failed", &.{});
                };
            }
        }

        if (self.tcp_keepalive_interval_s) |secs| {
            if (@hasDecl(std.posix.TCP, "KEEPINTVL")) {
                const val = std.mem.toBytes(@as(c_int, @intCast(secs)));
                std.posix.setsockopt(fd, std.posix.IPPROTO.TCP, std.posix.TCP.KEEPINTVL, &val) catch {
                    self.logger.warn("setsockopt TCP_KEEPINTVL failed", &.{});
                };
            }
        }

        if (self.tcp_keepalive_count) |count| {
            if (@hasDecl(std.posix.TCP, "KEEPCNT")) {
                const val = std.mem.toBytes(@as(c_int, @intCast(count)));
                std.posix.setsockopt(fd, std.posix.IPPROTO.TCP, std.posix.TCP.KEEPCNT, &val) catch {
                    self.logger.warn("setsockopt TCP_KEEPCNT failed", &.{});
                };
            }
        }
    }
};

/// Search raw HTTP header bytes for a named header value (case-insensitive).
/// `needle` must be lower-case and include the trailing colon, e.g. "x-foo:".
fn findHeaderInBytes(bytes: []const u8, needle: []const u8) ?[]const u8 {
    std.debug.assert(needle.len > 0 and needle[needle.len - 1] == ':');
    for (needle) |c| std.debug.assert(!std.ascii.isUpper(c));
    var it = std.mem.splitSequence(u8, bytes, "\r\n");
    _ = it.next(); // skip status line
    while (it.next()) |line| {
        if (line.len == 0) break;
        if (line.len < needle.len) continue;
        if (std.ascii.eqlIgnoreCase(line[0..needle.len], needle)) {
            return std.mem.trim(u8, line[needle.len..], " \t");
        }
    }
    return null;
}

// Client
/// HTTP/HTTPS client for talking to a Kubernetes API server.
///
/// Uses a runtime `Transport` vtable for HTTP dispatch, following the
/// `std.mem.Allocator` pattern (ptr + *const VTable). This allows the
/// same `Client` type to work with real HTTP, mocks, or any custom transport.
///
/// Two construction modes for production use:
/// - `init`: plain HTTP (e.g. via `kubectl proxy` on localhost).
/// - `initInCluster`: HTTPS with TLS + service-account bearer token.
///
/// For testing, use `MockTransport.client()` from `client/mock.zig`.
pub const Client = struct {
    allocator: std.mem.Allocator,
    base_url: []const u8,
    transport: Transport,
    auth: AuthProvider,
    retry_policy: RetryPolicy,
    rate_limiter: ?RateLimiter,
    circuit_breaker: ?CircuitBreaker,
    keep_alive: bool,
    shutdown_source: CancelSource,
    metrics: ClientMetrics,
    tracer: TracerProvider,
    logger: Logger,
    flow_tracker: FlowControlTracker,

    /// Options for configuring Client behavior.
    pub const ClientOptions = struct {
        /// Retry policy for transient failures (default: 3 retries with exponential backoff).
        retry: RetryPolicy = .{},
        /// Token-bucket rate limiter config (default: 5 QPS, burst 10).
        rate_limit: RateLimiter.Config = .{},
        /// Circuit breaker config (default: 5 failures, 30s recovery).
        circuit_breaker: CircuitBreaker.Config = .{},
        /// Maximum number of idle (keep-alive) connections cached for reuse.
        /// Active in-flight connections are not limited by this setting.
        /// `null` uses the std.http default (32).
        pool_size: ?u32 = null,
        /// Maximum response body size in bytes (default: 128 MiB).
        max_response_bytes: usize = 128 * 1024 * 1024,
        /// Read timeout in milliseconds. `null` uses the OS default.
        read_timeout_ms: ?u32 = null,
        /// Write timeout in milliseconds. `null` uses the OS default.
        write_timeout_ms: ?u32 = null,
        /// Read timeout in milliseconds for watch (streaming) connections.
        /// Can act as a safety net for graceful shutdown: if socket interrupt
        /// fails, the blocked read will time out after this duration.
        /// Default: `null` (no watch-specific timeout; falls back to `read_timeout_ms`).
        watch_read_timeout_ms: ?u32 = null,
        /// Enable HTTP keep-alive on connections (default: true).
        keep_alive: bool = true,
        /// Enable TCP keep-alive probes (default: true).
        tcp_keepalive: bool = true,
        /// Idle time in seconds before the first TCP keep-alive probe. `null` uses the OS default.
        tcp_keepalive_idle_s: ?u32 = null,
        /// Interval in seconds between TCP keep-alive probes. `null` uses the OS default.
        tcp_keepalive_interval_s: ?u32 = null,
        /// Number of unacknowledged TCP keep-alive probes before dropping the connection. `null` uses the OS default.
        tcp_keepalive_count: ?u32 = null,
        /// Metrics factory for HTTP client observability hooks. Default is no-op.
        metrics: ClientMetricsFactory = ClientMetricsFactory.noop,
        /// Tracer provider for distributed tracing. Default is no-op.
        tracer: TracerProvider = TracerProvider.noop,
        /// Structured logger. Default is no-op.
        logger: Logger = Logger.noop,

        /// Options that disable all production-hardening features.
        pub const none: ClientOptions = .{
            .retry = RetryPolicy.disabled,
            .rate_limit = RateLimiter.Config.disabled,
            .circuit_breaker = CircuitBreaker.Config.disabled,
            .pool_size = null,
            .max_response_bytes = 128 * 1024 * 1024,
            .read_timeout_ms = null,
            .write_timeout_ms = null,
            .watch_read_timeout_ms = null,
            .keep_alive = true,
            .tcp_keepalive = true,
        };
    };

    /// Error set for HTTP status codes returned by the Kubernetes API server.
    pub const ApiRequestError = error{
        HttpBadRequest,
        HttpUnauthorized,
        HttpForbidden,
        HttpNotFound,
        HttpConflict,
        HttpUnprocessableEntity,
        HttpTooManyRequests,
        HttpBadGateway,
        HttpServiceUnavailable,
        HttpGatewayTimeout,
        HttpServerError,
        HttpUnexpectedStatus,
        Canceled,
    };

    /// Errors from the network/HTTP transport layer.
    pub const TransportError = error{
        OutOfMemory,
        ConnectionRefused,
        ConnectionResetByPeer,
        ConnectionTimedOut,
        TemporaryNameServerFailure,
        TlsFailure,
        HttpRequestFailed,
        ResponseTooLarge,
    };

    /// Errors from JSON response parsing.
    pub const ParseError = error{
        OutOfMemory,
        JsonParseFailed,
    };

    /// Complete error set for client request methods (transport + parse + cancellation + circuit breaker).
    /// API-level errors (4xx/5xx) are returned via `ApiResult` rather than this set.
    pub const RequestError = TransportError || ParseError || error{ Canceled, CircuitBreakerOpen };

    /// Minimal Kubernetes Status object for error response parsing.
    pub const KubeStatus = struct {
        message: ?[]const u8 = null,
        reason: ?[]const u8 = null,
        code: ?i32 = null,
    };

    /// Captured API error response with HTTP status and body.
    pub const ApiErrorResponse = struct {
        status: http.Status,
        body: []const u8,
        allocator: std.mem.Allocator,

        /// Map the HTTP status to an `ApiRequestError`.
        pub fn statusError(self: ApiErrorResponse) ApiRequestError {
            return statusToError(self.status);
        }

        /// Try to parse the response body as a Kubernetes Status object.
        pub fn parseStatus(self: ApiErrorResponse) ?std.json.Parsed(KubeStatus) {
            return std.json.parseFromSlice(KubeStatus, self.allocator, self.body, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            }) catch null;
        }

        /// Free the heap-allocated response body.
        pub fn deinit(self: ApiErrorResponse) void {
            self.allocator.free(self.body);
        }
    };

    /// Result type for API operations. On success, contains the parsed value.
    /// On API-level error (4xx/5xx), contains the error response details.
    pub fn ApiResult(comptime T: type) type {
        return union(enum) {
            ok: T,
            api_error: ApiErrorResponse,

            /// Extract the success value, returning an `ApiRequestError` on API errors.
            /// On error, the error response is freed automatically.
            pub fn value(self: @This()) ApiRequestError!T {
                switch (self) {
                    .ok => |v| return v,
                    .api_error => |e| {
                        const err = e.statusError();
                        e.deinit();
                        return err;
                    },
                }
            }

            /// Release the underlying success value or error response.
            pub fn deinit(self: @This()) void {
                switch (self) {
                    .ok => |v| v.deinit(),
                    .api_error => |e| e.deinit(),
                }
            }
        };
    }

    /// Internal raw result from a single HTTP request.
    const RawResult = union(enum) {
        ok: []const u8,
        api_error: struct {
            status: http.Status,
            body: []const u8,
            retry_after_ns: ?u64,
        },
    };

    /// Release all resources owned by the client.
    pub fn deinit(self: *Client) void {
        self.flow_tracker.deinit();
        self.auth.deinit();
        self.allocator.free(self.base_url);
        self.transport.deinit();
    }

    /// Return the current API Priority and Fairness flow-control state.
    pub fn flowControl(self: *Client) FlowControl {
        return self.flow_tracker.get();
    }

    /// Return connection pool statistics, if supported by the transport.
    pub fn poolStats(self: *Client) ?PoolStats {
        return self.transport.poolStats();
    }

    /// GET a resource and parse the JSON response into T.
    pub fn get(self: *Client, comptime T: type, path: []const u8, ctx: Context) RequestError!ApiResult(std.json.Parsed(T)) {
        const raw = try self.doRequest(.GET, path, null, null, null, null, ctx);
        return self.wrapResult(T, raw);
    }

    /// POST a JSON body and parse the response into T.
    pub fn post(self: *Client, comptime T: type, path: []const u8, payload: []const u8, ctx: Context) RequestError!ApiResult(std.json.Parsed(T)) {
        const raw = try self.doRequest(.POST, path, payload, null, null, null, ctx);
        return self.wrapResult(T, raw);
    }

    /// PUT a JSON body and parse the response into T.
    pub fn put(self: *Client, comptime T: type, path: []const u8, payload: []const u8, ctx: Context) RequestError!ApiResult(std.json.Parsed(T)) {
        const raw = try self.doRequest(.PUT, path, payload, null, null, null, ctx);
        return self.wrapResult(T, raw);
    }

    /// PATCH a resource with a custom content type and parse the response into T.
    pub fn patch(self: *Client, comptime T: type, path: []const u8, payload: []const u8, content_type: []const u8, ctx: Context) RequestError!ApiResult(std.json.Parsed(T)) {
        const raw = try self.doRequest(.PATCH, path, payload, content_type, null, null, ctx);
        return self.wrapResult(T, raw);
    }

    /// DELETE a resource. Returns the raw response body.
    pub fn delete(self: *Client, path: []const u8, payload: ?[]const u8, ctx: Context) RequestError!ApiResult(RawResponse) {
        const raw = try self.doRequest(.DELETE, path, payload, null, null, null, ctx);
        return wrapRawResult(self.allocator, raw);
    }

    /// GET a resource and return the raw response body.
    pub fn getRaw(self: *Client, path: []const u8, ctx: Context) RequestError!ApiResult(RawResponse) {
        const raw = try self.doRequest(.GET, path, null, null, "*/*", null, ctx);
        return wrapRawResult(self.allocator, raw);
    }

    /// POST a JSON body and return the raw response body.
    pub fn postRaw(self: *Client, path: []const u8, payload: []const u8, ctx: Context) RequestError!ApiResult(RawResponse) {
        const raw = try self.doRequest(.POST, path, payload, null, null, null, ctx);
        return wrapRawResult(self.allocator, raw);
    }

    /// POST a value serialized as JSON and parse the response into T.
    pub fn postValue(self: *Client, comptime RespT: type, comptime BodyT: type, path: []const u8, body: *const BodyT, ctx: Context) RequestError!ApiResult(std.json.Parsed(RespT)) {
        const serializer = makeBodySerializer(BodyT, body);
        const raw = try self.doRequest(.POST, path, null, null, null, serializer, ctx);
        return self.wrapResult(RespT, raw);
    }

    /// PUT a value serialized as JSON and parse the response into T.
    pub fn putValue(self: *Client, comptime RespT: type, comptime BodyT: type, path: []const u8, body: *const BodyT, ctx: Context) RequestError!ApiResult(std.json.Parsed(RespT)) {
        const serializer = makeBodySerializer(BodyT, body);
        const raw = try self.doRequest(.PUT, path, null, null, null, serializer, ctx);
        return self.wrapResult(RespT, raw);
    }

    /// POST a value serialized as JSON and return the raw response body.
    pub fn postValueRaw(self: *Client, comptime BodyT: type, path: []const u8, body: *const BodyT, ctx: Context) RequestError!ApiResult(RawResponse) {
        const serializer = makeBodySerializer(BodyT, body);
        const raw = try self.doRequest(.POST, path, null, null, null, serializer, ctx);
        return wrapRawResult(self.allocator, raw);
    }

    /// Open a streaming connection for watch requests. Returns a `StreamResponse`
    /// that the caller can use to read newline-delimited JSON events.
    /// The caller owns the returned `StreamState` and must call `state.deinit()`.
    pub fn watchStream(self: *Client, path: []const u8, ctx: Context) !StreamResponse {
        try self.preflight(ctx);

        self.metrics.request_total.inc();
        const request_start = std.time.Instant.now() catch null;

        const auth_header = try self.auth.getAuthHeader(self.auth.shouldForceRefresh());
        defer if (auth_header) |ah| self.allocator.free(ah);

        var uri_buf: [uri_buf_size]u8 = undefined;
        const owned = try self.buildUri(path, &uri_buf);
        defer owned.deinit(self.allocator);

        const stream_resp = self.transport.sendStream(.{
            .method = .GET,
            .uri = owned.uri,
            .accept = "application/json",
            .auth_header = auth_header,
            .keep_alive = false,
        }, self.allocator) catch |err| {
            self.recordRequestLatency(request_start);

            if (err == error.HttpGone) {
                // Server responded with 410; it's alive.
                if (self.circuit_breaker) |*cb| cb.recordSuccess();
                self.updateCircuitBreakerGauge();
                return error.HttpGone;
            }
            self.metrics.request_error_total.inc();
            const mapped = mapTransportError(err);
            if (self.circuit_breaker) |*cb| {
                if (isRetryableTransport(mapped)) cb.recordFailure();
            }
            self.updateCircuitBreakerGauge();
            return mapped;
        };

        self.recordRequestLatency(request_start);
        self.logger.trace("watch stream opened", &.{
            LogField.string("path", path),
        });
        // Stream opened successfully; server is alive.
        self.auth.clearUnauthorized();
        if (self.circuit_breaker) |*cb| cb.recordSuccess();
        self.updateCircuitBreakerGauge();
        return stream_resp;
    }

    /// Raw response body paired with its allocator.
    /// Returned by `delete()`, `getRaw()`, and other raw methods where the
    /// response may be a resource type or a Kubernetes Status object.
    ///
    /// After `parseAs()` consumes the body, `body` is set to `null`.
    /// Calling `deinit()` on a consumed response is safe (no-op).
    pub const RawResponse = struct {
        body: ?[]const u8,
        allocator: std.mem.Allocator,

        /// Free the response body if it has not been consumed via `parseAs()`.
        pub fn deinit(self: RawResponse) void {
            if (self.body) |b| {
                self.allocator.free(b);
            }
        }

        /// Parse the raw body as a specific type `T`.
        ///
        /// The returned `Parsed(T)` owns all allocated memory. The caller
        /// must call `.deinit()` on it when done. The original body is
        /// consumed (copied into the parse arena); the `RawResponse` is
        /// left with `body = null`, so calling `deinit()` afterward is
        /// harmless.
        /// On error, the `RawResponse` is left unchanged and the caller
        /// should still call `RawResponse.deinit()`.
        pub fn parseAs(self: *RawResponse, comptime T: type) !std.json.Parsed(T) {
            const body = self.body orelse return error.BodyAlreadyConsumed;
            const arena_ptr = try self.allocator.create(std.heap.ArenaAllocator);
            arena_ptr.* = std.heap.ArenaAllocator.init(self.allocator);
            errdefer {
                arena_ptr.deinit();
                self.allocator.destroy(arena_ptr);
            }
            const val = try std.json.parseFromSliceLeaky(T, arena_ptr.allocator(), body, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            });
            // Free the original body now that we have a copy in the arena.
            // Mark body as consumed so a subsequent deinit() is safe.
            self.allocator.free(body);
            self.body = null;
            return .{ .arena = arena_ptr, .value = val };
        }
    };

    /// Signal the client to stop making new requests.
    pub fn shutdown(self: *Client) void {
        self.logger.info("client shutting down", &.{});
        self.shutdown_source.cancel();
    }

    /// Check if the client has been shut down.
    pub fn isShutdown(self: *const Client) bool {
        return self.shutdown_source.isCanceled();
    }

    /// Return a health check that reports healthy when the client is not shut down.
    pub fn healthCheck(self: *Client) HealthCheck {
        return HealthCheck.fromTypedCtx(Client, self, struct {
            fn check(c: *Client) bool {
                return !c.isShutdown();
            }
        }.check);
    }

    /// Return a root `Context` backed by this client's shutdown source.
    pub fn context(self: *const Client) Context {
        return self.shutdown_source.context();
    }

    /// Map an HTTP status code to an ApiRequestError.
    pub fn statusToError(status: http.Status) ApiRequestError {
        return switch (status) {
            .bad_request => error.HttpBadRequest,
            .unauthorized => error.HttpUnauthorized,
            .forbidden => error.HttpForbidden,
            .not_found => error.HttpNotFound,
            .conflict => error.HttpConflict,
            .unprocessable_entity => error.HttpUnprocessableEntity,
            .too_many_requests => error.HttpTooManyRequests,
            .bad_gateway => error.HttpBadGateway,
            .service_unavailable => error.HttpServiceUnavailable,
            .gateway_timeout => error.HttpGatewayTimeout,
            else => if (@intFromEnum(status) >= 500)
                error.HttpServerError
            else
                error.HttpUnexpectedStatus,
        };
    }

    // Internal
    /// Create a BodySerializer that captures a typed body pointer and
    /// streams JSON via `std.json.Stringify`.
    fn makeBodySerializer(comptime BodyT: type, body: *const BodyT) BodySerializer {
        return .{
            .context = @ptrCast(body),
            .writeFn = struct {
                fn write(ctx: *const anyopaque, writer: *std.Io.Writer) anyerror!void {
                    const b: *const BodyT = @ptrCast(@alignCast(ctx));
                    try std.json.Stringify.value(b.*, .{ .emit_null_optional_fields = false }, writer);
                }
            }.write,
        };
    }

    fn parseBody(self: *Client, comptime T: type, body: []const u8) ParseError!std.json.Parsed(T) {
        const arena_ptr = self.allocator.create(std.heap.ArenaAllocator) catch return error.OutOfMemory;
        arena_ptr.* = std.heap.ArenaAllocator.init(self.allocator);
        errdefer {
            arena_ptr.deinit();
            self.allocator.destroy(arena_ptr);
        }
        const val = std.json.parseFromSliceLeaky(T, arena_ptr.allocator(), body, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch |err| {
            self.logger.warn("parseBody failed", &.{
                LogField.string("error", @errorName(err)),
                LogField.uint("body_len", body.len),
                LogField.string("body_prefix", if (body.len > 200) body[0..200] else body),
                LogField.string("type", @typeName(T)),
            });
            return error.JsonParseFailed;
        };
        return .{ .arena = arena_ptr, .value = val };
    }

    const OwnedUri = struct {
        uri: Uri,
        /// Non-null when the URI was heap-allocated (stack buffer was too small).
        heap_buf: ?[]const u8,

        pub fn deinit(self_uri: OwnedUri, allocator: std.mem.Allocator) void {
            if (self_uri.heap_buf) |buf| allocator.free(buf);
        }
    };

    /// Stack buffer size for URI construction. Covers base URL + typical
    /// Kubernetes API paths without heap allocation.
    const uri_buf_size = 512;

    fn buildUri(self: *Client, path: []const u8, buf: []u8) (error{OutOfMemory} || error{HttpRequestFailed})!OwnedUri {
        const url = std.fmt.bufPrint(buf, "{s}{s}", .{ self.base_url, path }) catch {
            // Path too long for the provided buffer; fall back to heap.
            const heap_url = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.base_url, path }) catch return error.OutOfMemory;
            errdefer self.allocator.free(heap_url);
            return .{ .uri = Uri.parse(heap_url) catch return error.HttpRequestFailed, .heap_buf = heap_url };
        };
        return .{ .uri = Uri.parse(url) catch return error.HttpRequestFailed, .heap_buf = null };
    }

    fn doRequestOnce(self: *Client, method: http.Method, uri: Uri, payload: ?[]const u8, content_type: ?[]const u8, accept: ?[]const u8, body: ?BodySerializer, parent_span: ?SpanContext) TransportError!RawResult {
        const method_name = @tagName(method);
        const path = uri.path.percent_encoded;

        // Start a tracing span.
        const attrs = [_]tracing_mod.Attribute{
            .{ .key = "http.method", .value = .{ .string = method_name } },
            .{ .key = "http.url", .value = .{ .string = path } },
        };
        const span_ctx = self.tracer.startSpan(
            method_name,
            parent_span,
            .client,
            &attrs,
        );

        // Format traceparent header only when the tracer produced a valid span.
        var tp_buf: [55]u8 = undefined;
        const traceparent: ?[]const u8 = if (span_ctx.isValid())
            tracing_mod.formatTraceparent(span_ctx, &tp_buf)
        else
            null;

        const force = self.auth.shouldForceRefresh();
        const auth_header = try self.auth.getAuthHeader(force);
        defer if (auth_header) |ah| self.allocator.free(ah);

        var resp = self.transport.send(.{
            .method = method,
            .uri = uri,
            .content_type = content_type,
            .accept = accept,
            .auth_header = auth_header,
            .traceparent = traceparent,
            .keep_alive = self.keep_alive,
            .payload = payload,
        }, body, self.allocator) catch |err| {
            self.tracer.endSpan(span_ctx, .@"error");
            return mapTransportError(err);
        };
        defer resp.deinit();

        try self.flow_tracker.update(resp.flow_control);

        if (resp.status.class() != .success) {
            if (resp.status == .unauthorized) self.auth.markUnauthorized();
            self.tracer.endSpan(span_ctx, .@"error");
            return .{ .api_error = .{
                .status = resp.status,
                .body = resp.takeBody(),
                .retry_after_ns = resp.retry_after_ns,
            } };
        }

        self.auth.clearUnauthorized();
        self.tracer.endSpan(span_ctx, .ok);
        return .{ .ok = resp.takeBody() };
    }

    fn doRequest(self: *Client, method: http.Method, path: []const u8, payload: ?[]const u8, content_type: ?[]const u8, accept: ?[]const u8, body: ?BodySerializer, ctx: Context) RequestError!RawResult {
        return self.retryLoop(struct {
            method: http.Method,
            payload: ?[]const u8,
            content_type: ?[]const u8,
            accept: ?[]const u8,
            body: ?BodySerializer,
            parent_span: ?SpanContext,

            fn call(req_ctx: @This(), s: *Client, uri: Uri) TransportError!RawResult {
                return s.doRequestOnce(req_ctx.method, uri, req_ctx.payload, req_ctx.content_type, req_ctx.accept, req_ctx.body, req_ctx.parent_span);
            }
        }{ .method = method, .payload = payload, .content_type = content_type, .accept = accept, .body = body, .parent_span = ctx.span_context }, path, ctx);
    }

    /// Context cancellation, rate limiting, and circuit breaker gate.
    fn preflight(self: *Client, ctx: Context) !void {
        ctx.check() catch return error.Canceled;

        if (self.rate_limiter) |*rl| {
            const before = std.time.Instant.now() catch null;
            rl.acquire(ctx) catch return error.Canceled;
            if (before) |b| {
                if (std.time.Instant.now() catch null) |after| {
                    const wait_ns: f64 = @floatFromInt(after.since(b));
                    self.metrics.rate_limiter_latency.observe(wait_ns / @as(f64, std.time.ns_per_s));
                }
            }
        }

        if (self.circuit_breaker) |*cb| {
            cb.allowRequest() catch {
                self.metrics.circuit_breaker_trip_total.inc();
                return error.CircuitBreakerOpen;
            };
        }
    }

    /// Shared retry loop.
    fn retryLoop(self: *Client, req_ctx: anytype, path: []const u8, ctx: Context) RequestError!RawResult {
        try self.preflight(ctx);

        var uri_buf: [uri_buf_size]u8 = undefined;
        const owned = try self.buildUri(path, &uri_buf);
        defer owned.deinit(self.allocator);

        var attempt: u32 = 0;
        while (true) {
            self.metrics.request_total.inc();
            const request_start = std.time.Instant.now() catch null;

            const raw = req_ctx.call(self, owned.uri) catch |err| {
                self.recordRequestLatency(request_start);
                self.recordPoolStats();
                self.metrics.request_error_total.inc();

                if (self.circuit_breaker) |*cb| {
                    if (isRetryableTransport(err)) cb.recordFailure();
                }
                self.updateCircuitBreakerGauge();

                if (attempt < self.retry_policy.max_retries and isRetryableTransport(err)) {
                    self.metrics.retry_total.inc();
                    const sleep_ns = self.retry_policy.sleepNs(attempt, null);
                    self.logRetry(req_ctx, path, attempt, sleep_ns, .{ .transport = err });
                    context_mod.interruptibleSleep(ctx, sleep_ns) catch return error.Canceled;
                    attempt += 1;
                    continue;
                }
                self.logger.err("all retries exhausted", &.{
                    LogField.string("method", @tagName(req_ctx.method)),
                    LogField.string("path", path),
                    LogField.uint("attempt", @intCast(attempt + 1)),
                    LogField.uint("max_retries", @intCast(self.retry_policy.max_retries)),
                    LogField.string("error", @errorName(err)),
                });
                return err;
            };

            self.recordRequestLatency(request_start);
            self.recordPoolStats();

            switch (raw) {
                .ok => {
                    self.logger.trace("request ok", &.{
                        LogField.string("method", @tagName(req_ctx.method)),
                        LogField.string("path", path),
                    });
                    if (self.circuit_breaker) |*cb| cb.recordSuccess();
                    self.updateCircuitBreakerGauge();
                    return raw;
                },
                .api_error => |e| {
                    if (isCircuitBreakerFailure(e.status)) {
                        self.metrics.request_error_total.inc();
                        if (self.circuit_breaker) |*cb| cb.recordFailure();
                    } else {
                        // Server responded (even with 4xx/429); it's alive.
                        if (self.circuit_breaker) |*cb| cb.recordSuccess();
                    }
                    self.updateCircuitBreakerGauge();

                    if (attempt < self.retry_policy.max_retries and RetryPolicy.isRetryableStatus(e.status)) {
                        self.metrics.retry_total.inc();
                        const sleep_ns = self.retry_policy.sleepNs(attempt, e.retry_after_ns);
                        self.logRetry(req_ctx, path, attempt, sleep_ns, .{ .api_status = e.status });
                        self.allocator.free(e.body);
                        context_mod.interruptibleSleep(ctx, sleep_ns) catch return error.Canceled;
                        attempt += 1;
                        continue;
                    }
                    self.logger.trace("request api_error", &.{
                        LogField.string("method", @tagName(req_ctx.method)),
                        LogField.string("path", path),
                        LogField.uint("status", @intFromEnum(e.status)),
                    });
                    return raw;
                },
            }
        }
    }

    const RetryReason = union(enum) {
        transport: anyerror,
        api_status: http.Status,
    };

    fn logRetry(self: *Client, req_ctx: anytype, path: []const u8, attempt: u32, sleep_ns: u64, reason: RetryReason) void {
        switch (reason) {
            .transport => |err| self.logger.warn("retrying request", &.{
                LogField.string("method", @tagName(req_ctx.method)),
                LogField.string("path", path),
                LogField.uint("attempt", @intCast(attempt + 1)),
                LogField.uint("max_retries", @intCast(self.retry_policy.max_retries)),
                LogField.uint("backoff_ms", sleep_ns / std.time.ns_per_ms),
                LogField.string("error", @errorName(err)),
            }),
            .api_status => |code| self.logger.warn("retrying request", &.{
                LogField.string("method", @tagName(req_ctx.method)),
                LogField.string("path", path),
                LogField.uint("attempt", @intCast(attempt + 1)),
                LogField.uint("max_retries", @intCast(self.retry_policy.max_retries)),
                LogField.uint("backoff_ms", sleep_ns / std.time.ns_per_ms),
                LogField.uint("status_code", @intFromEnum(code)),
            }),
        }
    }

    fn isRetryableTransport(err: TransportError) bool {
        return switch (err) {
            error.ConnectionRefused,
            error.ConnectionResetByPeer,
            error.ConnectionTimedOut,
            error.TemporaryNameServerFailure,
            error.HttpRequestFailed,
            => true,
            else => false,
        };
    }

    fn isCircuitBreakerFailure(status: http.Status) bool {
        return switch (status) {
            .bad_gateway, .service_unavailable, .gateway_timeout => true,
            else => false,
        };
    }

    /// Convert a `RawResult` into a typed `ApiResult(std.json.Parsed(T))`.
    fn wrapResult(self: *Client, comptime T: type, raw: RawResult) (ParseError)!ApiResult(std.json.Parsed(T)) {
        switch (raw) {
            .ok => |body| {
                defer self.allocator.free(body);
                const parsed = try self.parseBody(T, body);
                return .{ .ok = parsed };
            },
            .api_error => |e| {
                return .{ .api_error = .{
                    .status = e.status,
                    .body = e.body,
                    .allocator = self.allocator,
                } };
            },
        }
    }

    /// Convert a `RawResult` into a `ApiResult(RawResponse)`.
    fn wrapRawResult(allocator: std.mem.Allocator, raw: RawResult) ApiResult(RawResponse) {
        switch (raw) {
            .ok => |body| {
                return .{ .ok = .{ .body = body, .allocator = allocator } };
            },
            .api_error => |e| {
                return .{ .api_error = .{
                    .status = e.status,
                    .body = e.body,
                    .allocator = allocator,
                } };
            },
        }
    }

    /// Map a transport-layer error to the named `TransportError` set.
    fn mapTransportError(err: anyerror) TransportError {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.ConnectionRefused => error.ConnectionRefused,
            error.ConnectionResetByPeer => error.ConnectionResetByPeer,
            error.ConnectionTimedOut => error.ConnectionTimedOut,
            error.TemporaryNameServerFailure => error.TemporaryNameServerFailure,
            error.TlsFailure => error.TlsFailure,
            error.ResponseTooLarge => error.ResponseTooLarge,
            else => error.HttpRequestFailed,
        };
    }

    // Construction
    /// Create a plain-HTTP client (e.g. for `kubectl proxy` on localhost).
    /// Heap-allocates a `StdHttpTransport` internally.
    pub fn init(allocator: std.mem.Allocator, base_url: []const u8, options: ClientOptions) !Client {
        return initInternal(allocator, base_url, null, null, options);
    }

    /// Create an HTTPS client using in-cluster service-account credentials.
    /// Heap-allocates a `StdHttpTransport` internally.
    pub fn initInCluster(allocator: std.mem.Allocator, config: InClusterConfig, options: ClientOptions) !Client {
        return initInternal(allocator, config.base_url, config.ca_cert_path, config.token_path, options);
    }

    fn initInternal(allocator: std.mem.Allocator, base_url: []const u8, ca_cert_path: ?[]const u8, token_path: ?[]const u8, options: ClientOptions) !Client {
        const owned_url = try allocator.dupe(u8, base_url);
        errdefer allocator.free(owned_url);

        const tp = try allocator.create(StdHttpTransport);
        errdefer {
            tp.http_client.deinit();
            allocator.destroy(tp);
        }

        tp.* = .{
            .http_client = .{ .allocator = allocator },
            .read_timeout_ms = options.read_timeout_ms,
            .write_timeout_ms = options.write_timeout_ms,
            .watch_read_timeout_ms = options.watch_read_timeout_ms,
            .tcp_keepalive = options.tcp_keepalive,
            .tcp_keepalive_idle_s = options.tcp_keepalive_idle_s,
            .tcp_keepalive_interval_s = options.tcp_keepalive_interval_s,
            .tcp_keepalive_count = options.tcp_keepalive_count,
            .max_response_bytes = options.max_response_bytes,
            .logger = options.logger.withScope("transport"),
            .self_allocator = allocator,
        };

        if (options.pool_size) |size| {
            tp.http_client.connection_pool.free_size = size;
        }

        if (ca_cert_path) |path| {
            try tp.http_client.ca_bundle.addCertsFromFilePathAbsolute(allocator, path);
            tp.http_client.next_https_rescan_certs = false;
        }

        return .{
            .allocator = allocator,
            .base_url = owned_url,
            .transport = tp.transport(),
            .auth = AuthProvider.init(allocator, token_path, options.logger.withScope("client")),
            .retry_policy = options.retry,
            .rate_limiter = try RateLimiter.init(.{ .qps = options.rate_limit.qps, .burst = options.rate_limit.burst, .logger = options.logger }),
            .circuit_breaker = try CircuitBreaker.init(.{ .failure_threshold = options.circuit_breaker.failure_threshold, .recovery_timeout_ns = options.circuit_breaker.recovery_timeout_ns, .logger = options.logger }),
            .keep_alive = options.keep_alive,
            .shutdown_source = CancelSource.init(),
            .metrics = options.metrics.create(),
            .tracer = options.tracer,
            .logger = options.logger.withScope("client"),
            .flow_tracker = FlowControlTracker.init(allocator),
        };
    }

    fn recordRequestLatency(self: *Client, start: ?std.time.Instant) void {
        const s = start orelse return;
        const end = std.time.Instant.now() catch return;
        const dur_ns: f64 = @floatFromInt(end.since(s));
        self.metrics.request_latency.observe(dur_ns / @as(f64, std.time.ns_per_s));
    }

    fn recordPoolStats(self: *Client) void {
        const stats = self.transport.poolStats() orelse return;
        self.metrics.pool_size.set(@floatFromInt(stats.pool_size));
        self.metrics.pool_idle_connections.set(@floatFromInt(stats.free_connections));
        self.metrics.pool_active_connections.set(@floatFromInt(stats.active_connections));
    }

    fn updateCircuitBreakerGauge(self: *Client) void {
        if (self.circuit_breaker) |*cb| {
            const state_val: f64 = switch (cb.getState()) {
                .closed => 0.0,
                .half_open => 1.0,
                .open => 2.0,
            };
            self.metrics.circuit_breaker_state.set(state_val);
        }
    }
};

test "buildUri constructs valid URL from standard path using stack buffer" {
    // Arrange
    var client = try Client.init(testing.allocator, "http://127.0.0.1:8001", .{});
    defer client.deinit();
    var buf: [Client.uri_buf_size]u8 = undefined;

    // Act
    const owned = try client.buildUri("/api/v1/pods", &buf);
    defer owned.deinit(testing.allocator);

    // Assert
    try testing.expect(owned.heap_buf == null);
    try testing.expectEqualStrings("127.0.0.1", owned.uri.host.?.percent_encoded);
    try testing.expectEqual(8001, owned.uri.port.?);
    try testing.expectEqualStrings("/api/v1/pods", owned.uri.path.percent_encoded);
}

test "buildUri constructs valid URL from empty path" {
    // Arrange
    var client = try Client.init(testing.allocator, "http://127.0.0.1:8001", .{});
    defer client.deinit();
    var buf: [Client.uri_buf_size]u8 = undefined;

    // Act
    const owned = try client.buildUri("", &buf);
    defer owned.deinit(testing.allocator);

    // Assert
    try testing.expect(owned.heap_buf == null);
    try testing.expectEqualStrings("127.0.0.1", owned.uri.host.?.percent_encoded);
    try testing.expectEqual(8001, owned.uri.port.?);
}

test "buildUri parses custom host and port correctly" {
    // Arrange
    var client = try Client.init(testing.allocator, "http://localhost:9090", .{});
    defer client.deinit();
    var buf: [Client.uri_buf_size]u8 = undefined;

    // Act
    const owned = try client.buildUri("/apis/apps/v1/deployments", &buf);
    defer owned.deinit(testing.allocator);

    // Assert
    try testing.expect(owned.heap_buf == null);
    try testing.expectEqualStrings("localhost", owned.uri.host.?.percent_encoded);
    try testing.expectEqual(9090, owned.uri.port.?);
    try testing.expectEqualStrings("/apis/apps/v1/deployments", owned.uri.path.percent_encoded);
}

test "buildUri falls back to heap allocation when stack buffer is too small" {
    // Arrange
    var client = try Client.init(testing.allocator, "http://127.0.0.1:8001", .{});
    defer client.deinit();
    var tiny_buf: [4]u8 = undefined;

    // Act
    const owned = try client.buildUri("/api/v1/pods", &tiny_buf);
    defer owned.deinit(testing.allocator);

    // Assert
    try testing.expect(owned.heap_buf != null);
    try testing.expectEqualStrings("127.0.0.1", owned.uri.host.?.percent_encoded);
    try testing.expectEqual(8001, owned.uri.port.?);
    try testing.expectEqualStrings("/api/v1/pods", owned.uri.path.percent_encoded);
}

test "findHeaderInBytes: extracts APF header" {
    // Act / Assert
    const raw = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nX-Kubernetes-PF-FlowSchema-UID: abc-123\r\n\r\n";
    const result = findHeaderInBytes(raw, "x-kubernetes-pf-flowschema-uid:");
    try testing.expect(result != null);
    try testing.expectEqualStrings("abc-123", result.?);
}

test "findHeaderInBytes: case insensitive" {
    // Act / Assert
    const raw = "HTTP/1.1 200 OK\r\nx-kubernetes-pf-prioritylevel-uid: def-456\r\n\r\n";
    const result = findHeaderInBytes(raw, "x-kubernetes-pf-prioritylevel-uid:");
    try testing.expect(result != null);
    try testing.expectEqualStrings("def-456", result.?);
}

test "findHeaderInBytes: header not present" {
    // Act / Assert
    const raw = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n";
    const result = findHeaderInBytes(raw, "x-kubernetes-pf-flowschema-uid:");
    try testing.expect(result == null);
}

test "buildUri with long path still produces correct URI via heap" {
    // Arrange
    var client = try Client.init(testing.allocator, "http://127.0.0.1:8001", .{});
    defer client.deinit();
    const long_path = "/api/v1/namespaces/very-long-namespace-name-for-testing/pods/my-very-long-pod-name-that-exceeds-normal-lengths";
    var tiny_buf: [8]u8 = undefined;

    // Act
    const owned = try client.buildUri(long_path, &tiny_buf);
    defer owned.deinit(testing.allocator);

    // Assert
    try testing.expect(owned.heap_buf != null);
    try testing.expectEqualStrings(long_path, owned.uri.path.percent_encoded);
}

test "poolStats: returns configured pool_size from StdHttpTransport" {
    // Arrange
    var client = try Client.init(testing.allocator, "http://127.0.0.1:8001", .{ .pool_size = 16 });
    defer client.deinit();

    // Act
    const stats = client.poolStats();

    // Assert
    try testing.expect(stats != null);
    try testing.expectEqual(@as(u32, 16), stats.?.pool_size);
    try testing.expectEqual(@as(u32, 0), stats.?.free_connections);
    try testing.expectEqual(@as(u32, 0), stats.?.active_connections);
}

test "healthCheck: reflects shutdown state" {
    // Arrange
    var client = try Client.init(testing.allocator, "http://127.0.0.1:8001", .{});
    defer client.deinit();
    const check = client.healthCheck();

    // Act / Assert
    try testing.expect(check.check_fn(check.ctx));

    client.shutdown();
    try testing.expect(!check.check_fn(check.ctx));
}

test "mapTransportError: maps known transport errors" {
    // Act / Assert
    try testing.expectEqual(error.OutOfMemory, Client.mapTransportError(error.OutOfMemory));
    try testing.expectEqual(error.ConnectionRefused, Client.mapTransportError(error.ConnectionRefused));
    try testing.expectEqual(error.ConnectionResetByPeer, Client.mapTransportError(error.ConnectionResetByPeer));
    try testing.expectEqual(error.ConnectionTimedOut, Client.mapTransportError(error.ConnectionTimedOut));
    try testing.expectEqual(error.TemporaryNameServerFailure, Client.mapTransportError(error.TemporaryNameServerFailure));
    try testing.expectEqual(error.TlsFailure, Client.mapTransportError(error.TlsFailure));
    try testing.expectEqual(error.ResponseTooLarge, Client.mapTransportError(error.ResponseTooLarge));
}

test "mapTransportError: maps unknown errors to HttpRequestFailed" {
    // Act / Assert
    try testing.expectEqual(error.HttpRequestFailed, Client.mapTransportError(error.Unexpected));
    try testing.expectEqual(error.HttpRequestFailed, Client.mapTransportError(error.FileNotFound));
    try testing.expectEqual(error.HttpRequestFailed, Client.mapTransportError(error.BrokenPipe));
}

test "RawResponse.parseAs: parses body and deinit afterward is safe" {
    // Arrange
    const body = try testing.allocator.dupe(u8, "{\"name\":\"test\"}");
    var raw = Client.RawResponse{ .body = body, .allocator = testing.allocator };

    // Act
    const parsed = try raw.parseAs(struct { name: ?[]const u8 = null });
    defer parsed.deinit();

    // Assert
    try testing.expectEqualStrings("test", parsed.value.name.?);
    raw.deinit();
}

test "RawResponse.parseAs: second call returns BodyAlreadyConsumed" {
    // Arrange
    const body = try testing.allocator.dupe(u8, "{\"name\":\"test\"}");
    var raw = Client.RawResponse{ .body = body, .allocator = testing.allocator };

    const parsed = try raw.parseAs(struct { name: ?[]const u8 = null });
    defer parsed.deinit();

    // Act / Assert
    try testing.expectError(error.BodyAlreadyConsumed, raw.parseAs(struct { name: ?[]const u8 = null }));
}

test "RawResponse.deinit: frees empty but heap-allocated body" {
    // Arrange
    const body = try testing.allocator.dupe(u8, "");

    // Act
    const raw = Client.RawResponse{ .body = body, .allocator = testing.allocator };
    raw.deinit();

    // Assert: no leak (testing.allocator detects leaks for zero-length allocs)
}

test "TransportResponse.takeBody: extracts body and deinit is safe afterward" {
    // Arrange
    const body = try testing.allocator.dupe(u8, "response body");
    var resp = TransportResponse{ .status = .ok, .body = body, .allocator = testing.allocator };

    // Act
    const taken = resp.takeBody();
    defer testing.allocator.free(taken);
    resp.deinit();

    // Assert
    try testing.expectEqualStrings("response body", taken);
    try testing.expect(resp.body == null);
}

test "TransportResponse.deinit: frees untaken body and flow-control" {
    // Arrange
    const body = try testing.allocator.dupe(u8, "body");
    const fs_uid = try testing.allocator.dupe(u8, "fs-uid");
    const pl_uid = try testing.allocator.dupe(u8, "pl-uid");

    // Act
    const resp = TransportResponse{
        .status = .ok,
        .body = body,
        .flow_control = .{ .flow_schema_uid = fs_uid, .priority_level_uid = pl_uid },
        .allocator = testing.allocator,
    };
    resp.deinit();

    // Assert: no leak (testing.allocator detects leaks)
}
