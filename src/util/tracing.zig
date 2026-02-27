//! Distributed tracing primitives with W3C Trace Context support.
//!
//! Provides trace and span identifiers, span context propagation, and a
//! pluggable `TracerProvider` vtable for integrating with backends such as
//! OpenTelemetry. Includes formatting and parsing of W3C `traceparent`
//! headers. The default `TracerProvider.noop` has zero cost.

const std = @import("std");
const testing = std.testing;

// Trace ID
/// 16-byte trace identifier, rendered as 32 lowercase hex characters.
pub const TraceId = struct {
    bytes: [16]u8,

    /// The all-zeros trace ID, representing an invalid/unset trace.
    pub const zero: TraceId = .{ .bytes = .{0} ** 16 };

    /// Generate a random trace ID using the system CSPRNG.
    pub fn generate() TraceId {
        var id: TraceId = undefined;
        std.crypto.random.bytes(&id.bytes);
        return id;
    }

    /// Convert to 32 lowercase hex characters into a caller-provided buffer.
    pub fn toHex(self: TraceId, buf: *[32]u8) void {
        bytesToHex(&self.bytes, buf);
    }

    /// Parse from a 32-character hex string.
    pub fn parse(hex: *const [32]u8) ?TraceId {
        var id: TraceId = undefined;
        for (&id.bytes, 0..) |*b, i| {
            b.* = parseHexByte(hex[i * 2], hex[i * 2 + 1]) orelse return null;
        }
        return id;
    }

    /// Returns true if this trace ID is all zeros (invalid/unset).
    pub fn isZero(self: TraceId) bool {
        return std.mem.eql(u8, &self.bytes, &zero.bytes);
    }
};

// Span ID
/// 8-byte span identifier, rendered as 16 lowercase hex characters.
pub const SpanId = struct {
    bytes: [8]u8,

    /// The all-zeros span ID, representing an invalid/unset span.
    pub const zero: SpanId = .{ .bytes = .{0} ** 8 };

    /// Generate a random span ID using the system CSPRNG.
    pub fn generate() SpanId {
        var id: SpanId = undefined;
        std.crypto.random.bytes(&id.bytes);
        return id;
    }

    /// Convert to 16 lowercase hex characters into a caller-provided buffer.
    pub fn toHex(self: SpanId, buf: *[16]u8) void {
        bytesToHex(&self.bytes, buf);
    }

    /// Parse from a 16-character hex string.
    pub fn parse(hex: *const [16]u8) ?SpanId {
        var id: SpanId = undefined;
        for (&id.bytes, 0..) |*b, i| {
            b.* = parseHexByte(hex[i * 2], hex[i * 2 + 1]) orelse return null;
        }
        return id;
    }

    /// Returns true if this span ID is all zeros (invalid/unset).
    pub fn isZero(self: SpanId) bool {
        return std.mem.eql(u8, &self.bytes, &zero.bytes);
    }
};

// Span Context
/// Immutable context propagated across process boundaries.
pub const SpanContext = struct {
    trace_id: TraceId,
    span_id: SpanId,
    trace_flags: u8 = 0,

    /// Bitmask for the W3C "sampled" trace flag.
    pub const sampled_flag: u8 = 0x01;

    /// A span context is valid when both trace and span IDs are non-zero.
    pub fn isValid(self: SpanContext) bool {
        return !self.trace_id.isZero() and !self.span_id.isZero();
    }

    /// Returns true if the sampled flag is set.
    pub fn isSampled(self: SpanContext) bool {
        return (self.trace_flags & sampled_flag) != 0;
    }

    /// A sentinel span context with all-zero IDs, used by the noop tracer.
    pub const invalid: SpanContext = .{
        .trace_id = TraceId.zero,
        .span_id = SpanId.zero,
        .trace_flags = 0,
    };
};

// Span types
/// Indicates whether the span represents a client call or an internal operation.
pub const SpanKind = enum {
    client,
    internal,
};

/// Outcome status of a completed span.
pub const SpanStatus = enum {
    unset,
    ok,
    @"error",
};

/// A typed value that can be attached to a span as an attribute.
pub const SpanAttributeValue = union(enum) {
    string: []const u8,
    int: i64,
    boolean: bool,
};

/// A key-value pair attached to a span for additional context.
pub const Attribute = struct {
    key: []const u8,
    value: SpanAttributeValue,
};

/// A completed span with timing, context, and diagnostic information.
pub const Span = struct {
    context: SpanContext,
    parent_span_id: ?SpanId,
    name: []const u8,
    start_time_ns: i128,
    attributes: ?[]const Attribute,
    kind: SpanKind,
    status: SpanStatus,
    message: ?[]const u8,
};

// W3C Traceparent
/// Format a SpanContext as a W3C traceparent header value.
/// Writes into a caller-provided 55-byte buffer and returns the slice.
/// Format: {version:2}-{trace-id:32}-{span-id:16}-{trace-flags:2}
pub fn formatTraceparent(sc: SpanContext, buf: *[55]u8) []const u8 {
    // version
    buf[0] = '0';
    buf[1] = '0';
    buf[2] = '-';
    // trace-id (32 hex chars)
    var trace_hex: [32]u8 = undefined;
    sc.trace_id.toHex(&trace_hex);
    @memcpy(buf[3..35], &trace_hex);
    buf[35] = '-';
    // span-id (16 hex chars)
    var span_hex: [16]u8 = undefined;
    sc.span_id.toHex(&span_hex);
    @memcpy(buf[36..52], &span_hex);
    buf[52] = '-';
    // trace-flags (2 hex chars)
    bytesToHex(&[_]u8{sc.trace_flags}, buf[53..55]);

    return buf[0..55];
}

/// Parse a W3C traceparent header value into a SpanContext.
/// Returns null on malformed input.
pub fn parseTraceparent(header: []const u8) ?SpanContext {
    if (header.len != 55) return null;

    // Check separators.
    if (header[2] != '-' or header[35] != '-' or header[52] != '-') return null;

    // Version must be "00".
    if (header[0] != '0' or header[1] != '0') return null;

    const trace_id = TraceId.parse(header[3..35]) orelse return null;
    const span_id = SpanId.parse(header[36..52]) orelse return null;
    const trace_flags = parseHexByte(header[53], header[54]) orelse return null;

    // Reject all-zero IDs.
    if (trace_id.isZero() or span_id.isZero()) return null;

    return .{
        .trace_id = trace_id,
        .span_id = span_id,
        .trace_flags = trace_flags,
    };
}

// TracerProvider vtable
/// Pluggable tracing backend following the MetricsProvider vtable pattern.
/// Default is `noop` which has zero cost: startSpan returns an invalid
/// SpanContext (all zeros) and endSpan does nothing.
pub const TracerProvider = struct {
    ptr: ?*anyopaque,
    vtable: *const VTable,

    /// VTable for tracer provider implementations.
    pub const VTable = struct {
        start_span: *const fn (
            ptr: ?*anyopaque,
            name: []const u8,
            parent: ?SpanContext,
            kind: SpanKind,
            attributes: ?[]const Attribute,
        ) SpanContext,
        end_span: *const fn (
            ptr: ?*anyopaque,
            context: SpanContext,
            status: SpanStatus,
        ) void,
    };

    /// Begin a new span with the given name, optional parent context, kind,
    /// and attributes. Returns the SpanContext for the newly started span.
    pub fn startSpan(
        self: TracerProvider,
        name: []const u8,
        parent: ?SpanContext,
        kind: SpanKind,
        attributes: ?[]const Attribute,
    ) SpanContext {
        return self.vtable.start_span(self.ptr, name, parent, kind, attributes);
    }

    /// End a span, recording its final status (ok, error, or unset).
    pub fn endSpan(self: TracerProvider, context: SpanContext, status: SpanStatus) void {
        self.vtable.end_span(self.ptr, context, status);
    }

    /// No-op tracer. startSpan returns an invalid SpanContext. Zero cost.
    pub const noop: TracerProvider = .{ .ptr = null, .vtable = &noop_vtable };

    fn noopStartSpan(_: ?*anyopaque, _: []const u8, _: ?SpanContext, _: SpanKind, _: ?[]const Attribute) SpanContext {
        return SpanContext.invalid;
    }
    fn noopEndSpan(_: ?*anyopaque, _: SpanContext, _: SpanStatus) void {}
    const noop_vtable: VTable = .{ .start_span = noopStartSpan, .end_span = noopEndSpan };
};

// Hex helpers
const hex_chars = "0123456789abcdef";

fn bytesToHex(bytes: []const u8, out: []u8) void {
    for (bytes, 0..) |b, i| {
        out[i * 2] = hex_chars[b >> 4];
        out[i * 2 + 1] = hex_chars[b & 0x0f];
    }
}

fn parseHexByte(hi: u8, lo: u8) ?u8 {
    const h: u8 = hexVal(hi) orelse return null;
    const l: u8 = hexVal(lo) orelse return null;
    return (h << 4) | l;
}

fn hexVal(c: u8) ?u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'f' => @intCast(c - 'a' + 10),
        'A'...'F' => @intCast(c - 'A' + 10),
        else => null,
    };
}

test "TraceId: generate produces non-zero ID" {
    // Act / Assert
    const id = TraceId.generate();
    try testing.expect(!id.isZero());
}

test "SpanId: generate produces non-zero ID" {
    // Act / Assert
    const id = SpanId.generate();
    try testing.expect(!id.isZero());
}

test "TraceId: format/parse roundtrip" {
    // Act / Assert
    const id = TraceId.generate();
    var buf: [32]u8 = undefined;
    id.toHex(&buf);
    const parsed = TraceId.parse(&buf).?;
    try testing.expectEqualSlices(u8, &id.bytes, &parsed.bytes);
}

test "SpanId: format/parse roundtrip" {
    // Act / Assert
    const id = SpanId.generate();
    var buf: [16]u8 = undefined;
    id.toHex(&buf);
    const parsed = SpanId.parse(&buf).?;
    try testing.expectEqualSlices(u8, &id.bytes, &parsed.bytes);
}

test "TraceId: parse rejects invalid hex" {
    // Act / Assert
    const bad = "0123456789abcdefGHIJKLMNOPQRSTUV".*;
    try testing.expect(TraceId.parse(&bad) == null);
}

test "SpanId: parse rejects invalid hex" {
    // Act / Assert
    const bad = "0123456789abXXXX".*;
    try testing.expect(SpanId.parse(&bad) == null);
}

test "SpanContext: isValid and isSampled" {
    // Arrange
    const sc = SpanContext{
        .trace_id = TraceId.generate(),
        .span_id = SpanId.generate(),
        .trace_flags = SpanContext.sampled_flag,
    };
    try testing.expect(sc.isValid());
    try testing.expect(sc.isSampled());

    // Act / Assert
    try testing.expect(!SpanContext.invalid.isValid());
    try testing.expect(!SpanContext.invalid.isSampled());
}

test "formatTraceparent/parseTraceparent roundtrip" {
    // Arrange
    const sc = SpanContext{
        .trace_id = TraceId.generate(),
        .span_id = SpanId.generate(),
        .trace_flags = SpanContext.sampled_flag,
    };
    var buf: [55]u8 = undefined;
    const header = formatTraceparent(sc, &buf);
    try testing.expectEqual(@as(usize, 55), header.len);

    // Act / Assert
    const parsed = parseTraceparent(header).?;
    try testing.expectEqualSlices(u8, &sc.trace_id.bytes, &parsed.trace_id.bytes);
    try testing.expectEqualSlices(u8, &sc.span_id.bytes, &parsed.span_id.bytes);
    try testing.expectEqual(sc.trace_flags, parsed.trace_flags);
}

test "parseTraceparent: rejects wrong length" {
    // Act / Assert
    try testing.expect(parseTraceparent("too-short") == null);
    try testing.expect(parseTraceparent("00-0123456789abcdef0123456789abcdef-0123456789abcdef-01-extra") == null);
}

test "parseTraceparent: rejects invalid hex" {
    // Act / Assert
    try testing.expect(parseTraceparent("00-ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ-0123456789abcdef-01") == null);
}

test "parseTraceparent: rejects all-zero trace ID" {
    // Act / Assert
    try testing.expect(parseTraceparent("00-00000000000000000000000000000000-0123456789abcdef-01") == null);
}

test "parseTraceparent: rejects all-zero span ID" {
    // Act / Assert
    try testing.expect(parseTraceparent("00-0123456789abcdef0123456789abcdef-0000000000000000-01") == null);
}

test "parseTraceparent: rejects unknown version" {
    // Act / Assert
    try testing.expect(parseTraceparent("01-0123456789abcdef0123456789abcdef-0123456789abcdef-01") == null);
    try testing.expect(parseTraceparent("ff-0123456789abcdef0123456789abcdef-0123456789abcdef-01") == null);
}

test "parseTraceparent: rejects missing separators" {
    // Act / Assert
    try testing.expect(parseTraceparent("00X0123456789abcdef0123456789abcdefX0123456789abcdefX01") == null);
}

test "noop tracer: startSpan returns invalid SpanContext" {
    // Act / Assert
    const sc = TracerProvider.noop.startSpan("test", null, .client, null);
    try testing.expect(!sc.isValid());
}

test "noop tracer: endSpan is safe to call" {
    // Act / Assert
    TracerProvider.noop.endSpan(SpanContext.invalid, .ok);
    TracerProvider.noop.endSpan(SpanContext.invalid, .@"error");
}

test "custom TracerProvider receives calls" {
    // Arrange
    const TestTracer = struct {
        start_count: u32 = 0,
        end_count: u32 = 0,
        last_name: []const u8 = "",
        last_kind: SpanKind = .internal,
        last_status: SpanStatus = .unset,

        // Act
        fn startSpan(raw: ?*anyopaque, name: []const u8, _: ?SpanContext, kind: SpanKind, _: ?[]const Attribute) SpanContext {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.start_count += 1;
            self.last_name = name;
            self.last_kind = kind;
            return .{
                .trace_id = TraceId.generate(),
                .span_id = SpanId.generate(),
                .trace_flags = SpanContext.sampled_flag,
            };
        }

        // Assert
        fn endSpan(raw: ?*anyopaque, _: SpanContext, status: SpanStatus) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.end_count += 1;
            self.last_status = status;
        }

        const vtable: TracerProvider.VTable = .{
            .start_span = startSpan,
            .end_span = endSpan,
        };
    };

    var tracer = TestTracer{};
    const provider: TracerProvider = .{ .ptr = @ptrCast(&tracer), .vtable = &TestTracer.vtable };

    const sc = provider.startSpan("HTTP GET", null, .client, null);
    try testing.expect(sc.isValid());
    try testing.expectEqual(@as(u32, 1), tracer.start_count);
    try testing.expectEqualStrings("HTTP GET", tracer.last_name);
    try testing.expectEqual(SpanKind.client, tracer.last_kind);

    provider.endSpan(sc, .ok);
    try testing.expectEqual(@as(u32, 1), tracer.end_count);
    try testing.expectEqual(SpanStatus.ok, tracer.last_status);
}
