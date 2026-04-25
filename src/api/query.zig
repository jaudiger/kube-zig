//! Query parameter building and serialization for Kubernetes API requests.
//!
//! Provides buffer-based helpers that append query strings for list, watch,
//! patch, and delete operations. Also includes percent-encoding for query
//! values and JSON serialization of delete option bodies.

const std = @import("std");
const options = @import("options.zig");
const ListOptions = options.ListOptions;
const WatchOptions = options.WatchOptions;
const PatchOptions = options.PatchOptions;
const DeleteOptions = options.DeleteOptions;
const LogOptions = options.LogOptions;
const testing = std.testing;

/// Validate that a resource name is non-empty and contains no slashes.
/// Return `error.InvalidResourceName` if validation fails.
pub fn validateName(name: []const u8) !void {
    if (name.len == 0 or std.mem.findScalar(u8, name, '/') != null) {
        return error.InvalidResourceName;
    }
}

// Buffer-based query parameter builders
/// Append watch query parameters to a growing buffer.
/// Always append at least "?watch=true".
pub fn appendWatchQueryTo(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, opts: WatchOptions) !void {
    try buf.appendSlice(alloc, "?watch=true");
    if (opts.allow_bookmarks) {
        try buf.appendSlice(alloc, "&allowWatchBookmarks=true");
    }
    if (opts.label_selector) |ls| {
        try buf.appendSlice(alloc, "&labelSelector=");
        try percentEncodeQueryValue(buf, alloc, ls);
    }
    if (opts.field_selector) |fs| {
        try buf.appendSlice(alloc, "&fieldSelector=");
        try percentEncodeQueryValue(buf, alloc, fs);
    }
    if (opts.resource_version) |rv| {
        try buf.appendSlice(alloc, "&resourceVersion=");
        try percentEncodeQueryValue(buf, alloc, rv);
    }
    if (opts.timeout_seconds) |ts| {
        try buf.appendSlice(alloc, "&timeoutSeconds=");
        try appendInt(buf, alloc, ts);
    }
}

/// Append a base-10 integer to the buffer.
fn appendInt(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, value: anytype) !void {
    var int_buf: [32]u8 = undefined;
    const slice = std.fmt.bufPrint(&int_buf, "{d}", .{value}) catch unreachable;
    try buf.appendSlice(alloc, slice);
}

/// Append an ampersand separator (if needed) and the parameter key.
fn appendParamKey(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, need_amp: *bool, key: []const u8) !void {
    if (need_amp.*) try buf.append(alloc, '&');
    try buf.appendSlice(alloc, key);
    need_amp.* = true;
}

/// Append list query parameters to a growing buffer.
/// Append nothing if no options are set.
pub fn appendListQueryTo(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, opts: ListOptions) !void {
    const has_params = opts.label_selector != null or
        opts.field_selector != null or
        opts.resource_version != null or
        opts.resource_version_match != null or
        opts.limit != null or
        opts.continue_token != null or
        opts.timeout_seconds != null;
    if (!has_params) return;

    try buf.append(alloc, '?');
    var need_amp = false;

    if (opts.label_selector) |ls| {
        try appendParamKey(buf, alloc, &need_amp, "labelSelector=");
        try percentEncodeQueryValue(buf, alloc, ls);
    }

    if (opts.field_selector) |fs| {
        try appendParamKey(buf, alloc, &need_amp, "fieldSelector=");
        try percentEncodeQueryValue(buf, alloc, fs);
    }

    if (opts.resource_version) |rv| {
        try appendParamKey(buf, alloc, &need_amp, "resourceVersion=");
        try percentEncodeQueryValue(buf, alloc, rv);
    }

    if (opts.resource_version_match) |rvm| {
        try appendParamKey(buf, alloc, &need_amp, "resourceVersionMatch=");
        try buf.appendSlice(alloc, rvm.toValue());
    }

    if (opts.limit) |n| {
        try appendParamKey(buf, alloc, &need_amp, "limit=");
        try appendInt(buf, alloc, n);
    }

    if (opts.continue_token) |ct| {
        try appendParamKey(buf, alloc, &need_amp, "continue=");
        try percentEncodeQueryValue(buf, alloc, ct);
    }

    if (opts.timeout_seconds) |ts| {
        try appendParamKey(buf, alloc, &need_amp, "timeoutSeconds=");
        try appendInt(buf, alloc, ts);
    }
}

/// Append dryRun and fieldManager query parameters to a growing buffer.
/// Append nothing if neither `dry_run` is true nor `field_manager` is set.
pub fn appendDryRunFieldManagerTo(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, dry_run: bool, field_manager: ?[]const u8) !void {
    if (!dry_run and field_manager == null) return;
    try buf.append(alloc, '?');
    if (dry_run) {
        try buf.appendSlice(alloc, "dryRun=All");
    }
    if (field_manager) |fm| {
        if (dry_run) try buf.append(alloc, '&');
        try buf.appendSlice(alloc, "fieldManager=");
        try percentEncodeQueryValue(buf, alloc, fm);
    }
}

/// Append patch-specific query parameters to a growing buffer.
/// Append nothing if no options require query parameters.
pub fn appendPatchQueryTo(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, opts: PatchOptions) !void {
    const has_fm = opts.field_manager != null;
    const has_force = opts.force;
    if (!has_fm and !has_force) return;

    try buf.append(alloc, '?');
    if (opts.field_manager) |fm| {
        try buf.appendSlice(alloc, "fieldManager=");
        try percentEncodeQueryValue(buf, alloc, fm);
        if (has_force) try buf.append(alloc, '&');
    }
    if (opts.force) {
        try buf.appendSlice(alloc, "force=true");
    }
}

/// Append log query parameters to a growing buffer.
/// Append nothing if no options are set.
pub fn appendLogQueryTo(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, opts: LogOptions) !void {
    const has_params = opts.container != null or
        opts.follow != null or
        opts.tail_lines != null or
        opts.since_seconds != null or
        opts.timestamps != null or
        opts.previous != null or
        opts.limit_bytes != null;
    if (!has_params) return;

    try buf.append(alloc, '?');
    var need_amp = false;

    if (opts.container) |c| {
        try appendParamKey(buf, alloc, &need_amp, "container=");
        try percentEncodeQueryValue(buf, alloc, c);
    }

    if (opts.follow) |f| {
        try appendParamKey(buf, alloc, &need_amp, "follow=");
        try buf.appendSlice(alloc, if (f) "true" else "false");
    }

    if (opts.tail_lines) |n| {
        try appendParamKey(buf, alloc, &need_amp, "tailLines=");
        try appendInt(buf, alloc, n);
    }

    if (opts.since_seconds) |n| {
        try appendParamKey(buf, alloc, &need_amp, "sinceSeconds=");
        try appendInt(buf, alloc, n);
    }

    if (opts.timestamps) |t| {
        try appendParamKey(buf, alloc, &need_amp, "timestamps=");
        try buf.appendSlice(alloc, if (t) "true" else "false");
    }

    if (opts.previous) |p| {
        try appendParamKey(buf, alloc, &need_amp, "previous=");
        try buf.appendSlice(alloc, if (p) "true" else "false");
    }

    if (opts.limit_bytes) |n| {
        try appendParamKey(buf, alloc, &need_amp, "limitBytes=");
        try appendInt(buf, alloc, n);
    }
}

// Allocating wrapper
/// Append patch-specific query parameters to a base path.
/// Take ownership of `base` only when params are appended (free it);
/// otherwise return `base` as-is.
pub fn appendPatchQueryParams(alloc: std.mem.Allocator, base: []const u8, opts: PatchOptions) ![]const u8 {
    if (!opts.force and opts.field_manager == null) return base;
    defer alloc.free(base);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    try buf.appendSlice(alloc, base);
    try appendPatchQueryTo(&buf, alloc, opts);
    return buf.toOwnedSlice(alloc);
}

/// Serialize delete options into a JSON request body.
/// Return null if no options are set.
pub fn serializeDeleteOpts(alloc: std.mem.Allocator, opts: DeleteOptions) !?[]const u8 {
    if (opts.propagation_policy == null and
        opts.grace_period_seconds == null and
        opts.precondition_uid == null and
        opts.precondition_resource_version == null) return null;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const w = &out.writer;

    try w.writeAll("{\"apiVersion\":\"v1\",\"kind\":\"DeleteOptions\"");

    if (opts.propagation_policy) |pp| {
        try w.writeAll(",\"propagationPolicy\":\"");
        try w.writeAll(pp.toValue());
        try w.writeByte('"');
    }

    if (opts.grace_period_seconds) |gps| {
        try w.writeAll(",\"gracePeriodSeconds\":");
        try w.print("{d}", .{gps});
    }

    if (opts.precondition_uid != null or opts.precondition_resource_version != null) {
        try w.writeAll(",\"preconditions\":{");
        var need_comma = false;

        if (opts.precondition_uid) |uid| {
            try w.writeAll("\"uid\":");
            try std.json.Stringify.encodeJsonString(uid, .{}, w);
            need_comma = true;
        }

        if (opts.precondition_resource_version) |rv| {
            if (need_comma) try w.writeByte(',');
            try w.writeAll("\"resourceVersion\":");
            try std.json.Stringify.encodeJsonString(rv, .{}, w);
        }

        try w.writeByte('}');
    }

    try w.writeByte('}');

    return try out.toOwnedSlice();
}

/// Percent-encode a query parameter value into an `ArrayList`.
pub fn percentEncodeQueryValue(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, raw: []const u8) !void {
    for (raw) |c| {
        if (isQueryValueChar(c)) {
            try buf.append(alloc, c);
        } else {
            try buf.appendSlice(alloc, &[_]u8{
                '%',
                hexDigit(@truncate(c >> 4)),
                hexDigit(@truncate(c & 0x0f)),
            });
        }
    }
}

fn isQueryValueChar(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9' => true,
        '-', '.', '_', '~' => true, // unreserved
        else => false,
    };
}

fn hexDigit(nibble: u4) u8 {
    return "0123456789ABCDEF"[nibble];
}

// validateName tests
test "validateName: empty string returns error" {
    // Act / Assert
    try testing.expectError(error.InvalidResourceName, validateName(""));
}

test "validateName: single slash returns error" {
    // Act / Assert
    try testing.expectError(error.InvalidResourceName, validateName("/"));
}

test "validateName: embedded slash returns error" {
    // Act / Assert
    try testing.expectError(error.InvalidResourceName, validateName("a/b"));
}

test "validateName: multiple slashes returns error" {
    // Act / Assert
    try testing.expectError(error.InvalidResourceName, validateName("a/b/c"));
}

test "validateName: leading slash returns error" {
    // Act / Assert
    try testing.expectError(error.InvalidResourceName, validateName("/pod"));
}

test "validateName: trailing slash returns error" {
    // Act / Assert
    try testing.expectError(error.InvalidResourceName, validateName("pod/"));
}

test "validateName: valid simple name succeeds" {
    // Act / Assert
    try validateName("my-pod");
}

test "validateName: valid name with dots succeeds" {
    // Act / Assert
    try validateName("my.pod.v1");
}

test "validateName: valid name with underscores and tildes succeeds" {
    // Act / Assert
    try validateName("my_pod~1");
}

// appendWatchQueryTo tests
test "appendWatchQueryTo: defaults produce watch=true with bookmarks" {
    // Arrange
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    // Act
    try appendWatchQueryTo(&buf, testing.allocator, .{});

    // Assert
    try testing.expectEqualStrings("?watch=true&allowWatchBookmarks=true", buf.items);
}

test "appendWatchQueryTo: bookmarks disabled" {
    // Arrange
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    // Act
    try appendWatchQueryTo(&buf, testing.allocator, .{ .allow_bookmarks = false });

    // Assert
    try testing.expectEqualStrings("?watch=true", buf.items);
}

test "appendWatchQueryTo: all options" {
    // Arrange
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    // Act
    try appendWatchQueryTo(&buf, testing.allocator, .{
        .label_selector = "app=nginx",
        .field_selector = "status.phase=Running",
        .resource_version = "999",
        .timeout_seconds = 60,
        .allow_bookmarks = true,
    });

    // Assert
    try testing.expectEqualStrings(
        "?watch=true&allowWatchBookmarks=true&labelSelector=app%3Dnginx&fieldSelector=status.phase%3DRunning&resourceVersion=999&timeoutSeconds=60",
        buf.items,
    );
}

test "appendWatchQueryTo: appends to existing buffer content" {
    // Arrange
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try buf.appendSlice(testing.allocator, "/api/v1/pods");

    // Act
    try appendWatchQueryTo(&buf, testing.allocator, .{ .allow_bookmarks = false });

    // Assert
    try testing.expectEqualStrings("/api/v1/pods?watch=true", buf.items);
}

// appendListQueryTo tests
test "appendListQueryTo: no options appends nothing" {
    // Arrange
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try buf.appendSlice(testing.allocator, "/api/v1/pods");

    // Act
    try appendListQueryTo(&buf, testing.allocator, .{});

    // Assert
    try testing.expectEqualStrings("/api/v1/pods", buf.items);
}

test "appendListQueryTo: label selector" {
    // Arrange
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    // Act
    try appendListQueryTo(&buf, testing.allocator, .{ .label_selector = "app=nginx" });

    // Assert
    try testing.expectEqualStrings("?labelSelector=app%3Dnginx", buf.items);
}

test "appendListQueryTo: all options" {
    // Arrange
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    // Act
    try appendListQueryTo(&buf, testing.allocator, .{
        .label_selector = "app=nginx",
        .field_selector = "status.phase=Running",
        .resource_version = "999",
        .resource_version_match = .not_older_than,
        .limit = 10,
        .continue_token = "abc",
        .timeout_seconds = 60,
    });

    // Assert
    try testing.expectEqualStrings(
        "?labelSelector=app%3Dnginx&fieldSelector=status.phase%3DRunning&resourceVersion=999&resourceVersionMatch=NotOlderThan&limit=10&continue=abc&timeoutSeconds=60",
        buf.items,
    );
}

// appendDryRunFieldManagerTo tests
test "appendDryRunFieldManagerTo: neither option appends nothing" {
    // Arrange
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    // Act
    try appendDryRunFieldManagerTo(&buf, testing.allocator, false, null);

    // Assert
    try testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "appendDryRunFieldManagerTo: dry_run only" {
    // Arrange
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    // Act
    try appendDryRunFieldManagerTo(&buf, testing.allocator, true, null);

    // Assert
    try testing.expectEqualStrings("?dryRun=All", buf.items);
}

test "appendDryRunFieldManagerTo: field_manager only" {
    // Arrange
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    // Act
    try appendDryRunFieldManagerTo(&buf, testing.allocator, false, "my-controller");

    // Assert
    try testing.expectEqualStrings("?fieldManager=my-controller", buf.items);
}

test "appendDryRunFieldManagerTo: both" {
    // Arrange
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    // Act
    try appendDryRunFieldManagerTo(&buf, testing.allocator, true, "ctl");

    // Assert
    try testing.expectEqualStrings("?dryRun=All&fieldManager=ctl", buf.items);
}

// appendPatchQueryTo tests
test "appendPatchQueryTo: no options appends nothing" {
    // Arrange
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    // Act
    try appendPatchQueryTo(&buf, testing.allocator, .{});

    // Assert
    try testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "appendPatchQueryTo: fieldManager only" {
    // Arrange
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    // Act
    try appendPatchQueryTo(&buf, testing.allocator, .{ .field_manager = "ctl" });

    // Assert
    try testing.expectEqualStrings("?fieldManager=ctl", buf.items);
}

test "appendPatchQueryTo: force only" {
    // Arrange
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    // Act
    try appendPatchQueryTo(&buf, testing.allocator, .{ .force = true });

    // Assert
    try testing.expectEqualStrings("?force=true", buf.items);
}

test "appendPatchQueryTo: both fieldManager and force" {
    // Arrange
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    // Act
    try appendPatchQueryTo(&buf, testing.allocator, .{ .field_manager = "ctl", .force = true });

    // Assert
    try testing.expectEqualStrings("?fieldManager=ctl&force=true", buf.items);
}

test "appendPatchQueryTo: fieldManager with special characters" {
    // Arrange
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    // Act
    try appendPatchQueryTo(&buf, testing.allocator, .{ .field_manager = "my controller&v=2" });

    // Assert
    try testing.expectEqualStrings("?fieldManager=my%20controller%26v%3D2", buf.items);
}

// appendPatchQueryParams tests
test "appendPatchQueryParams: no options returns base as-is" {
    // Arrange
    const base = try testing.allocator.dupe(u8, "/api/v1/pods/my-pod");

    // Act
    const result = try appendPatchQueryParams(testing.allocator, base, .{});
    defer testing.allocator.free(result);

    // Assert
    try testing.expectEqualStrings("/api/v1/pods/my-pod", result);
}

test "appendPatchQueryParams: with options frees base and returns new" {
    // Arrange
    const base = try testing.allocator.dupe(u8, "/api/v1/pods/my-pod");

    // Act
    const result = try appendPatchQueryParams(testing.allocator, base, .{ .field_manager = "ctl", .force = true });
    defer testing.allocator.free(result);

    // Assert
    try testing.expectEqualStrings("/api/v1/pods/my-pod?fieldManager=ctl&force=true", result);
}

// percentEncodeQueryValue tests
test "percentEncodeQueryValue: unreserved characters pass through" {
    // Arrange
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    // Act
    try percentEncodeQueryValue(&buf, testing.allocator, "hello-world_v1.0~beta");

    // Assert
    try testing.expectEqualStrings("hello-world_v1.0~beta", buf.items);
}

test "percentEncodeQueryValue: reserved characters are encoded" {
    // Arrange
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    // Act
    try percentEncodeQueryValue(&buf, testing.allocator, "a=b&c d");

    // Assert
    try testing.expectEqualStrings("a%3Db%26c%20d", buf.items);
}

// serializeDeleteOpts tests
test "serializeDeleteOpts: no options returns null" {
    // Act
    const result = try serializeDeleteOpts(testing.allocator, .{});

    // Assert
    try testing.expectEqual(null, result);
}

test "serializeDeleteOpts: propagation policy" {
    // Act
    const result = (try serializeDeleteOpts(testing.allocator, .{ .propagation_policy = .background })).?;
    defer testing.allocator.free(result);

    // Assert
    try testing.expectEqualStrings("{\"apiVersion\":\"v1\",\"kind\":\"DeleteOptions\",\"propagationPolicy\":\"Background\"}", result);
}

test "serializeDeleteOpts: grace period" {
    // Act
    const result = (try serializeDeleteOpts(testing.allocator, .{ .grace_period_seconds = 30 })).?;
    defer testing.allocator.free(result);

    // Assert
    try testing.expectEqualStrings("{\"apiVersion\":\"v1\",\"kind\":\"DeleteOptions\",\"gracePeriodSeconds\":30}", result);
}

test "serializeDeleteOpts: both options" {
    // Act
    const result = (try serializeDeleteOpts(testing.allocator, .{ .propagation_policy = .foreground, .grace_period_seconds = 60 })).?;
    defer testing.allocator.free(result);

    // Assert
    try testing.expectEqualStrings("{\"apiVersion\":\"v1\",\"kind\":\"DeleteOptions\",\"propagationPolicy\":\"Foreground\",\"gracePeriodSeconds\":60}", result);
}

test "serializeDeleteOpts: precondition uid" {
    // Act
    const result = (try serializeDeleteOpts(testing.allocator, .{ .precondition_uid = "abc-123" })).?;
    defer testing.allocator.free(result);

    // Assert
    try testing.expectEqualStrings("{\"apiVersion\":\"v1\",\"kind\":\"DeleteOptions\",\"preconditions\":{\"uid\":\"abc-123\"}}", result);
}

test "serializeDeleteOpts: precondition resourceVersion" {
    // Act
    const result = (try serializeDeleteOpts(testing.allocator, .{ .precondition_resource_version = "456" })).?;
    defer testing.allocator.free(result);

    // Assert
    try testing.expectEqualStrings("{\"apiVersion\":\"v1\",\"kind\":\"DeleteOptions\",\"preconditions\":{\"resourceVersion\":\"456\"}}", result);
}

test "serializeDeleteOpts: both preconditions" {
    // Act
    const result = (try serializeDeleteOpts(testing.allocator, .{ .precondition_uid = "abc-123", .precondition_resource_version = "456" })).?;
    defer testing.allocator.free(result);

    // Assert
    try testing.expectEqualStrings("{\"apiVersion\":\"v1\",\"kind\":\"DeleteOptions\",\"preconditions\":{\"uid\":\"abc-123\",\"resourceVersion\":\"456\"}}", result);
}

test "serializeDeleteOpts: all delete options" {
    // Act
    const result = (try serializeDeleteOpts(testing.allocator, .{
        .propagation_policy = .background,
        .grace_period_seconds = 30,
        .precondition_uid = "uid-xyz",
        .precondition_resource_version = "789",
    })).?;
    defer testing.allocator.free(result);

    // Assert
    try testing.expectEqualStrings(
        "{\"apiVersion\":\"v1\",\"kind\":\"DeleteOptions\",\"propagationPolicy\":\"Background\",\"gracePeriodSeconds\":30,\"preconditions\":{\"uid\":\"uid-xyz\",\"resourceVersion\":\"789\"}}",
        result,
    );
}

test "serializeDeleteOpts: precondition uid with special characters is JSON-escaped" {
    // Act
    const result = (try serializeDeleteOpts(testing.allocator, .{
        .precondition_uid = "uid-with-\"quotes\"-and-\\backslash",
    })).?;
    defer testing.allocator.free(result);

    // Assert
    try testing.expectEqualStrings(
        "{\"apiVersion\":\"v1\",\"kind\":\"DeleteOptions\",\"preconditions\":{\"uid\":\"uid-with-\\\"quotes\\\"-and-\\\\backslash\"}}",
        result,
    );
}

test "serializeDeleteOpts: precondition resourceVersion with control chars is JSON-escaped" {
    // Act
    const result = (try serializeDeleteOpts(testing.allocator, .{
        .precondition_resource_version = "ver\n123",
    })).?;
    defer testing.allocator.free(result);

    // Assert
    try testing.expectEqualStrings(
        "{\"apiVersion\":\"v1\",\"kind\":\"DeleteOptions\",\"preconditions\":{\"resourceVersion\":\"ver\\n123\"}}",
        result,
    );
}

test "serializeDeleteOpts: orphan propagation policy" {
    // Act
    const result = (try serializeDeleteOpts(testing.allocator, .{ .propagation_policy = .orphan })).?;
    defer testing.allocator.free(result);

    // Assert
    try testing.expectEqualStrings("{\"apiVersion\":\"v1\",\"kind\":\"DeleteOptions\",\"propagationPolicy\":\"Orphan\"}", result);
}

test "serializeDeleteOpts: OOM on allocation returns OutOfMemory" {
    // Arrange
    var fa = std.testing.FailingAllocator.init(testing.allocator, .{});
    fa.fail_index = 0;

    // Act / Assert
    try testing.expectError(error.OutOfMemory, serializeDeleteOpts(fa.allocator(), .{ .propagation_policy = .background }));
}
