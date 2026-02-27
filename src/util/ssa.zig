//! Server-Side Apply (SSA) conflict detection and information extraction.
//!
//! Provides helpers to identify HTTP 409 Conflict responses from the
//! Kubernetes API server that originate from SSA field ownership
//! conflicts, and to extract the conflicting field manager names
//! from the error message.

const std = @import("std");
const http = std.http;
const KubeStatus = @import("../client/Client.zig").Client.KubeStatus;
const testing = std.testing;

/// Information extracted from an SSA conflict error response.
///
/// All string fields (`managers` elements and `message`) are owned by the
/// internal arena and freed in one shot by `deinit()`. The caller does not
/// need to keep the original `err_body` alive after `extractConflictInfo` returns.
pub const ConflictInfo = struct {
    /// The field manager(s) that own the conflicting fields.
    /// Parsed from the error message. May be empty if parsing fails.
    managers: []const []const u8,
    /// The error message from the API server (arena-owned copy).
    message: []const u8,
    /// Backing arena that owns all allocations (managers slice + strings + message).
    arena: std.heap.ArenaAllocator,

    /// Free all memory owned by this ConflictInfo.
    pub fn deinit(self: *ConflictInfo) void {
        self.arena.deinit();
    }
};

/// Check if an API error response represents an SSA field conflict.
/// SSA conflicts are HTTP 409 with reason "Conflict".
///
/// `err_status` is the HTTP status code and `err_body` is the raw response body.
/// This function parses the body as a Kubernetes Status object to check the reason.
pub fn isApplyConflict(err_status: http.Status, err_body: []const u8, allocator: std.mem.Allocator) bool {
    if (err_status != .conflict) return false;

    // Try to parse as Kubernetes Status to check the reason field.
    const parsed = std.json.parseFromSlice(KubeStatus, allocator, err_body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return false;
    defer parsed.deinit();

    const reason = parsed.value.reason orelse return false;
    return std.mem.eql(u8, reason, "Conflict");
}

/// Extract conflict information from an SSA conflict error response.
/// Returns null if the error is not an SSA conflict.
/// The returned ConflictInfo owns all its data via an internal arena;
/// caller must call `deinit()` to release it.
pub fn extractConflictInfo(
    err_status: http.Status,
    err_body: []const u8,
    allocator: std.mem.Allocator,
) error{OutOfMemory}!?ConflictInfo {
    if (err_status != .conflict) return null;

    // Parse Kubernetes Status.
    const parsed = std.json.parseFromSlice(KubeStatus, allocator, err_body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return null;
    defer parsed.deinit();

    const reason = parsed.value.reason orelse return null;
    if (!std.mem.eql(u8, reason, "Conflict")) return null;

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();

    // Find message directly in err_body and dupe into the arena.
    const body_message = findMessageInBody(err_body) orelse "";
    const message_copy = try aa.dupe(u8, body_message);

    // Extract manager names from the raw body message.
    // Kubernetes SSA conflict messages in JSON contain escaped quotes like:
    //   "conflict with \\\"kubectl-client-side-apply\\\" using apps/v1"
    // In the raw JSON body, the \" appears as \\" in the string literal.
    var managers_list: std.ArrayListUnmanaged([]const u8) = .empty;

    // In the raw JSON body, quoted manager names appear between escaped quotes: \"mgr\"
    // which in the body bytes looks like: \", mgr, \"
    const escaped_quote = "\\\"";
    var search_pos: usize = 0;
    while (search_pos < body_message.len) {
        const quote_start = std.mem.indexOfPos(u8, body_message, search_pos, escaped_quote) orelse break;
        const name_start = quote_start + escaped_quote.len;
        const quote_end = std.mem.indexOfPos(u8, body_message, name_start, escaped_quote) orelse break;
        const mgr_name = body_message[name_start..quote_end];

        // Deduplicate.
        var found = false;
        for (managers_list.items) |existing| {
            if (std.mem.eql(u8, existing, mgr_name)) {
                found = true;
                break;
            }
        }
        if (!found) {
            try managers_list.append(aa, try aa.dupe(u8, mgr_name));
        }

        search_pos = quote_end + escaped_quote.len;
    }

    return .{
        .managers = try managers_list.toOwnedSlice(aa),
        .message = message_copy,
        .arena = arena,
    };
}

/// Find the "message" field value in the raw JSON body.
/// Returns a slice into err_body if found.
fn findMessageInBody(body: []const u8) ?[]const u8 {
    // Look for "message":" pattern and extract the string value.
    const key = "\"message\":\"";
    const start = std.mem.indexOf(u8, body, key) orelse return null;
    const value_start = start + key.len;

    // Find the end of the string value (unescaped quote).
    var pos = value_start;
    while (pos < body.len) {
        if (body[pos] == '\\') {
            pos += 2; // skip escaped char
            continue;
        }
        if (body[pos] == '"') {
            return body[value_start..pos];
        }
        pos += 1;
    }
    return null;
}

test "isApplyConflict: returns true for 409 with Conflict reason" {
    // Act
    const body =
        \\{"kind":"Status","apiVersion":"v1","metadata":{},"status":"Failure","message":"Apply failed with 1 conflict: conflict with \"kubectl-client-side-apply\" using apps/v1","reason":"Conflict","code":409}
    ;

    // Assert
    try testing.expect(isApplyConflict(.conflict, body, testing.allocator));
}

test "isApplyConflict: returns false for non-409 status" {
    // Act
    const body =
        \\{"kind":"Status","apiVersion":"v1","status":"Failure","reason":"NotFound","code":404}
    ;

    // Assert
    try testing.expect(!isApplyConflict(.not_found, body, testing.allocator));
}

test "isApplyConflict: returns false for 409 with non-Conflict reason" {
    // Act
    const body =
        \\{"kind":"Status","apiVersion":"v1","status":"Failure","reason":"AlreadyExists","code":409}
    ;

    // Assert
    try testing.expect(!isApplyConflict(.conflict, body, testing.allocator));
}

test "isApplyConflict: returns false for invalid JSON body" {
    // Act / Assert
    try testing.expect(!isApplyConflict(.conflict, "not json", testing.allocator));
}

test "isApplyConflict: returns false for empty body" {
    // Act / Assert
    try testing.expect(!isApplyConflict(.conflict, "", testing.allocator));
}

test "extractConflictInfo: extracts single manager" {
    // Arrange
    const body =
        \\{"kind":"Status","apiVersion":"v1","metadata":{},"status":"Failure","message":"Apply failed with 1 conflict: conflict with \"kubectl-client-side-apply\" using apps/v1","reason":"Conflict","code":409}
    ;

    // Act
    var info = (try extractConflictInfo(.conflict, body, testing.allocator)).?;
    defer info.deinit();

    // Assert
    try testing.expectEqual(@as(usize, 1), info.managers.len);
    try testing.expectEqualStrings("kubectl-client-side-apply", info.managers[0]);
    try testing.expect(info.message.len > 0);
}

test "extractConflictInfo: extracts multiple managers" {
    // Arrange
    const body =
        \\{"kind":"Status","apiVersion":"v1","metadata":{},"status":"Failure","message":"Apply failed with 2 conflicts: conflicts with \"mgr1\" using v1, \"mgr2\" using apps/v1","reason":"Conflict","code":409}
    ;

    // Act
    var info = (try extractConflictInfo(.conflict, body, testing.allocator)).?;
    defer info.deinit();

    // Assert
    try testing.expectEqual(@as(usize, 2), info.managers.len);
    try testing.expectEqualStrings("mgr1", info.managers[0]);
    try testing.expectEqualStrings("mgr2", info.managers[1]);
}

test "extractConflictInfo: returns null for non-409" {
    // Arrange
    const body =
        \\{"kind":"Status","reason":"NotFound","code":404}
    ;

    // Act
    const result = try extractConflictInfo(.not_found, body, testing.allocator);

    // Assert
    try testing.expect(result == null);
}

test "extractConflictInfo: returns null for 409 with wrong reason" {
    // Arrange
    const body =
        \\{"kind":"Status","reason":"AlreadyExists","code":409}
    ;

    // Act
    const result = try extractConflictInfo(.conflict, body, testing.allocator);

    // Assert
    try testing.expect(result == null);
}

test "extractConflictInfo: returns empty managers when no quoted names in message" {
    // Arrange
    const body =
        \\{"kind":"Status","message":"some conflict without quoted managers","reason":"Conflict","code":409}
    ;

    // Act
    var info = (try extractConflictInfo(.conflict, body, testing.allocator)).?;
    defer info.deinit();

    // Assert
    try testing.expectEqual(@as(usize, 0), info.managers.len);
}

test "findMessageInBody: extracts message value" {
    // Arrange
    const body =
        \\{"kind":"Status","message":"hello world","reason":"Conflict"}
    ;

    // Act
    const msg = findMessageInBody(body);

    // Assert
    try testing.expect(msg != null);
    try testing.expectEqualStrings("hello world", msg.?);
}

test "findMessageInBody: returns null when no message field" {
    // Arrange
    const body =
        \\{"kind":"Status","reason":"Conflict"}
    ;

    // Act
    const msg = findMessageInBody(body);

    // Assert
    try testing.expect(msg == null);
}
