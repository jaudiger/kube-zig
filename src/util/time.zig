//! Shared RFC 3339 / ISO 8601 timestamp utilities: formatting and parsing.
//!
//! **Formatting**: `writeNow` / `bufNow` produce UTC timestamps at three
//! comptime-selectable precision levels:
//!
//! ```zig
//! // Writer-based (loggers):
//! try time.writeNow(.nanos, writer);
//!
//! // Buffer-based (events, conditions):
//! var buf: [time.Precision.seconds.bufLen()]u8 = undefined;
//! const ts = time.bufNow(.seconds, &buf);
//! ```
//!
//! **Parsing**: `parseTimestamp` converts an RFC 3339 UTC string back to
//! Unix epoch seconds:
//!
//! ```zig
//! const epoch = time.parseTimestamp("2026-02-12T15:30:00Z") orelse return error.BadTimestamp;
//! ```

const std = @import("std");
const testing = std.testing;

/// Return nanoseconds elapsed since `epoch` on the monotonic clock.
pub fn monotonicNowNs(epoch: std.time.Instant) error{ClockUnavailable}!u64 {
    return (std.time.Instant.now() catch return error.ClockUnavailable).since(epoch);
}

/// Timestamp precision for RFC 3339 formatting.
pub const Precision = enum {
    /// `YYYY-MM-DDThh:mm:ssZ` (20 bytes).
    seconds,
    /// `YYYY-MM-DDThh:mm:ss.000000Z` (27 bytes, hardcoded zero microseconds).
    micros,
    /// `YYYY-MM-DDThh:mm:ss.nnnnnnnnnZ` (30 bytes, real nanoseconds).
    nanos,

    /// Comptime-known output length for each precision.
    pub fn bufLen(comptime self: Precision) comptime_int {
        return switch (self) {
            .seconds => 20,
            .micros => 27,
            .nanos => 30,
        };
    }
};

/// Decomposed UTC date/time components from an epoch-seconds value.
const DateTime = struct {
    year: u16,
    month: u8,
    day: u8,
    hours: u8,
    minutes: u8,
    seconds: u8,
};

/// Break epoch seconds into calendar components.
fn decompose(secs: u64) DateTime {
    const epoch_secs: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const epoch_day = epoch_secs.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = epoch_secs.getDaySeconds();

    return .{
        .year = year_day.year,
        .month = @intFromEnum(month_day.month),
        .day = month_day.day_index + 1,
        .hours = day_secs.getHoursIntoDay(),
        .minutes = day_secs.getMinutesIntoHour(),
        .seconds = day_secs.getSecondsIntoMinute(),
    };
}

/// Write the date-time prefix (`YYYY-MM-DDThh:mm:ss`) shared by all precisions.
fn writeDateTime(w: anytype, dt: DateTime) !void {
    try w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
        dt.year, dt.month, dt.day, dt.hours, dt.minutes, dt.seconds,
    });
}

/// Write the current UTC time as an RFC 3339 timestamp at the given
/// comptime-known precision.
///
/// - `.seconds`: `YYYY-MM-DDThh:mm:ssZ`
/// - `.micros`:  `YYYY-MM-DDThh:mm:ss.000000Z`
/// - `.nanos`:   `YYYY-MM-DDThh:mm:ss.nnnnnnnnnZ`
pub fn writeNow(comptime precision: Precision, w: anytype) !void {
    switch (precision) {
        .nanos => {
            const nanos = std.time.nanoTimestamp();
            const nanos_unsigned: u128 = @intCast(@max(0, nanos));
            const secs: u64 = std.math.cast(u64, nanos_unsigned / std.time.ns_per_s) orelse return error.Overflow;
            const frac: u32 = @intCast(nanos_unsigned % std.time.ns_per_s);

            const dt = decompose(secs);
            try writeDateTime(w, dt);
            try w.print(".{d:0>9}Z", .{frac});
        },
        .micros => {
            const secs: u64 = @intCast(@max(0, std.time.timestamp()));
            const dt = decompose(secs);
            try writeDateTime(w, dt);
            try w.writeAll(".000000Z");
        },
        .seconds => {
            const secs: u64 = @intCast(@max(0, std.time.timestamp()));
            const dt = decompose(secs);
            try writeDateTime(w, dt);
            try w.writeByte('Z');
        },
    }
}

/// Format the current UTC time into a fixed-size buffer and return the
/// written slice.  The buffer size is comptime-derived from the precision.
pub fn bufNow(comptime precision: Precision, buf: *[precision.bufLen()]u8) []const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    writeNow(precision, fbs.writer()) catch unreachable;
    return fbs.getWritten();
}

// Parsing
/// Parse an RFC 3339 UTC timestamp into Unix epoch seconds.
///
/// Accepts the standard Kubernetes format `YYYY-MM-DDThh:mm:ssZ`.
/// Fractional seconds (e.g. `.000000Z`, `.123456789Z`) are accepted
/// but discarded; the return value has second-level precision.
///
/// Returns `null` when the input is malformed.
pub fn parseTimestamp(ts: []const u8) ?i64 {
    if (ts.len < 20) return null;
    if (ts[4] != '-' or ts[7] != '-' or ts[10] != 'T' or
        ts[13] != ':' or ts[16] != ':') return null;
    if (ts[ts.len - 1] != 'Z') return null;

    const year = std.fmt.parseInt(u16, ts[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, ts[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, ts[8..10], 10) catch return null;
    const hours = std.fmt.parseInt(u8, ts[11..13], 10) catch return null;
    const minutes = std.fmt.parseInt(u8, ts[14..16], 10) catch return null;
    const seconds = std.fmt.parseInt(u8, ts[17..19], 10) catch return null;

    if (month < 1 or month > 12 or day < 1 or day > 31) return null;
    if (hours > 23 or minutes > 59 or seconds > 60) return null;

    const epoch_days = civilToEpochDays(year, month, day);
    return epoch_days * 86400 +
        @as(i64, hours) * 3600 + @as(i64, minutes) * 60 + @as(i64, seconds);
}

/// Convert a civil date to days since 1970-01-01 (algorithm by Howard Hinnant).
fn civilToEpochDays(year: u16, month: u8, day: u8) i64 {
    var y: i64 = @intCast(year);
    const m: i64 = @intCast(month);
    const d: i64 = @intCast(day);

    if (m <= 2) y -= 1;
    const era: i64 = @divFloor(y, 400);
    const yoe: i64 = y - era * 400;
    const mp: i64 = if (m > 2) m - 3 else m + 9;
    const doy: i64 = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe: i64 = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

test "decompose: epoch zero is 1970-01-01T00:00:00" {
    // Act
    const dt = decompose(0);

    // Assert
    try testing.expectEqual(@as(u16, 1970), dt.year);
    try testing.expectEqual(@as(u8, 1), dt.month);
    try testing.expectEqual(@as(u8, 1), dt.day);
    try testing.expectEqual(@as(u8, 0), dt.hours);
    try testing.expectEqual(@as(u8, 0), dt.minutes);
    try testing.expectEqual(@as(u8, 0), dt.seconds);
}

test "decompose: known timestamp 2024-06-15T13:30:45" {
    // Act
    const dt = decompose(1718458245);

    // Assert
    try testing.expectEqual(@as(u16, 2024), dt.year);
    try testing.expectEqual(@as(u8, 6), dt.month);
    try testing.expectEqual(@as(u8, 15), dt.day);
    try testing.expectEqual(@as(u8, 13), dt.hours);
    try testing.expectEqual(@as(u8, 30), dt.minutes);
    try testing.expectEqual(@as(u8, 45), dt.seconds);
}

test "Precision.bufLen: returns correct sizes" {
    // Act / Assert
    try testing.expectEqual(20, Precision.seconds.bufLen());
    try testing.expectEqual(27, Precision.micros.bufLen());
    try testing.expectEqual(30, Precision.nanos.bufLen());
}

test "bufNow seconds: produces correct length and format" {
    // Arrange
    var buf: [Precision.seconds.bufLen()]u8 = undefined;

    // Act
    const result = bufNow(.seconds, &buf);

    // Assert
    try testing.expectEqual(@as(usize, 20), result.len);
    try testing.expectEqual(@as(u8, '-'), result[4]);
    try testing.expectEqual(@as(u8, '-'), result[7]);
    try testing.expectEqual(@as(u8, 'T'), result[10]);
    try testing.expectEqual(@as(u8, ':'), result[13]);
    try testing.expectEqual(@as(u8, ':'), result[16]);
    try testing.expectEqual(@as(u8, 'Z'), result[19]);
}

test "bufNow micros: produces correct length and format" {
    // Arrange
    var buf: [Precision.micros.bufLen()]u8 = undefined;

    // Act
    const result = bufNow(.micros, &buf);

    // Assert
    try testing.expectEqual(@as(usize, 27), result.len);
    try testing.expectEqual(@as(u8, '-'), result[4]);
    try testing.expectEqual(@as(u8, '-'), result[7]);
    try testing.expectEqual(@as(u8, 'T'), result[10]);
    try testing.expectEqual(@as(u8, ':'), result[13]);
    try testing.expectEqual(@as(u8, ':'), result[16]);
    try testing.expectEqual(@as(u8, '.'), result[19]);
    try testing.expectEqual(@as(u8, 'Z'), result[26]);
}

test "writeNow nanos: produces correct length and format" {
    // Arrange
    var buf: [Precision.nanos.bufLen()]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    // Act
    try writeNow(.nanos, fbs.writer());
    const result = fbs.getWritten();

    // Assert
    try testing.expectEqual(@as(usize, 30), result.len);
    try testing.expectEqual(@as(u8, '-'), result[4]);
    try testing.expectEqual(@as(u8, '-'), result[7]);
    try testing.expectEqual(@as(u8, 'T'), result[10]);
    try testing.expectEqual(@as(u8, ':'), result[13]);
    try testing.expectEqual(@as(u8, ':'), result[16]);
    try testing.expectEqual(@as(u8, '.'), result[19]);
    try testing.expectEqual(@as(u8, 'Z'), result[29]);
}

test "parseTimestamp: epoch zero" {
    // Act / Assert
    try testing.expectEqual(@as(i64, 0), parseTimestamp("1970-01-01T00:00:00Z").?);
}

test "parseTimestamp: known value" {
    // Act / Assert
    try testing.expectEqual(@as(i64, 1718458245), parseTimestamp("2024-06-15T13:30:45Z").?);
}

test "parseTimestamp: fractional seconds are ignored" {
    // Act / Assert
    try testing.expectEqual(@as(i64, 1718458245), parseTimestamp("2024-06-15T13:30:45.000000Z").?);
    try testing.expectEqual(@as(i64, 1718458245), parseTimestamp("2024-06-15T13:30:45.123456789Z").?);
}

test "parseTimestamp: rejects malformed input" {
    // Act / Assert
    try testing.expectEqual(@as(?i64, null), parseTimestamp(""));
    try testing.expectEqual(@as(?i64, null), parseTimestamp("not-a-timestamp-----"));
    try testing.expectEqual(@as(?i64, null), parseTimestamp("2024-06-15T13:30:45")); // missing Z
    try testing.expectEqual(@as(?i64, null), parseTimestamp("2024-13-15T13:30:45Z")); // month 13
    try testing.expectEqual(@as(?i64, null), parseTimestamp("2024-06-15T25:30:45Z")); // hour 25
}

test "parseTimestamp: round-trip with decompose" {
    // Arrange
    const epoch: i64 = 1718458245;
    const dt = decompose(@intCast(epoch));

    // Act
    var buf: [Precision.seconds.bufLen()]u8 = undefined;
    const formatted = std.fmt.bufPrint(&buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        dt.year, dt.month, dt.day, dt.hours, dt.minutes, dt.seconds,
    }) catch unreachable;

    // Assert
    try testing.expectEqual(epoch, parseTimestamp(formatted).?);
}
