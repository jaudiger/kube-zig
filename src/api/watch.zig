//! Kubernetes watch stream for observing resource changes in real time.
//!
//! Provides `WatchStream(T)`, a line-based iterator over a streaming HTTP
//! response that yields typed `WatchEvent(T)` values (ADDED, MODIFIED,
//! DELETED, BOOKMARK, ERROR). Uses two-phase JSON parsing to handle
//! bookmark objects that contain null values for required fields.

const std = @import("std");
const client_mod = @import("../client/Client.zig");
const Client = client_mod.Client;
const Context = client_mod.Context;
const StreamState = client_mod.StreamState;
const Io = std.Io;
const Logger = @import("../util/logging.zig").Logger;
const LogField = @import("../util/logging.zig").Field;
const testing = std.testing;

/// Typed Kubernetes watch event.
pub fn WatchEvent(comptime T: type) type {
    return union(enum) {
        added: T,
        modified: T,
        deleted: T,
        bookmark: Bookmark,
        api_error: ApiError,

        /// Bookmark event containing only a resourceVersion for efficient reconnection.
        pub const Bookmark = struct {
            resource_version: []const u8,
        };

        /// Error event from the Kubernetes API, e.g. 410 Gone when
        /// the requested resourceVersion is too old.
        pub const ApiError = struct {
            code: ?i64 = null,
            reason: ?[]const u8 = null,
            message: ?[]const u8 = null,
        };
    };
}

/// Parsed watch event with arena-based memory ownership.
/// The caller must call `deinit()` when done to free all memory
/// allocated during parsing, following the `std.json.Parsed(T)` pattern.
pub fn ParsedEvent(comptime T: type) type {
    return struct {
        event: WatchEvent(T),
        arena: *std.heap.ArenaAllocator,

        /// Free the arena and all memory allocated during parsing.
        pub fn deinit(self: @This()) void {
            const child = self.arena.child_allocator;
            self.arena.deinit();
            child.destroy(self.arena);
        }
    };
}

/// Intermediate raw type for JSON parsing of a watch event line.
fn WatchEventRaw(comptime T: type) type {
    return struct {
        type: []const u8,
        object: T,
    };
}

/// Raw type for parsing ERROR events where the object is a Status.
const ErrorObjectRaw = struct {
    type: []const u8,
    object: struct {
        code: ?i64 = null,
        reason: ?[]const u8 = null,
        message: ?[]const u8 = null,
    },
};

/// Slim type for phase-1 parsing: extract only the event type string,
/// skipping the object value entirely.
const EventTypeRaw = struct {
    type: []const u8,
};

/// Slim type for parsing BOOKMARK events without deserializing the full
/// resource object. Kubernetes bookmark events contain minimal objects
/// that may have null values for required fields (e.g. `"containers": null`),
/// which would fail full-type deserialization.
const BookmarkObjectRaw = struct {
    type: []const u8,
    object: struct {
        metadata: ?struct {
            resourceVersion: ?[]const u8 = null,
        } = null,
    },
};

/// Parse a single JSON line into a `ParsedEvent(T)`.
///
/// Use a two-phase parse strategy:
///   1. Extract the event `type` string using a slim struct.
///   2. Parse the `object` only as the type appropriate for that event:
///      `T` for ADDED/MODIFIED/DELETED, a slim bookmark struct for BOOKMARK,
///      and a status struct for ERROR.
///
/// This avoids deserializing bookmark objects into the full resource type,
/// which would fail because Kubernetes sends minimal bookmark objects with
/// null values for required fields (e.g. `"spec":{"containers":null}`).
pub fn parseEventLine(comptime T: type, allocator: std.mem.Allocator, line: []const u8) !ParsedEvent(T) {
    const arena_ptr = try allocator.create(std.heap.ArenaAllocator);
    arena_ptr.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        arena_ptr.deinit();
        allocator.destroy(arena_ptr);
    }

    const arena_alloc = arena_ptr.allocator();
    const parse_opts: std.json.ParseOptions = .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    };

    // Phase 1: Extract only the event type without parsing the full object.
    const event_type = (std.json.parseFromSliceLeaky(
        EventTypeRaw,
        arena_alloc,
        line,
        parse_opts,
    ) catch return error.JsonParseFailed).type;

    // Phase 2: Parse the object using the type appropriate for this event kind.
    if (std.mem.eql(u8, event_type, "ADDED") or
        std.mem.eql(u8, event_type, "MODIFIED") or
        std.mem.eql(u8, event_type, "DELETED"))
    {
        const raw = std.json.parseFromSliceLeaky(
            WatchEventRaw(T),
            arena_alloc,
            line,
            parse_opts,
        ) catch return error.JsonParseFailed;

        const event: WatchEvent(T) = if (std.mem.eql(u8, event_type, "ADDED"))
            .{ .added = raw.object }
        else if (std.mem.eql(u8, event_type, "MODIFIED"))
            .{ .modified = raw.object }
        else
            .{ .deleted = raw.object };

        return .{ .event = event, .arena = arena_ptr };
    } else if (std.mem.eql(u8, event_type, "BOOKMARK")) {
        const bm_raw = std.json.parseFromSliceLeaky(
            BookmarkObjectRaw,
            arena_alloc,
            line,
            parse_opts,
        ) catch return error.JsonParseFailed;

        const rv = if (bm_raw.object.metadata) |meta| meta.resourceVersion else null;
        return .{
            .event = .{ .bookmark = .{ .resource_version = rv orelse return error.JsonParseFailed } },
            .arena = arena_ptr,
        };
    } else if (std.mem.eql(u8, event_type, "ERROR")) {
        const error_raw = std.json.parseFromSliceLeaky(
            ErrorObjectRaw,
            arena_alloc,
            line,
            parse_opts,
        ) catch return error.JsonParseFailed;
        return .{
            .event = .{ .api_error = .{
                .code = error_raw.object.code,
                .reason = error_raw.object.reason,
                .message = error_raw.object.message,
            } },
            .arena = arena_ptr,
        };
    } else {
        return error.UnknownEventType;
    }
}

/// Extract the resourceVersion from an object's metadata, if present.
fn extractResourceVersion(comptime T: type, object: T) ?[]const u8 {
    if (@hasField(T, "metadata")) {
        if (object.metadata) |meta| {
            const MetaType = @TypeOf(meta);
            if (@hasField(MetaType, "resourceVersion")) {
                return meta.resourceVersion;
            }
        }
    }
    return null;
}

/// Extract the resourceVersion from a typed watch event's object.
fn extractEventResourceVersion(comptime T: type, event: WatchEvent(T)) ?[]const u8 {
    return switch (event) {
        .added => |obj| extractResourceVersion(T, obj),
        .modified => |obj| extractResourceVersion(T, obj),
        .deleted => |obj| extractResourceVersion(T, obj),
        .bookmark => |bm| bm.resource_version,
        .api_error => null,
    };
}

/// Iterator over a Kubernetes watch stream that yields typed events.
///
/// Example:
/// ```zig
/// var stream = try api.watch(.{});
/// defer stream.close();
/// while (try stream.next()) |event| {
///     defer event.deinit();
///     switch (event.event) { ... }
/// }
/// ```
pub fn WatchStream(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Event = WatchEvent(T);

        /// Default maximum bytes allowed for a single watch event line (4 MiB).
        pub const default_max_line_size: usize = 4 * 1024 * 1024;

        allocator: std.mem.Allocator,
        client: *Client,
        ctx: Context,
        state: *StreamState,
        last_resource_version: ?[]const u8,
        closed: bool,
        max_line_size: usize,

        /// Initialize a watch stream by opening an HTTP streaming connection.
        pub fn init(client_ptr: *Client, ctx: Context, path: []const u8, max_line_size: usize) !Self {
            client_ptr.logger.info("watch started", &.{});
            const stream_resp = try client_ptr.watchStream(path, ctx);
            return .{
                .allocator = client_ptr.allocator,
                .client = client_ptr,
                .ctx = ctx,
                .state = stream_resp.state,
                .last_resource_version = null,
                .closed = false,
                .max_line_size = max_line_size,
            };
        }

        /// Read the next watch event from the stream.
        /// Return `null` on clean end-of-stream (server timeout or connection close).
        /// The caller must call `deinit()` on the returned `ParsedEvent`.
        pub fn next(self: *Self) !?ParsedEvent(T) {
            if (self.closed) return null;
            self.ctx.check() catch return error.Canceled;

            const line = self.readLine() catch |err| switch (err) {
                error.EndOfStream => return null,
                else => return err,
            };
            defer self.allocator.free(line);

            if (line.len == 0) return null;

            const parsed = parseEventLine(T, self.allocator, line) catch |err| {
                self.client.logger.warn("watch event parse failed", &.{
                    LogField.string("error", @errorName(err)),
                    LogField.uint("line_len", line.len),
                    LogField.string("line_prefix", if (line.len > 200) line[0..200] else line),
                });
                return err;
            };
            errdefer parsed.deinit();

            // Log watch error events.
            switch (parsed.event) {
                .api_error => |api_err| {
                    self.client.logger.warn("watch error event", &.{
                        LogField.uint("code", if (api_err.code) |c| std.math.cast(u64, c) orelse 0 else 0),
                        LogField.string("reason", api_err.reason orelse ""),
                        LogField.string("message", api_err.message orelse ""),
                    });
                },
                else => {},
            }

            // Update last_resource_version for reconnection.
            const rv = extractEventResourceVersion(T, parsed.event);
            if (rv) |new_rv| {
                // Copy into our own allocator since parsed event's arena owns the original.
                const owned_rv = try self.allocator.dupe(u8, new_rv);
                if (self.last_resource_version) |old| self.allocator.free(old);
                self.last_resource_version = owned_rv;
            }

            return parsed;
        }

        /// Return the last observed resourceVersion for reconnection.
        pub fn resourceVersion(self: *const Self) ?[]const u8 {
            return self.last_resource_version;
        }

        /// Close the watch stream and release all resources.
        pub fn close(self: *Self) void {
            if (self.closed) return;
            self.closed = true;
            self.client.logger.debug("watch stream closed", &.{
                LogField.string("last_resource_version", self.last_resource_version orelse ""),
            });
            if (self.last_resource_version) |rv| {
                self.allocator.free(rv);
                self.last_resource_version = null;
            }
            self.state.deinit();
        }

        /// Shut down the underlying socket, causing any blocked `read()`
        /// in `next()` to return immediately. Safe to call from another thread.
        pub fn interrupt(self: *Self) void {
            self.state.interrupt();
        }

        fn readLine(self: *Self) ![]const u8 {
            const reader = self.state.reader orelse return error.EndOfStream;

            var line_writer = Io.Writer.Allocating.init(self.allocator);
            errdefer line_writer.deinit();

            // Read until we find a newline delimiter, bounded by max_line_size.
            // Using streamDelimiterLimit enforces the limit during streaming,
            // preventing unbounded allocation from a malicious server.
            const n = reader.streamDelimiterLimit(&line_writer.writer, '\n', Io.Limit.limited(self.max_line_size)) catch |err| switch (err) {
                error.ReadFailed => return error.ConnectionResetByPeer,
                error.WriteFailed => return error.OutOfMemory,
                error.StreamTooLong => return error.LineTooLong,
            };

            // If the reader buffer still has data, the first byte is the delimiter; consume it.
            // If the buffer is empty, we hit EOF.
            if (reader.bufferedLen() > 0) {
                reader.toss(1); // consume the '\n' delimiter
            } else if (n == 0) {
                // No data and no delimiter found: clean end of stream.
                // errdefer will handle line_writer cleanup.
                return error.EndOfStream;
            }
            // else: EOF with partial line data, return what we have.

            return line_writer.toOwnedSlice() catch return error.OutOfMemory;
        }
    };
}

const TestResource = @import("../test_types.zig").TestResource;

/// A resource type with a required (non-optional) slice field, mirroring
/// CoreV1PodSpec.containers which has no default and cannot accept null.
/// Used to test two-phase parsing of BOOKMARKs with strict resource types.
const StrictResource = struct {
    metadata: ?StrictMeta = null,
    spec: ?StrictSpec = null,

    const StrictMeta = struct {
        name: ?[]const u8 = null,
        resourceVersion: ?[]const u8 = null,
    };
    const StrictSpec = struct {
        containers: []const StrictContainer,

        const StrictContainer = struct {
            name: []const u8,
        };
    };
};

/// A minimal resource with no metadata field at all, for testing
/// extractResourceVersion on types that lack metadata.
const NoMetadataResource = struct {
    kind: ?[]const u8 = null,
};

// Comptime instantiation tests
test "WatchEvent, ParsedEvent, and WatchStream types can be instantiated at comptime" {
    // Act / Assert
    comptime {
        _ = WatchEvent(TestResource);
        _ = ParsedEvent(TestResource);
        _ = WatchStream(TestResource);
    }
}

// ADDED event tests
test "parseEventLine: ADDED event parses object fields and metadata" {
    // Arrange
    const allocator = testing.allocator;
    const line =
        \\{"type":"ADDED","object":{"metadata":{"name":"my-pod","resourceVersion":"100"},"spec":{"replicas":3}}}
    ;

    // Act
    const parsed = try parseEventLine(TestResource, allocator, line);
    defer parsed.deinit();

    // Assert
    try testing.expect(parsed.event == .added);
    const obj = parsed.event.added;
    try testing.expectEqualStrings("my-pod", obj.metadata.?.name.?);
    try testing.expectEqualStrings("100", obj.metadata.?.resourceVersion.?);
    try testing.expectEqual(@as(i64, 3), obj.spec.?.replicas.?);
}

test "parseEventLine: ADDED event with no metadata leaves metadata null" {
    // Arrange
    const allocator = testing.allocator;
    const line =
        \\{"type":"ADDED","object":{"spec":{"replicas":1}}}
    ;

    // Act
    const parsed = try parseEventLine(TestResource, allocator, line);
    defer parsed.deinit();

    // Assert
    try testing.expect(parsed.event == .added);
    try testing.expect(parsed.event.added.metadata == null);
    try testing.expectEqual(@as(i64, 1), parsed.event.added.spec.?.replicas.?);
}

test "parseEventLine: ADDED event with empty object parses successfully" {
    // Arrange
    const allocator = testing.allocator;
    const line =
        \\{"type":"ADDED","object":{}}
    ;

    // Act
    const parsed = try parseEventLine(TestResource, allocator, line);
    defer parsed.deinit();

    // Assert
    try testing.expect(parsed.event == .added);
    try testing.expect(parsed.event.added.metadata == null);
    try testing.expect(parsed.event.added.spec == null);
}

test "parseEventLine: ADDED event ignores unknown fields" {
    // Arrange
    const allocator = testing.allocator;
    const line =
        \\{"type":"ADDED","object":{"metadata":{"name":"pod-1","unknownField":"value"},"unknownTop":"x"}}
    ;

    // Act
    const parsed = try parseEventLine(TestResource, allocator, line);
    defer parsed.deinit();

    // Assert
    try testing.expect(parsed.event == .added);
    try testing.expectEqualStrings("pod-1", parsed.event.added.metadata.?.name.?);
}

test "parseEventLine: ADDED event with strict resource parses containers" {
    // Arrange
    const allocator = testing.allocator;
    const line =
        \\{"type":"ADDED","object":{"metadata":{"name":"pod-1","resourceVersion":"42"},"spec":{"containers":[{"name":"nginx"}]}}}
    ;

    // Act
    const parsed = try parseEventLine(StrictResource, allocator, line);
    defer parsed.deinit();

    // Assert
    try testing.expect(parsed.event == .added);
    const obj = parsed.event.added;
    try testing.expectEqualStrings("pod-1", obj.metadata.?.name.?);
    try testing.expectEqual(@as(usize, 1), obj.spec.?.containers.len);
    try testing.expectEqualStrings("nginx", obj.spec.?.containers[0].name);
}

// MODIFIED event tests
test "parseEventLine: MODIFIED event parses object metadata" {
    // Arrange
    const allocator = testing.allocator;
    const line =
        \\{"type":"MODIFIED","object":{"metadata":{"name":"my-pod","resourceVersion":"200"}}}
    ;

    // Act
    const parsed = try parseEventLine(TestResource, allocator, line);
    defer parsed.deinit();

    // Assert
    try testing.expect(parsed.event == .modified);
    try testing.expectEqualStrings("my-pod", parsed.event.modified.metadata.?.name.?);
    try testing.expectEqualStrings("200", parsed.event.modified.metadata.?.resourceVersion.?);
}

test "parseEventLine: MODIFIED event with strict resource parses multiple containers" {
    // Arrange
    const allocator = testing.allocator;
    const line =
        \\{"type":"MODIFIED","object":{"metadata":{"name":"pod-1","resourceVersion":"43"},"spec":{"containers":[{"name":"nginx"},{"name":"sidecar"}]}}}
    ;

    // Act
    const parsed = try parseEventLine(StrictResource, allocator, line);
    defer parsed.deinit();

    // Assert
    try testing.expect(parsed.event == .modified);
    try testing.expectEqual(@as(usize, 2), parsed.event.modified.spec.?.containers.len);
}

// DELETED event tests
test "parseEventLine: DELETED event parses object metadata" {
    // Arrange
    const allocator = testing.allocator;
    const line =
        \\{"type":"DELETED","object":{"metadata":{"name":"my-pod","resourceVersion":"300"}}}
    ;

    // Act
    const parsed = try parseEventLine(TestResource, allocator, line);
    defer parsed.deinit();

    // Assert
    try testing.expect(parsed.event == .deleted);
    try testing.expectEqualStrings("my-pod", parsed.event.deleted.metadata.?.name.?);
}

test "parseEventLine: DELETED event with strict resource parses normally" {
    // Arrange
    const allocator = testing.allocator;
    const line =
        \\{"type":"DELETED","object":{"metadata":{"name":"pod-1","resourceVersion":"44"},"spec":{"containers":[{"name":"nginx"}]}}}
    ;

    // Act
    const parsed = try parseEventLine(StrictResource, allocator, line);
    defer parsed.deinit();

    // Assert
    try testing.expect(parsed.event == .deleted);
    try testing.expectEqualStrings("pod-1", parsed.event.deleted.metadata.?.name.?);
}

// BOOKMARK event tests
test "parseEventLine: BOOKMARK event extracts resourceVersion" {
    // Arrange
    const allocator = testing.allocator;
    const line =
        \\{"type":"BOOKMARK","object":{"metadata":{"resourceVersion":"500"}}}
    ;

    // Act
    const parsed = try parseEventLine(TestResource, allocator, line);
    defer parsed.deinit();

    // Assert
    try testing.expect(parsed.event == .bookmark);
    try testing.expectEqualStrings("500", parsed.event.bookmark.resource_version);
}

test "parseEventLine: BOOKMARK with null required fields in strict resource parses successfully" {
    // Arrange
    const allocator = testing.allocator;
    const line =
        \\{"type":"BOOKMARK","object":{"metadata":{"resourceVersion":"656063322"},"spec":{"containers":null}}}
    ;

    // Act
    const parsed = try parseEventLine(StrictResource, allocator, line);
    defer parsed.deinit();

    // Assert
    try testing.expect(parsed.event == .bookmark);
    try testing.expectEqualStrings("656063322", parsed.event.bookmark.resource_version);
}

test "parseEventLine: BOOKMARK with extra fields is parsed" {
    // Arrange
    const allocator = testing.allocator;
    const line =
        \\{"type":"BOOKMARK","object":{"kind":"Pod","apiVersion":"v1","metadata":{"resourceVersion":"656063322","annotations":{"k8s.io/initial-events-end":"true"}},"spec":{"containers":null},"status":{}}}
    ;

    // Act
    const parsed = try parseEventLine(StrictResource, allocator, line);
    defer parsed.deinit();

    // Assert
    try testing.expect(parsed.event == .bookmark);
    try testing.expectEqualStrings("656063322", parsed.event.bookmark.resource_version);
}

test "parseEventLine: BOOKMARK with missing metadata returns JsonParseFailed" {
    // Arrange
    const allocator = testing.allocator;
    const line =
        \\{"type":"BOOKMARK","object":{}}
    ;

    // Act / Assert
    try testing.expectError(error.JsonParseFailed, parseEventLine(TestResource, allocator, line));
}

test "parseEventLine: BOOKMARK with null resourceVersion returns JsonParseFailed" {
    // Arrange
    const allocator = testing.allocator;
    const line =
        \\{"type":"BOOKMARK","object":{"metadata":{"resourceVersion":null}}}
    ;

    // Act / Assert
    try testing.expectError(error.JsonParseFailed, parseEventLine(TestResource, allocator, line));
}

// ERROR event tests
test "parseEventLine: ERROR event with 410 Gone parses all fields" {
    // Arrange
    const allocator = testing.allocator;
    const line =
        \\{"type":"ERROR","object":{"kind":"Status","apiVersion":"v1","code":410,"reason":"Gone","message":"too old resource version"}}
    ;

    // Act
    const parsed = try parseEventLine(TestResource, allocator, line);
    defer parsed.deinit();

    // Assert
    try testing.expect(parsed.event == .api_error);
    const err = parsed.event.api_error;
    try testing.expectEqual(@as(i64, 410), err.code.?);
    try testing.expectEqualStrings("Gone", err.reason.?);
    try testing.expectEqualStrings("too old resource version", err.message.?);
}

test "parseEventLine: ERROR event with only code leaves reason and message null" {
    // Arrange
    const allocator = testing.allocator;
    const line =
        \\{"type":"ERROR","object":{"code":500}}
    ;

    // Act
    const parsed = try parseEventLine(TestResource, allocator, line);
    defer parsed.deinit();

    // Assert
    try testing.expect(parsed.event == .api_error);
    try testing.expectEqual(@as(i64, 500), parsed.event.api_error.code.?);
    try testing.expect(parsed.event.api_error.reason == null);
    try testing.expect(parsed.event.api_error.message == null);
}

test "parseEventLine: ERROR event with empty object leaves all fields null" {
    // Arrange
    const allocator = testing.allocator;
    const line =
        \\{"type":"ERROR","object":{}}
    ;

    // Act
    const parsed = try parseEventLine(TestResource, allocator, line);
    defer parsed.deinit();

    // Assert
    try testing.expect(parsed.event == .api_error);
    try testing.expect(parsed.event.api_error.code == null);
    try testing.expect(parsed.event.api_error.reason == null);
    try testing.expect(parsed.event.api_error.message == null);
}

// Unknown and malformed event tests
test "parseEventLine: unknown event type returns UnknownEventType" {
    // Arrange
    const allocator = testing.allocator;
    const line =
        \\{"type":"UNKNOWN","object":{"metadata":{"name":"x"}}}
    ;

    // Act / Assert
    try testing.expectError(error.UnknownEventType, parseEventLine(TestResource, allocator, line));
}

test "parseEventLine: lowercase event type returns UnknownEventType" {
    // Arrange
    const allocator = testing.allocator;
    const line =
        \\{"type":"added","object":{"metadata":{"name":"x"}}}
    ;

    // Act / Assert
    try testing.expectError(error.UnknownEventType, parseEventLine(TestResource, allocator, line));
}

test "parseEventLine: empty type string returns UnknownEventType" {
    // Arrange
    const allocator = testing.allocator;
    const line =
        \\{"type":"","object":{}}
    ;

    // Act / Assert
    try testing.expectError(error.UnknownEventType, parseEventLine(TestResource, allocator, line));
}

test "parseEventLine: completely invalid JSON returns JsonParseFailed" {
    // Act / Assert
    try testing.expectError(error.JsonParseFailed, parseEventLine(TestResource, testing.allocator, "not valid json"));
}

test "parseEventLine: empty string returns JsonParseFailed" {
    // Act / Assert
    try testing.expectError(error.JsonParseFailed, parseEventLine(TestResource, testing.allocator, ""));
}

test "parseEventLine: truncated JSON returns JsonParseFailed" {
    // Act
    const line =
        \\{"type":"ADDED","object":{"metadata":{"name":"po
    ;

    // Assert
    try testing.expectError(error.JsonParseFailed, parseEventLine(TestResource, testing.allocator, line));
}

test "parseEventLine: JSON missing type field returns JsonParseFailed" {
    // Act
    const line =
        \\{"object":{"metadata":{"name":"my-pod"}}}
    ;

    // Assert
    try testing.expectError(error.JsonParseFailed, parseEventLine(TestResource, testing.allocator, line));
}

test "parseEventLine: JSON missing object field returns JsonParseFailed" {
    // Act
    const line =
        \\{"type":"ADDED"}
    ;

    // Assert
    try testing.expectError(error.JsonParseFailed, parseEventLine(TestResource, testing.allocator, line));
}

test "parseEventLine: JSON array instead of object returns JsonParseFailed" {
    // Act / Assert
    try testing.expectError(error.JsonParseFailed, parseEventLine(TestResource, testing.allocator, "[1,2,3]"));
}

// extractEventResourceVersion tests
test "extractEventResourceVersion: ADDED event returns resourceVersion" {
    // Arrange
    const line =
        \\{"type":"ADDED","object":{"metadata":{"name":"pod-1","resourceVersion":"42"}}}
    ;
    const parsed = try parseEventLine(TestResource, testing.allocator, line);
    defer parsed.deinit();

    // Act
    const rv = extractEventResourceVersion(TestResource, parsed.event);

    // Assert
    try testing.expectEqualStrings("42", rv.?);
}

test "extractEventResourceVersion: MODIFIED event returns resourceVersion" {
    // Arrange
    const line =
        \\{"type":"MODIFIED","object":{"metadata":{"resourceVersion":"99"}}}
    ;
    const parsed = try parseEventLine(TestResource, testing.allocator, line);
    defer parsed.deinit();

    // Act
    const rv = extractEventResourceVersion(TestResource, parsed.event);

    // Assert
    try testing.expectEqualStrings("99", rv.?);
}

test "extractEventResourceVersion: DELETED event returns resourceVersion" {
    // Arrange
    const line =
        \\{"type":"DELETED","object":{"metadata":{"resourceVersion":"77"}}}
    ;
    const parsed = try parseEventLine(TestResource, testing.allocator, line);
    defer parsed.deinit();

    // Act
    const rv = extractEventResourceVersion(TestResource, parsed.event);

    // Assert
    try testing.expectEqualStrings("77", rv.?);
}

test "extractEventResourceVersion: BOOKMARK event returns resource_version" {
    // Arrange
    const line =
        \\{"type":"BOOKMARK","object":{"metadata":{"resourceVersion":"500"}}}
    ;
    const parsed = try parseEventLine(TestResource, testing.allocator, line);
    defer parsed.deinit();

    // Act
    const rv = extractEventResourceVersion(TestResource, parsed.event);

    // Assert
    try testing.expectEqualStrings("500", rv.?);
}

test "extractEventResourceVersion: ERROR event always returns null" {
    // Arrange
    const line =
        \\{"type":"ERROR","object":{"code":410,"reason":"Gone"}}
    ;
    const parsed = try parseEventLine(TestResource, testing.allocator, line);
    defer parsed.deinit();

    // Act
    const rv = extractEventResourceVersion(TestResource, parsed.event);

    // Assert
    try testing.expect(rv == null);
}

test "extractEventResourceVersion: ADDED event without metadata returns null" {
    // Arrange
    const line =
        \\{"type":"ADDED","object":{"spec":{"replicas":1}}}
    ;
    const parsed = try parseEventLine(TestResource, testing.allocator, line);
    defer parsed.deinit();

    // Act
    const rv = extractEventResourceVersion(TestResource, parsed.event);

    // Assert
    try testing.expect(rv == null);
}

test "extractResourceVersion: type without metadata field returns null" {
    // Arrange
    const obj = NoMetadataResource{ .kind = "Pod" };

    // Act
    const rv = extractResourceVersion(NoMetadataResource, obj);

    // Assert
    try testing.expect(rv == null);
}

// Unicode / special character tests
test "parseEventLine: ADDED event with unicode name parses correctly" {
    // Arrange
    const line =
        \\{"type":"ADDED","object":{"metadata":{"name":"\u00e9\u00e0\u00fc-pod"}}}
    ;

    // Act
    const parsed = try parseEventLine(TestResource, testing.allocator, line);
    defer parsed.deinit();

    // Assert
    try testing.expect(parsed.event == .added);
    try testing.expect(parsed.event.added.metadata.?.name != null);
}

test "parseEventLine: ERROR event with unicode message parses correctly" {
    // Arrange
    const line =
        \\{"type":"ERROR","object":{"code":400,"message":"invalid \u00e9ncoding"}}
    ;

    // Act
    const parsed = try parseEventLine(TestResource, testing.allocator, line);
    defer parsed.deinit();

    // Assert
    try testing.expect(parsed.event == .api_error);
    try testing.expect(parsed.event.api_error.message != null);
}

// OOM / allocator failure tests
test "parseEventLine: OOM on arena creation returns OutOfMemory without leaking" {
    // Arrange
    var fa = std.testing.FailingAllocator.init(testing.allocator, .{});
    fa.fail_index = 0;
    const line =
        \\{"type":"ADDED","object":{"metadata":{"name":"pod-1"}}}
    ;

    // Act / Assert
    try testing.expectError(error.OutOfMemory, parseEventLine(TestResource, fa.allocator(), line));
}

test "parseEventLine: OOM during JSON parsing returns error without leaking" {
    // Arrange
    var fa = std.testing.FailingAllocator.init(testing.allocator, .{});
    fa.fail_index = 1;
    const line =
        \\{"type":"ADDED","object":{"metadata":{"name":"pod-1"}}}
    ;

    // Act
    const result = parseEventLine(TestResource, fa.allocator(), line);

    // Assert
    try testing.expect(result == error.JsonParseFailed or result == error.OutOfMemory);
}

// Memory safety: deinit frees all memory
test "parseEventLine: deinit frees all memory for ADDED event" {
    // Arrange
    const line =
        \\{"type":"ADDED","object":{"metadata":{"name":"pod-1","resourceVersion":"42"},"spec":{"replicas":5}}}
    ;

    // Act
    const parsed = try parseEventLine(TestResource, testing.allocator, line);

    // Assert
    parsed.deinit();
}

test "parseEventLine: deinit frees all memory for BOOKMARK event" {
    // Arrange
    const line =
        \\{"type":"BOOKMARK","object":{"metadata":{"resourceVersion":"999"}}}
    ;

    // Act
    const parsed = try parseEventLine(TestResource, testing.allocator, line);

    // Assert
    parsed.deinit();
}

test "parseEventLine: deinit frees all memory for ERROR event" {
    // Arrange
    const line =
        \\{"type":"ERROR","object":{"code":410,"reason":"Gone","message":"resource version too old"}}
    ;

    // Act
    const parsed = try parseEventLine(TestResource, testing.allocator, line);

    // Assert
    parsed.deinit();
}
