const std = @import("std");
const testing = std.testing;

/// Inline-buffer holder for a Kubernetes resourceVersion string.
pub const ResourceVersion = struct {
    pub const max_len: usize = 128;

    buf: [max_len]u8 = undefined,
    len: ?u16 = null,

    /// Returns the stored value, or null if none has been assigned.
    pub fn slice(self: *const ResourceVersion) ?[]const u8 {
        const n = self.len orelse return null;
        return self.buf[0..n];
    }

    /// Store the given string. Returns error.ResourceVersionTooLong if it
    /// exceeds max_len.
    pub fn assign(self: *ResourceVersion, rv: []const u8) error{ResourceVersionTooLong}!void {
        if (rv.len > max_len) return error.ResourceVersionTooLong;
        @memcpy(self.buf[0..rv.len], rv);
        self.len = @intCast(rv.len);
    }

    /// Clear the stored value so that slice() returns null.
    pub fn clear(self: *ResourceVersion) void {
        self.len = null;
    }

    /// Returns true if a value has been assigned (even if empty).
    pub fn isSet(self: *const ResourceVersion) bool {
        return self.len != null;
    }
};

test "ResourceVersion: default is unset" {
    // Act
    const rv = ResourceVersion{};

    // Assert
    try testing.expect(!rv.isSet());
    try testing.expect(rv.slice() == null);
}

test "ResourceVersion: assign and slice round-trip" {
    // Arrange
    var rv = ResourceVersion{};

    // Act
    try rv.assign("12345");

    // Assert
    try testing.expect(rv.isSet());
    try testing.expectEqualStrings("12345", rv.slice().?);
}

test "ResourceVersion: assign empty string marks as set" {
    // Arrange
    var rv = ResourceVersion{};

    // Act
    try rv.assign("");

    // Assert
    try testing.expect(rv.isSet());
    try testing.expectEqualStrings("", rv.slice().?);
}

test "ResourceVersion: clear resets to unset" {
    // Arrange
    var rv = ResourceVersion{};
    try rv.assign("999");

    // Act
    rv.clear();

    // Assert
    try testing.expect(!rv.isSet());
    try testing.expect(rv.slice() == null);
}

test "ResourceVersion: oversize string returns error and leaves value unchanged" {
    // Arrange
    var rv = ResourceVersion{};
    const big: [ResourceVersion.max_len + 1]u8 = [_]u8{'x'} ** (ResourceVersion.max_len + 1);

    // Act / Assert
    try testing.expectError(error.ResourceVersionTooLong, rv.assign(&big));
    try testing.expect(!rv.isSet());
}

test "ResourceVersion: max_len string is accepted" {
    // Arrange
    var rv = ResourceVersion{};
    const exactly_max: [ResourceVersion.max_len]u8 = [_]u8{'a'} ** ResourceVersion.max_len;

    // Act
    try rv.assign(&exactly_max);

    // Assert
    try testing.expect(rv.isSet());
    try testing.expectEqual(@as(usize, ResourceVersion.max_len), rv.slice().?.len);
}

test "ResourceVersion: assign overwrites previous value" {
    // Arrange
    var rv = ResourceVersion{};
    try rv.assign("old");

    // Act
    try rv.assign("new-value");

    // Assert
    try testing.expectEqualStrings("new-value", rv.slice().?);
}
