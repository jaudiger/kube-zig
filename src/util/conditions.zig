//! Helpers for working with Kubernetes status conditions.
//!
//! Provides generic functions to find, check, set, and remove conditions
//! on any struct that carries a `type` and `status` field (both the
//! standardized `MetaV1Condition` shape and legacy per-resource condition
//! types). All slice-returning functions allocate a fresh slice; the caller
//! owns the returned memory.

const std = @import("std");
const testing = std.testing;

// Public types
/// Typed enum for the three standard Kubernetes condition statuses.
pub const ConditionStatus = enum {
    condition_true,
    condition_false,
    condition_unknown,

    /// Returns the canonical Kubernetes string representation.
    pub fn toValue(self: ConditionStatus) []const u8 {
        return switch (self) {
            .condition_true => "True",
            .condition_false => "False",
            .condition_unknown => "Unknown",
        };
    }

    /// Parse a Kubernetes condition status string. Returns null for unrecognized values.
    pub fn fromValue(s: []const u8) ?ConditionStatus {
        if (std.mem.eql(u8, s, "True")) return .condition_true;
        if (std.mem.eql(u8, s, "False")) return .condition_false;
        if (std.mem.eql(u8, s, "Unknown")) return .condition_unknown;
        return null;
    }
};

/// Input for setting a condition. Uses only common fields that exist
/// across both standardized and legacy condition types.
pub const ConditionValue = struct {
    type: []const u8,
    status: ConditionStatus,
    reason: []const u8,
    message: []const u8,
    /// If provided, written to `observedGeneration` (if the condition type has that field).
    observed_generation: ?i64 = null,
};

// Type helpers
/// Extract the element type C from either `?[]const C` or `[]const C`.
fn ConditionElement(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |opt| ConditionElement(opt.child),
        .pointer => |ptr| ptr.child,
        else => @compileError("expected a slice or optional slice type, got " ++ @typeName(T)),
    };
}

fn validateConditionType(comptime C: type) void {
    if (!@hasField(C, "type")) {
        @compileError("condition type '" ++ @typeName(C) ++ "' has no 'type' field");
    }
    if (!@hasField(C, "status")) {
        @compileError("condition type '" ++ @typeName(C) ++ "' has no 'status' field");
    }
}

/// Set a string field that may be `[]const u8` or `?[]const u8`.
/// Silently skips if the field does not exist on C.
fn setStringField(comptime C: type, obj: *C, comptime field_name: []const u8, value: []const u8) void {
    if (comptime @hasField(C, field_name)) {
        const FieldType = @TypeOf(@field(obj.*, field_name));
        if (FieldType == []const u8) {
            @field(obj.*, field_name) = value;
        } else if (FieldType == ?[]const u8) {
            @field(obj.*, field_name) = value;
        }
    }
}

// Condition lookup
/// Find a condition by its type string in a conditions slice.
/// Works with both `?[]const C` (optional slice) and `[]const C` (non-optional).
/// Returns a pointer to the matching condition, or null if not found.
pub fn findCondition(comptime SliceT: type, conds: SliceT, condition_type: []const u8) ?*const ConditionElement(SliceT) {
    const C = ConditionElement(SliceT);
    comptime validateConditionType(C);

    const slice: []const C = if (comptime @typeInfo(SliceT) == .optional)
        (conds orelse return null)
    else
        conds;

    for (slice) |*cond| {
        if (std.mem.eql(u8, cond.type, condition_type)) return cond;
    }
    return null;
}

// Status checks
/// Returns true if a condition with the given type exists and has status "True".
pub fn isConditionTrue(comptime SliceT: type, conds: SliceT, condition_type: []const u8) bool {
    const cond = findCondition(SliceT, conds, condition_type) orelse return false;
    return std.mem.eql(u8, cond.status, "True");
}

/// Returns true if a condition with the given type exists and has status "False".
pub fn isConditionFalse(comptime SliceT: type, conds: SliceT, condition_type: []const u8) bool {
    const cond = findCondition(SliceT, conds, condition_type) orelse return false;
    return std.mem.eql(u8, cond.status, "False");
}

/// Returns true if a condition with the given type exists and has status "Unknown".
pub fn isConditionUnknown(comptime SliceT: type, conds: SliceT, condition_type: []const u8) bool {
    const cond = findCondition(SliceT, conds, condition_type) orelse return false;
    return std.mem.eql(u8, cond.status, "Unknown");
}

/// Returns the parsed ConditionStatus for a condition type, or null if the condition doesn't exist.
pub fn getConditionStatus(comptime SliceT: type, conds: SliceT, condition_type: []const u8) ?ConditionStatus {
    const cond = findCondition(SliceT, conds, condition_type) orelse return null;
    return ConditionStatus.fromValue(cond.status);
}

// Set / remove
/// Set or update a condition in a conditions slice.
///
/// If a condition with the same type already exists, it is updated in place
/// (status, reason, message, observedGeneration are overwritten;
/// lastTransitionTime is only updated if the status changed).
/// If no matching condition exists, a new one is appended.
///
/// Returns a new slice. Each code path uses a single allocation followed
/// by an infallible fill. Caller owns the returned slice.
///
/// `timestamp` is the RFC 3339 timestamp string for lastTransitionTime on new
/// conditions or status transitions. The caller provides it so this module stays
/// standalone (no clock dependency).
pub fn setCondition(
    comptime C: type,
    existing: ?[]const C,
    value: ConditionValue,
    timestamp: []const u8,
    allocator: std.mem.Allocator,
) error{OutOfMemory}![]const C {
    comptime validateConditionType(C);

    const slice = existing orelse {
        // Allocate
        const result = try allocator.alloc(C, 1);
        errdefer comptime unreachable;

        // Fill
        result[0] = makeNewCondition(C, value, timestamp);
        return result;
    };

    // Find existing condition with matching type.
    var found_index: ?usize = null;
    for (slice, 0..) |cond, i| {
        if (std.mem.eql(u8, cond.type, value.type)) {
            found_index = i;
            break;
        }
    }

    if (found_index) |idx| {
        // Allocate
        const result = try allocator.alloc(C, slice.len);
        errdefer comptime unreachable;

        // Fill
        @memcpy(result, slice);
        result[idx] = updateCondition(C, slice[idx], value, timestamp);
        return result;
    } else {
        // Allocate
        const result = try allocator.alloc(C, slice.len + 1);
        errdefer comptime unreachable;

        // Fill
        @memcpy(result[0..slice.len], slice);
        result[slice.len] = makeNewCondition(C, value, timestamp);
        return result;
    }
}

/// Remove a condition by type from a conditions slice.
/// Returns a new slice without the matching condition.
/// Uses a measure pass, a single allocation, then an infallible fill.
/// Caller owns the returned slice. Returns null if the input slice is null.
pub fn removeCondition(
    comptime C: type,
    existing: ?[]const C,
    condition_type: []const u8,
    allocator: std.mem.Allocator,
) error{OutOfMemory}!?[]const C {
    comptime validateConditionType(C);
    const slice = existing orelse return null;

    // Measure
    var keep: usize = 0;
    for (slice) |cond| {
        if (!std.mem.eql(u8, cond.type, condition_type)) keep += 1;
    }

    // Allocate
    const result = try allocator.alloc(C, keep);
    errdefer comptime unreachable;

    // Fill
    var i: usize = 0;
    for (slice) |cond| {
        if (!std.mem.eql(u8, cond.type, condition_type)) {
            result[i] = cond;
            i += 1;
        }
    }
    return result;
}

// Internal helpers
/// Build a brand-new condition value of type C, setting all known fields
/// from the ConditionValue and defaulting unknown optional fields to null.
fn makeNewCondition(comptime C: type, value: ConditionValue, timestamp: []const u8) C {
    var cond: C = undefined;

    inline for (@typeInfo(C).@"struct".fields) |field| {
        if (comptime std.mem.eql(u8, field.name, "type")) {
            @field(cond, field.name) = value.type;
        } else if (comptime std.mem.eql(u8, field.name, "status")) {
            @field(cond, field.name) = value.status.toValue();
        } else if (comptime std.mem.eql(u8, field.name, "reason")) {
            @field(cond, field.name) = coerceStringValue(field.type, value.reason);
        } else if (comptime std.mem.eql(u8, field.name, "message")) {
            @field(cond, field.name) = coerceStringValue(field.type, value.message);
        } else if (comptime std.mem.eql(u8, field.name, "lastTransitionTime")) {
            @field(cond, field.name) = coerceStringValue(field.type, timestamp);
        } else if (comptime std.mem.eql(u8, field.name, "observedGeneration")) {
            @field(cond, field.name) = value.observed_generation;
        } else if (comptime @typeInfo(field.type) == .optional) {
            @field(cond, field.name) = null;
        } else {
            @compileError("condition type '" ++ @typeName(C) ++
                "' has unhandled required field '" ++ field.name ++ "'");
        }
    }

    return cond;
}

/// Update an existing condition, preserving lastTransitionTime when the status
/// has not changed.
fn updateCondition(comptime C: type, existing: C, value: ConditionValue, timestamp: []const u8) C {
    var cond = existing;
    const status_changed = !std.mem.eql(u8, existing.status, value.status.toValue());
    cond.status = value.status.toValue();

    setStringField(C, &cond, "reason", value.reason);
    setStringField(C, &cond, "message", value.message);

    if (status_changed) {
        setStringField(C, &cond, "lastTransitionTime", timestamp);
    }

    if (comptime @hasField(C, "observedGeneration")) {
        if (value.observed_generation) |gen| {
            cond.observedGeneration = gen;
        }
    }

    return cond;
}

/// Coerce a `[]const u8` value to a field type that is either `[]const u8` or `?[]const u8`.
fn coerceStringValue(comptime T: type, value: []const u8) T {
    if (T == []const u8) return value;
    if (T == ?[]const u8) return value;
    @compileError("expected []const u8 or ?[]const u8, got " ++ @typeName(T));
}

/// Mimics MetaV1Condition (standardized, all required fields).
const StandardCondition = struct {
    lastTransitionTime: []const u8,
    message: []const u8,
    observedGeneration: ?i64 = null,
    reason: []const u8,
    status: []const u8,
    type: []const u8,
};

/// Mimics AppsV1DeploymentCondition (legacy, optional fields).
const LegacyCondition = struct {
    lastTransitionTime: ?[]const u8 = null,
    lastUpdateTime: ?[]const u8 = null,
    message: ?[]const u8 = null,
    reason: ?[]const u8 = null,
    status: []const u8,
    type: []const u8,
};

// ConditionStatus tests
test "ConditionStatus.toValue returns correct strings" {
    // Act / Assert
    try testing.expectEqualStrings("True", ConditionStatus.condition_true.toValue());
    try testing.expectEqualStrings("False", ConditionStatus.condition_false.toValue());
    try testing.expectEqualStrings("Unknown", ConditionStatus.condition_unknown.toValue());
}

test "ConditionStatus.fromValue parses valid strings" {
    // Act / Assert
    try testing.expectEqual(ConditionStatus.condition_true, ConditionStatus.fromValue("True").?);
    try testing.expectEqual(ConditionStatus.condition_false, ConditionStatus.fromValue("False").?);
    try testing.expectEqual(ConditionStatus.condition_unknown, ConditionStatus.fromValue("Unknown").?);
}

test "ConditionStatus.fromValue returns null for unrecognized" {
    // Act / Assert
    try testing.expect(ConditionStatus.fromValue("true") == null);
    try testing.expect(ConditionStatus.fromValue("yes") == null);
    try testing.expect(ConditionStatus.fromValue("") == null);
}

// findCondition tests
test "findCondition finds condition by type (StandardCondition)" {
    // Arrange
    const conds = [_]StandardCondition{
        .{ .type = "Ready", .status = "True", .reason = "AllGood", .message = "ok", .lastTransitionTime = "t0" },
        .{ .type = "Available", .status = "False", .reason = "Waiting", .message = "not yet", .lastTransitionTime = "t1" },
    };

    // Act
    const found = findCondition([]const StandardCondition, &conds, "Available").?;

    // Assert
    try testing.expectEqualStrings("Available", found.type);
    try testing.expectEqualStrings("False", found.status);
}

test "findCondition returns null when type not found" {
    // Arrange
    const conds = [_]StandardCondition{
        .{ .type = "Ready", .status = "True", .reason = "r", .message = "m", .lastTransitionTime = "t" },
    };

    // Act / Assert
    try testing.expect(findCondition([]const StandardCondition, &conds, "Missing") == null);
}

test "findCondition returns null for empty slice" {
    // Arrange
    const conds = [_]StandardCondition{};

    // Act / Assert
    try testing.expect(findCondition([]const StandardCondition, &conds, "Ready") == null);
}

test "findCondition returns null for null optional slice" {
    // Act
    const conds: ?[]const StandardCondition = null;

    // Assert
    try testing.expect(findCondition(?[]const StandardCondition, conds, "Ready") == null);
}

test "findCondition works with LegacyCondition" {
    // Arrange
    const conds = [_]LegacyCondition{
        .{ .type = "Available", .status = "True" },
        .{ .type = "Progressing", .status = "True", .reason = "NewReplicaSet", .message = "has minimum" },
    };

    // Act
    const found = findCondition([]const LegacyCondition, &conds, "Progressing").?;

    // Assert
    try testing.expectEqualStrings("Progressing", found.type);
    try testing.expectEqualStrings("NewReplicaSet", found.reason.?);
}

// isConditionTrue / False / Unknown tests
test "isConditionTrue returns true when matching" {
    // Arrange
    const conds = [_]StandardCondition{
        .{ .type = "Ready", .status = "True", .reason = "r", .message = "m", .lastTransitionTime = "t" },
    };

    // Act / Assert
    try testing.expect(isConditionTrue([]const StandardCondition, &conds, "Ready"));
}

test "isConditionTrue returns false when status differs" {
    // Arrange
    const conds = [_]StandardCondition{
        .{ .type = "Ready", .status = "False", .reason = "r", .message = "m", .lastTransitionTime = "t" },
    };

    // Act / Assert
    try testing.expect(!isConditionTrue([]const StandardCondition, &conds, "Ready"));
}

test "isConditionTrue returns false when condition missing" {
    // Arrange
    const conds = [_]StandardCondition{};

    // Act / Assert
    try testing.expect(!isConditionTrue([]const StandardCondition, &conds, "Ready"));
}

test "isConditionTrue returns false for null slice" {
    // Act
    const conds: ?[]const StandardCondition = null;

    // Assert
    try testing.expect(!isConditionTrue(?[]const StandardCondition, conds, "Ready"));
}

test "isConditionFalse returns true when matching" {
    // Arrange
    const conds = [_]LegacyCondition{
        .{ .type = "Available", .status = "False" },
    };

    // Act / Assert
    try testing.expect(isConditionFalse([]const LegacyCondition, &conds, "Available"));
}

test "isConditionFalse returns false when status differs" {
    // Arrange
    const conds = [_]LegacyCondition{
        .{ .type = "Available", .status = "True" },
    };

    // Act / Assert
    try testing.expect(!isConditionFalse([]const LegacyCondition, &conds, "Available"));
}

test "isConditionUnknown returns true when matching" {
    // Arrange
    const conds = [_]StandardCondition{
        .{ .type = "Ready", .status = "Unknown", .reason = "r", .message = "m", .lastTransitionTime = "t" },
    };

    // Act / Assert
    try testing.expect(isConditionUnknown([]const StandardCondition, &conds, "Ready"));
}

test "isConditionUnknown returns false when condition missing" {
    // Act
    const conds: ?[]const LegacyCondition = null;

    // Assert
    try testing.expect(!isConditionUnknown(?[]const LegacyCondition, conds, "Ready"));
}

// getConditionStatus tests
test "getConditionStatus returns correct enum" {
    // Arrange
    const conds = [_]StandardCondition{
        .{ .type = "Ready", .status = "False", .reason = "r", .message = "m", .lastTransitionTime = "t" },
    };

    // Act
    const status = getConditionStatus([]const StandardCondition, &conds, "Ready").?;

    // Assert
    try testing.expectEqual(ConditionStatus.condition_false, status);
}

test "getConditionStatus returns null for missing condition" {
    // Arrange
    const conds = [_]StandardCondition{};

    // Act / Assert
    try testing.expect(getConditionStatus([]const StandardCondition, &conds, "Ready") == null);
}

// setCondition tests
test "setCondition appends to null slice" {
    // Arrange
    const result = try setCondition(
        StandardCondition,
        null,
        .{ .type = "Ready", .status = .condition_true, .reason = "AllGood", .message = "ok" },
        "2024-01-01T00:00:00Z",
        testing.allocator,
    );
    defer testing.allocator.free(result);

    // Act / Assert
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("Ready", result[0].type);
    try testing.expectEqualStrings("True", result[0].status);
    try testing.expectEqualStrings("AllGood", result[0].reason);
    try testing.expectEqualStrings("ok", result[0].message);
    try testing.expectEqualStrings("2024-01-01T00:00:00Z", result[0].lastTransitionTime);
}

test "setCondition appends to existing slice" {
    // Arrange
    const initial = [_]StandardCondition{
        .{ .type = "Ready", .status = "True", .reason = "r", .message = "m", .lastTransitionTime = "t0" },
    };

    // Act
    const result = try setCondition(
        StandardCondition,
        &initial,
        .{ .type = "Available", .status = .condition_true, .reason = "Deployed", .message = "done" },
        "t1",
        testing.allocator,
    );
    defer testing.allocator.free(result);

    // Assert
    try testing.expectEqual(@as(usize, 2), result.len);
    try testing.expectEqualStrings("Ready", result[0].type);
    try testing.expectEqualStrings("Available", result[1].type);
}

test "setCondition preserves lastTransitionTime when status unchanged" {
    // Arrange
    const initial = [_]StandardCondition{
        .{ .type = "Ready", .status = "True", .reason = "OldReason", .message = "old", .lastTransitionTime = "2024-01-01T00:00:00Z" },
    };

    // Act
    const result = try setCondition(
        StandardCondition,
        &initial,
        .{ .type = "Ready", .status = .condition_true, .reason = "NewReason", .message = "new" },
        "2024-02-01T00:00:00Z",
        testing.allocator,
    );
    defer testing.allocator.free(result);

    // Assert
    try testing.expectEqualStrings("2024-01-01T00:00:00Z", result[0].lastTransitionTime);
    try testing.expectEqualStrings("NewReason", result[0].reason);
    try testing.expectEqualStrings("new", result[0].message);
}

test "setCondition updates lastTransitionTime when status changes" {
    // Arrange
    const initial = [_]StandardCondition{
        .{ .type = "Ready", .status = "True", .reason = "r", .message = "m", .lastTransitionTime = "2024-01-01T00:00:00Z" },
    };

    // Act
    const result = try setCondition(
        StandardCondition,
        &initial,
        .{ .type = "Ready", .status = .condition_false, .reason = "NotReady", .message = "fail" },
        "2024-02-01T00:00:00Z",
        testing.allocator,
    );
    defer testing.allocator.free(result);

    // Assert
    try testing.expectEqualStrings("2024-02-01T00:00:00Z", result[0].lastTransitionTime);
    try testing.expectEqualStrings("False", result[0].status);
}

test "setCondition sets observedGeneration when provided (StandardCondition)" {
    // Arrange
    const result = try setCondition(
        StandardCondition,
        null,
        .{ .type = "Ready", .status = .condition_true, .reason = "r", .message = "m", .observed_generation = 5 },
        "t",
        testing.allocator,
    );
    defer testing.allocator.free(result);

    // Act / Assert
    try testing.expectEqual(@as(?i64, 5), result[0].observedGeneration);
}

test "setCondition skips observedGeneration on LegacyCondition" {
    // Arrange
    const result = try setCondition(
        LegacyCondition,
        null,
        .{ .type = "Available", .status = .condition_true, .reason = "Deployed", .message = "ok", .observed_generation = 3 },
        "t",
        testing.allocator,
    );
    defer testing.allocator.free(result);

    // Act / Assert
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("Available", result[0].type);
}

test "setCondition handles optional fields (LegacyCondition)" {
    // Arrange
    const result = try setCondition(
        LegacyCondition,
        null,
        .{ .type = "Progressing", .status = .condition_true, .reason = "NewRS", .message = "rolling" },
        "2024-01-01T00:00:00Z",
        testing.allocator,
    );
    defer testing.allocator.free(result);

    // Act / Assert
    try testing.expectEqualStrings("Progressing", result[0].type);
    try testing.expectEqualStrings("True", result[0].status);
    try testing.expectEqualStrings("NewRS", result[0].reason.?);
    try testing.expectEqualStrings("rolling", result[0].message.?);
    try testing.expectEqualStrings("2024-01-01T00:00:00Z", result[0].lastTransitionTime.?);
    // lastUpdateTime should be null (unhandled optional field).
    try testing.expect(result[0].lastUpdateTime == null);
}

test "setCondition updates observedGeneration on existing condition" {
    // Arrange
    const initial = [_]StandardCondition{
        .{ .type = "Ready", .status = "True", .reason = "r", .message = "m", .lastTransitionTime = "t", .observedGeneration = 1 },
    };

    // Act
    const result = try setCondition(
        StandardCondition,
        &initial,
        .{ .type = "Ready", .status = .condition_true, .reason = "r2", .message = "m2", .observed_generation = 3 },
        "t2",
        testing.allocator,
    );
    defer testing.allocator.free(result);

    // Assert
    try testing.expectEqual(@as(?i64, 3), result[0].observedGeneration);
}

// removeCondition tests
test "removeCondition removes existing condition" {
    // Arrange
    const conds = [_]StandardCondition{
        .{ .type = "Ready", .status = "True", .reason = "r", .message = "m", .lastTransitionTime = "t" },
        .{ .type = "Available", .status = "True", .reason = "r", .message = "m", .lastTransitionTime = "t" },
    };

    // Act
    const result = (try removeCondition(StandardCondition, &conds, "Ready", testing.allocator)).?;
    defer testing.allocator.free(result);

    // Assert
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("Available", result[0].type);
}

test "removeCondition returns same-length slice when not found" {
    // Arrange
    const conds = [_]StandardCondition{
        .{ .type = "Ready", .status = "True", .reason = "r", .message = "m", .lastTransitionTime = "t" },
    };

    // Act
    const result = (try removeCondition(StandardCondition, &conds, "Missing", testing.allocator)).?;
    defer testing.allocator.free(result);

    // Assert
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("Ready", result[0].type);
}

test "removeCondition returns null for null input" {
    // Arrange
    const result = try removeCondition(StandardCondition, null, "Ready", testing.allocator);

    // Act / Assert
    try testing.expect(result == null);
}

test "removeCondition returns empty slice when removing only condition" {
    // Arrange
    const conds = [_]LegacyCondition{
        .{ .type = "Available", .status = "True" },
    };

    // Act
    const result = (try removeCondition(LegacyCondition, &conds, "Available", testing.allocator)).?;
    defer testing.allocator.free(result);

    // Assert
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "removeCondition works with LegacyCondition" {
    // Arrange
    const conds = [_]LegacyCondition{
        .{ .type = "Available", .status = "True" },
        .{ .type = "Progressing", .status = "True", .reason = "NewRS" },
    };

    // Act
    const result = (try removeCondition(LegacyCondition, &conds, "Available", testing.allocator)).?;
    defer testing.allocator.free(result);

    // Assert
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("Progressing", result[0].type);
}

// OOM tests
test "setCondition: OOM on allocation does not leak" {
    // Arrange
    var fa = std.testing.FailingAllocator.init(testing.allocator, .{});
    const initial = [_]StandardCondition{
        .{ .type = "Ready", .status = "True", .reason = "r", .message = "m", .lastTransitionTime = "t" },
    };

    // Act
    fa.fail_index = fa.alloc_index;

    // Assert
    try testing.expectError(error.OutOfMemory, setCondition(
        StandardCondition,
        &initial,
        .{ .type = "Available", .status = .condition_true, .reason = "r", .message = "m" },
        "t",
        fa.allocator(),
    ));
}
