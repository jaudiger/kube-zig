//! Structured logging framework with vtable-dispatched backends.
//!
//! Provides a `Logger` type that dispatches log calls through a vtable,
//! enabling pluggable backends. Includes two built-in implementations:
//! `JsonStdoutLogger` (one JSON object per line) and `TextStdoutLogger`
//! (human-readable plain text). A zero-cost `Logger.noop` discards all
//! messages. Supports scoped loggers and base-field injection via `withFields`.

const std = @import("std");
const time_mod = @import("time.zig");
const testing = std.testing;

/// Log severity level.
pub const Level = enum(u8) {
    trace = 0,
    debug = 1,
    info = 2,
    warn = 3,
    err = 4,

    /// Return the numeric ordering value for level comparison.
    pub fn order(self: Level) u8 {
        return @intFromEnum(self);
    }

    /// Return the lowercase string representation of this level.
    pub fn asText(self: Level) []const u8 {
        return switch (self) {
            .trace => "trace",
            .debug => "debug",
            .info => "info",
            .warn => "warn",
            .err => "error",
        };
    }

    /// Return the uppercase representation used by Kubernetes component logs.
    pub fn asTextUpper(self: Level) []const u8 {
        return switch (self) {
            .trace => "TRACE",
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
        };
    }
};

/// A structured log field value.
pub const FieldValue = union(enum) {
    string: []const u8,
    int: i64,
    uint: u64,
    float: f64,
    boolean: bool,
};

/// A key-value pair for structured logging.
pub const Field = struct {
    key: []const u8,
    value: FieldValue,

    /// Create a string field.
    pub fn string(key: []const u8, val: []const u8) Field {
        return .{ .key = key, .value = .{ .string = val } };
    }

    /// Create a signed integer field.
    pub fn int(key: []const u8, val: i64) Field {
        return .{ .key = key, .value = .{ .int = val } };
    }

    /// Create an unsigned integer field.
    pub fn uint(key: []const u8, val: u64) Field {
        return .{ .key = key, .value = .{ .uint = val } };
    }

    /// Create a floating-point field.
    pub fn float(key: []const u8, val: f64) Field {
        return .{ .key = key, .value = .{ .float = val } };
    }

    /// Create a boolean field.
    pub fn boolean(key: []const u8, val: bool) Field {
        return .{ .key = key, .value = .{ .boolean = val } };
    }

    /// Create a field from an error, converting it to its name string.
    pub fn err(key: []const u8, e: anyerror) Field {
        return .{ .key = key, .value = .{ .string = @errorName(e) } };
    }
};

/// Runtime-dispatched structured logger, following the vtable pattern
/// used by MetricsProvider, Transport, etc. throughout this codebase.
///
/// Implementations must be safe to call from any thread.
/// The `log` method must never return an error.
pub const Logger = struct {
    ptr: ?*anyopaque,
    vtable: *const VTable,
    scope: []const u8 = "",
    min_level: u8 = 0,

    pub const VTable = struct {
        log: *const fn (ptr: ?*anyopaque, level: Level, scope: []const u8, message: []const u8, fields: []const Field) void,
    };

    /// No-op logger that discards all messages. Zero cost.
    /// min_level is set above all levels so convenience methods short-circuit.
    pub const noop: Logger = .{
        .ptr = null,
        .vtable = &noop_vtable,
        .scope = "",
        .min_level = std.math.maxInt(u8),
    };
    fn noopLog(_: ?*anyopaque, _: Level, _: []const u8, _: []const u8, _: []const Field) void {}
    const noop_vtable: VTable = .{ .log = noopLog };

    /// Log a message at the given level.
    pub fn log(self: Logger, level: Level, message: []const u8, fields: []const Field) void {
        self.vtable.log(self.ptr, level, self.scope, message, fields);
    }

    // Convenience methods
    /// Log a message at trace level. Skipped if min_level is above trace.
    pub fn trace(self: Logger, message: []const u8, fields: []const Field) void {
        if (@intFromEnum(Level.trace) >= self.min_level) self.log(.trace, message, fields);
    }

    /// Log a message at debug level. Skipped if min_level is above debug.
    pub fn debug(self: Logger, message: []const u8, fields: []const Field) void {
        if (@intFromEnum(Level.debug) >= self.min_level) self.log(.debug, message, fields);
    }

    /// Log a message at info level. Skipped if min_level is above info.
    pub fn info(self: Logger, message: []const u8, fields: []const Field) void {
        if (@intFromEnum(Level.info) >= self.min_level) self.log(.info, message, fields);
    }

    /// Log a message at warn level. Skipped if min_level is above warn.
    pub fn warn(self: Logger, message: []const u8, fields: []const Field) void {
        if (@intFromEnum(Level.warn) >= self.min_level) self.log(.warn, message, fields);
    }

    /// Log a message at error level. Skipped if min_level is above error.
    pub fn err(self: Logger, message: []const u8, fields: []const Field) void {
        if (@intFromEnum(Level.err) >= self.min_level) self.log(.err, message, fields);
    }

    /// Return a new Logger with the given scope tag.
    /// Performs no allocation; copies the struct with a different scope.
    pub fn withScope(self: Logger, scope: []const u8) Logger {
        var new = self;
        new.scope = scope;
        return new;
    }

    /// Return a new Logger that prepends `base_fields` to every log call.
    /// The returned `WithFieldsLogger` must outlive the returned `Logger`.
    pub fn withFields(self: Logger, allocator: std.mem.Allocator, base_fields: []const Field) !*WithFieldsLogger {
        const wf = try allocator.create(WithFieldsLogger);
        wf.* = .{
            .inner = self,
            .base_fields = base_fields,
            .allocator = allocator,
        };
        return wf;
    }
};

/// A Logger wrapper that prepends base fields to every log call.
pub const WithFieldsLogger = struct {
    inner: Logger,
    base_fields: []const Field,
    allocator: std.mem.Allocator,

    const vtable_impl: Logger.VTable = .{
        .log = logImpl,
    };

    fn logImpl(ptr: ?*anyopaque, level: Level, scope: []const u8, message: []const u8, fields: []const Field) void {
        const self: *WithFieldsLogger = @ptrCast(@alignCast(ptr.?));

        // Concatenate base_fields + call-site fields into a stack buffer.
        // 16 entries covers all realistic instrumentation sites.
        var buf: [16]Field = undefined;
        const total = self.base_fields.len + fields.len;

        if (total <= buf.len) {
            @memcpy(buf[0..self.base_fields.len], self.base_fields);
            @memcpy(buf[self.base_fields.len..][0..fields.len], fields);
            // Pass scope through to inner vtable directly, preserving caller's scope.
            self.inner.vtable.log(self.inner.ptr, level, scope, message, buf[0..total]);
        } else {
            // Fallback: heap allocate the combined slice.
            const combined = self.allocator.alloc(Field, total) catch {
                // On OOM, log without base fields rather than losing the message.
                self.inner.vtable.log(self.inner.ptr, level, scope, message, fields);
                return;
            };
            defer self.allocator.free(combined);
            @memcpy(combined[0..self.base_fields.len], self.base_fields);
            @memcpy(combined[self.base_fields.len..], fields);
            self.inner.vtable.log(self.inner.ptr, level, scope, message, combined);
        }
    }

    /// Obtain a `Logger` backed by this instance.
    /// Preserves the scope and min_level from the inner logger.
    pub fn logger(self: *WithFieldsLogger) Logger {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable_impl,
            .scope = self.inner.scope,
            .min_level = self.inner.min_level,
        };
    }

    /// Destroy this WithFieldsLogger, freeing the backing allocation.
    pub fn deinit(self: *WithFieldsLogger) void {
        self.allocator.destroy(self);
    }
};

// Built-in JSON stdout logger
/// A Logger implementation that writes one JSON object per line to stdout.
///
/// Format: `{"ts":"2025-02-09T18:30:00.123456789Z","level":"info","scope":"...","msg":"...","key":"val"}\n`
///
/// Thread-safe: each line is built in a stack buffer and written atomically.
pub const JsonStdoutLogger = struct {
    io: std.Io,
    min_level: Level,

    const vtable_impl: Logger.VTable = .{
        .log = logImpl,
    };

    /// Create a new JSON stdout logger that filters messages below `min_level`.
    pub fn init(io: std.Io, min_level: Level) JsonStdoutLogger {
        return .{ .io = io, .min_level = min_level };
    }

    /// Obtain a `Logger` backed by this instance.
    pub fn logger(self: *JsonStdoutLogger) Logger {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable_impl,
            .min_level = @intFromEnum(self.min_level),
        };
    }

    fn logImpl(ptr: ?*anyopaque, level: Level, scope: []const u8, message: []const u8, fields: []const Field) void {
        const self: *JsonStdoutLogger = @ptrCast(@alignCast(ptr.?));
        if (level.order() < self.min_level.order()) return;

        var buf: [4096]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);

        writeJsonLine(self.io, &w, level, scope, message, fields) catch return;

        const out = w.buffered();
        const stdout = std.Io.File.stdout();
        stdout.writeStreamingAll(self.io, out) catch {};
    }
};

/// Write a single JSON log line to the given writer. Shared between
/// JsonStdoutLogger and the test writer logger.
fn writeJsonLine(io: std.Io, w: anytype, level: Level, scope: []const u8, message: []const u8, fields: []const Field) !void {
    try w.writeAll("{\"ts\":\"");
    try time_mod.writeNow(io, .nanos, w);
    try w.writeByte('"');
    try w.writeAll(",\"level\":\"");
    try w.writeAll(level.asText());
    try w.writeByte('"');

    if (scope.len > 0) {
        try w.writeAll(",\"scope\":");
        try writeJsonString(w, scope);
    }

    try w.writeAll(",\"msg\":");
    try writeJsonString(w, message);

    for (fields) |field| {
        try w.writeByte(',');
        try writeJsonString(w, field.key);
        try w.writeByte(':');
        switch (field.value) {
            .string => |s| try writeJsonString(w, s),
            .int => |v| try w.print("{d}", .{v}),
            .uint => |v| try w.print("{d}", .{v}),
            .float => |v| try w.print("{d}", .{v}),
            .boolean => |v| try w.writeAll(if (v) "true" else "false"),
        }
    }

    try w.writeAll("}\n");
}

/// Write a JSON-escaped string (with surrounding quotes) to the writer.
fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try w.print("\\u{x:0>4}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    try w.writeByte('"');
}

// Built-in plain-text stdout logger
/// A Logger implementation that writes human-readable log lines to stdout.
///
/// Format: `2025-02-09T18:30:00.123456789Z [level][scope] message  key=value key=value\n`
///
/// Thread-safe: each line is built in a stack buffer and written atomically.
pub const TextStdoutLogger = struct {
    io: std.Io,
    min_level: Level,

    const vtable_impl: Logger.VTable = .{
        .log = logImpl,
    };

    /// Create a new plain-text stdout logger that filters messages below `min_level`.
    pub fn init(io: std.Io, min_level: Level) TextStdoutLogger {
        return .{ .io = io, .min_level = min_level };
    }

    /// Obtain a `Logger` backed by this instance.
    pub fn logger(self: *TextStdoutLogger) Logger {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable_impl,
            .min_level = @intFromEnum(self.min_level),
        };
    }

    fn logImpl(ptr: ?*anyopaque, level: Level, scope: []const u8, message: []const u8, fields: []const Field) void {
        const self: *TextStdoutLogger = @ptrCast(@alignCast(ptr.?));
        if (level.order() < self.min_level.order()) return;

        var buf: [4096]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);

        writeTextLine(self.io, &w, level, scope, message, fields) catch return;

        const out = w.buffered();
        const stdout = std.Io.File.stdout();
        stdout.writeStreamingAll(self.io, out) catch {};
    }
};

/// Write a text string with newlines and control characters escaped.
/// Keeps printable characters as-is for human readability.
fn writeEscapedText(w: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try w.print("\\x{x:0>2}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
}

/// Write a single plain-text log line to the given writer.
fn writeTextLine(io: std.Io, w: anytype, level: Level, scope: []const u8, message: []const u8, fields: []const Field) !void {
    try time_mod.writeNow(io, .nanos, w);
    try w.writeByte(' ');
    try w.writeAll(level.asTextUpper());

    if (scope.len > 0) {
        try w.writeByte(' ');
        try writeEscapedText(w, scope);
    }

    try w.writeAll(" \"");
    try writeEscapedText(w, message);
    try w.writeByte('"');

    for (fields) |field| {
        try w.writeByte(' ');
        try w.writeAll(field.key);
        try w.writeByte('=');
        switch (field.value) {
            .string => |s| try writeEscapedText(w, s),
            .int => |v| try w.print("{d}", .{v}),
            .uint => |v| try w.print("{d}", .{v}),
            .float => |v| try w.print("{d}", .{v}),
            .boolean => |v| try w.writeAll(if (v) "true" else "false"),
        }
    }

    try w.writeByte('\n');
}

test "Level ordering: trace < debug < info < warn < err" {
    // Act / Assert
    try testing.expect(Level.trace.order() < Level.debug.order());
    try testing.expect(Level.debug.order() < Level.info.order());
    try testing.expect(Level.info.order() < Level.warn.order());
    try testing.expect(Level.warn.order() < Level.err.order());
}

test "Level.asText returns correct strings" {
    // Act / Assert
    try testing.expectEqualStrings("trace", Level.trace.asText());
    try testing.expectEqualStrings("debug", Level.debug.asText());
    try testing.expectEqualStrings("info", Level.info.asText());
    try testing.expectEqualStrings("warn", Level.warn.asText());
    try testing.expectEqualStrings("error", Level.err.asText());
}

test "Level.asTextUpper returns uppercase strings" {
    // Act / Assert
    try testing.expectEqualStrings("TRACE", Level.trace.asTextUpper());
    try testing.expectEqualStrings("DEBUG", Level.debug.asTextUpper());
    try testing.expectEqualStrings("INFO", Level.info.asTextUpper());
    try testing.expectEqualStrings("WARN", Level.warn.asTextUpper());
    try testing.expectEqualStrings("ERROR", Level.err.asTextUpper());
}

test "Logger.noop: calling all methods is safe, no output" {
    // Act / Assert
    const l = Logger.noop;
    l.trace("test", &.{});
    l.debug("test", &.{});
    l.info("test", &.{});
    l.warn("test", &.{});
    l.err("test", &.{});
    l.log(.info, "test", &.{Field.string("k", "v")});
}

test "Logger.noop: min_level short-circuits all convenience methods" {
    // Act / Assert
    const l = Logger.noop;
    // noop min_level is maxInt(u8), so all convenience methods should short-circuit.
    try testing.expect(l.min_level == std.math.maxInt(u8));
}

test "Field helpers: construct correct values" {
    // Arrange
    const s = Field.string("k", "v");
    try testing.expectEqualStrings("k", s.key);
    try testing.expectEqualStrings("v", s.value.string);

    // Act
    const i = Field.int("k", -42);
    try testing.expectEqual(@as(i64, -42), i.value.int);

    // Assert
    const u = Field.uint("k", 100);
    try testing.expectEqual(@as(u64, 100), u.value.uint);

    const f = Field.float("k", 3.14);
    try testing.expectEqual(@as(f64, 3.14), f.value.float);

    const b = Field.boolean("k", true);
    try testing.expect(b.value.boolean);

    const e = Field.err("k", error.OutOfMemory);
    try testing.expectEqualStrings("OutOfMemory", e.value.string);
}

// Test logger that captures output
const TestLogger = struct {
    buf: std.ArrayList(u8),
    allocator: std.mem.Allocator,
    io: std.Io,
    min_level: Level,

    const vtable_impl: Logger.VTable = .{
        .log = logImpl,
    };

    fn init(allocator: std.mem.Allocator, io: std.Io, min_level: Level) TestLogger {
        return .{
            .buf = .empty,
            .allocator = allocator,
            .io = io,
            .min_level = min_level,
        };
    }

    fn deinit(self: *TestLogger) void {
        self.buf.deinit(self.allocator);
    }

    fn getLogger(self: *TestLogger) Logger {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable_impl,
            .min_level = @intFromEnum(self.min_level),
        };
    }

    fn logImpl(ptr: ?*anyopaque, level: Level, scope: []const u8, message: []const u8, fields: []const Field) void {
        const self: *TestLogger = @ptrCast(@alignCast(ptr.?));
        if (level.order() < self.min_level.order()) return;
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        writeJsonLine(self.io, &aw.writer, level, scope, message, fields) catch return;
        self.buf.appendSlice(self.allocator, aw.written()) catch return;
    }

    fn output(self: *const TestLogger) []const u8 {
        return self.buf.items;
    }
};

test "JsonStdoutLogger: respects min level filtering" {
    // Arrange
    // Use TestLogger to validate level filtering logic (same as JsonStdoutLogger).
    var tl = TestLogger.init(testing.allocator, testing.io, .info);
    defer tl.deinit();
    const l = tl.getLogger();

    // Act
    l.debug("should be filtered", &.{});
    try testing.expectEqual(@as(usize, 0), tl.output().len);

    // Assert
    l.info("should appear", &.{});
    try testing.expect(tl.output().len > 0);
}

test "JsonStdoutLogger: JSON output parses correctly and includes all fields" {
    // Arrange
    var tl = TestLogger.init(testing.allocator, testing.io, .debug);
    defer tl.deinit();
    const l = tl.getLogger();

    // Act
    l.info("test message", &.{
        Field.string("string_field", "hello"),
        Field.int("int_field", -42),
        Field.uint("uint_field", 100),
        Field.boolean("bool_field", true),
    });

    // Assert
    const output = tl.output();
    try testing.expect(output.len > 0);

    // Parse the JSON line.
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, output, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    try testing.expectEqualStrings("info", obj.get("level").?.string);
    try testing.expectEqualStrings("test message", obj.get("msg").?.string);
    try testing.expectEqualStrings("hello", obj.get("string_field").?.string);
    try testing.expectEqual(@as(i64, -42), obj.get("int_field").?.integer);
    try testing.expectEqual(@as(i64, 100), obj.get("uint_field").?.integer);
    try testing.expect(obj.get("bool_field").?.bool);

    // Verify "ts" is an RFC 3339 string with nanosecond precision.
    const ts = obj.get("ts").?.string;
    try testing.expectEqual(@as(usize, 30), ts.len);
    try testing.expect(ts[29] == 'Z');
    try testing.expect(ts[10] == 'T');
    try testing.expect(ts[4] == '-');
    try testing.expect(ts[19] == '.');
}

test "FieldValue union: each variant serializes correctly in JSON" {
    // Arrange
    var tl = TestLogger.init(testing.allocator, testing.io, .debug);
    defer tl.deinit();
    const l = tl.getLogger();

    // Act
    // String
    l.info("s", &.{Field.string("k", "val")});
    // Int
    l.info("i", &.{Field.int("k", -1)});
    // Uint
    l.info("u", &.{Field.uint("k", 99)});
    // Float
    l.info("f", &.{Field.float("k", 3.14)});
    // Bool
    l.info("b", &.{Field.boolean("k", false)});

    // Assert
    // Each line should be valid JSON.
    var it = std.mem.splitScalar(u8, tl.output(), '\n');
    var count: usize = 0;
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
        defer parsed.deinit();
        count += 1;
    }
    try testing.expectEqual(@as(usize, 5), count);
}

test "withFields: base fields appear in every log call alongside call-site fields" {
    // Arrange
    var tl = TestLogger.init(testing.allocator, testing.io, .debug);
    defer tl.deinit();
    const l = tl.getLogger();

    // Act
    const base_fields = [_]Field{
        Field.string("component", "reflector"),
        Field.string("resource", "pods"),
    };

    // Assert
    const wf = try l.withFields(testing.allocator, &base_fields);
    defer wf.deinit();
    const wl = wf.logger();

    wl.info("something happened", &.{
        Field.uint("count", 42),
    });

    const output = tl.output();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, output, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    // Base fields present.
    try testing.expectEqualStrings("reflector", obj.get("component").?.string);
    try testing.expectEqualStrings("pods", obj.get("resource").?.string);
    // Call-site field present.
    try testing.expectEqual(@as(i64, 42), obj.get("count").?.integer);
    // Message present.
    try testing.expectEqualStrings("something happened", obj.get("msg").?.string);
}

test "writeJsonString: escapes special characters" {
    // Arrange
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    // Act / Assert
    try writeJsonString(&w, "hello \"world\"\nline2\ttab\\back");
    const result = w.buffered();
    try testing.expectEqualStrings("\"hello \\\"world\\\"\\nline2\\ttab\\\\back\"", result);
}

test "JsonStdoutLogger: init and logger method" {
    // Act / Assert
    var jsl = JsonStdoutLogger.init(testing.io, .warn);
    const l = jsl.logger();
    // Verify the vtable-based Logger is correctly wired.
    try testing.expect(l.ptr != null);
    try testing.expect(l.vtable == &JsonStdoutLogger.vtable_impl);
    // Verify min level is stored on the Logger for early short-circuit.
    try testing.expectEqual(@as(u8, @intFromEnum(Level.warn)), l.min_level);
    // Verify min level is stored.
    try testing.expectEqual(Level.warn, jsl.min_level);
    // Note: we do NOT call l.warn/l.err here because the JsonStdoutLogger
    // writes to actual stdout, which interferes with `zig build test`'s
    // --listen protocol. Use TestLogger for output verification instead.
}

test "withScope: scope appears in JSON output" {
    // Arrange
    var tl = TestLogger.init(testing.allocator, testing.io, .debug);
    defer tl.deinit();
    const l = tl.getLogger().withScope("reflector");

    // Act
    l.info("test", &.{});

    // Assert
    const output = tl.output();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, output, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    try testing.expectEqualStrings("reflector", obj.get("scope").?.string);
}

test "withScope: empty scope omits scope key" {
    // Arrange
    var tl = TestLogger.init(testing.allocator, testing.io, .debug);
    defer tl.deinit();
    const l = tl.getLogger();

    // Act
    l.info("test", &.{});

    // Assert
    const output = tl.output();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, output, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    try testing.expect(obj.get("scope") == null);
}

test "withScope: preserved through withFields" {
    // Arrange
    var tl = TestLogger.init(testing.allocator, testing.io, .debug);
    defer tl.deinit();
    const scoped = tl.getLogger().withScope("controller");

    // Act
    const base_fields = [_]Field{Field.string("key", "val")};
    const wf = try scoped.withFields(testing.allocator, &base_fields);
    defer wf.deinit();
    const l = wf.logger();

    // Assert
    l.info("test", &.{});

    const output = tl.output();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, output, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    try testing.expectEqualStrings("controller", obj.get("scope").?.string);
    try testing.expectEqualStrings("val", obj.get("key").?.string);
}

test "TextStdoutLogger: init and logger method" {
    // Act / Assert
    var tsl = TextStdoutLogger.init(testing.io, .info);
    const l = tsl.logger();
    try testing.expect(l.ptr != null);
    try testing.expect(l.vtable == &TextStdoutLogger.vtable_impl);
    try testing.expectEqual(@as(u8, @intFromEnum(Level.info)), l.min_level);
}

test "writeTextLine: formats plain text correctly" {
    // Arrange
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    // Act / Assert
    try writeTextLine(std.testing.io, &w, .info, "", "hello world", &.{});
    const output = w.buffered();
    // 30-byte RFC 3339 timestamp + space prefix.
    try testing.expect(output.len >= 31);
    try testing.expect(output[30] == ' ');
    try testing.expect(output[29] == 'Z');
    try testing.expect(output[10] == 'T');
    try testing.expectEqualStrings("INFO \"hello world\"\n", output[31..]);
}

test "writeTextLine: includes scope" {
    // Arrange
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    // Act / Assert
    try writeTextLine(std.testing.io, &w, .warn, "reflector", "watch ended", &.{});
    const output = w.buffered();
    try testing.expect(output.len >= 31);
    try testing.expectEqualStrings("WARN reflector \"watch ended\"\n", output[31..]);
}

test "writeTextLine: includes fields" {
    // Arrange
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    // Act / Assert
    try writeTextLine(std.testing.io, &w, .info, "informer", "list completed", &.{
        Field.string("resource", "pods"),
        Field.uint("count", 5),
    });
    const output = w.buffered();
    try testing.expect(output.len >= 31);
    try testing.expectEqualStrings("INFO informer \"list completed\" resource=pods count=5\n", output[31..]);
}

test "writeEscapedText: escapes newlines and control characters" {
    // Arrange
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    // Act
    try writeEscapedText(&w, "hello\nworld\r\ttab\x01end");

    // Assert
    try testing.expectEqualStrings("hello\\nworld\\r\\ttab\\x01end", w.buffered());
}

test "writeTextLine: escapes control characters in string field values" {
    // Arrange
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    // Act
    try writeTextLine(std.testing.io, &w, .info, "", "msg", &.{
        Field.string("val", "line1\nline2"),
    });

    // Assert
    const output = w.buffered();
    try testing.expectEqualStrings("INFO \"msg\" val=line1\\nline2\n", output[31..]);
}

test "min_level: early level check skips vtable dispatch" {
    // Arrange
    var tl = TestLogger.init(testing.allocator, testing.io, .warn);
    defer tl.deinit();
    const l = tl.getLogger();

    // Act
    // trace, debug and info should be filtered by min_level before vtable dispatch.
    l.trace("filtered", &.{});
    l.debug("filtered", &.{});
    l.info("filtered", &.{});
    try testing.expectEqual(@as(usize, 0), tl.output().len);

    // Assert
    // warn and err should pass through.
    l.warn("visible", &.{});
    try testing.expect(tl.output().len > 0);
}
