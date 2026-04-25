//! Retry policy with exponential backoff and jitter for transient HTTP errors.
//!
//! Provides `RetryPolicy` for configuring retry attempts, backoff growth, and
//! jitter. Also includes helpers for parsing the HTTP `Retry-After` header
//! (seconds-only format) and for identifying retryable HTTP status codes.

const std = @import("std");
const http = std.http;
const testing = std.testing;

/// Configures retry behavior with exponential backoff.
pub const RetryPolicy = struct {
    /// Maximum number of retry attempts before giving up (default: 3).
    max_retries: u32 = 3,
    /// Backoff duration in nanoseconds for the first retry (default: 500 ms).
    initial_backoff_ns: u64 = 500 * std.time.ns_per_ms,
    /// Upper bound on backoff duration in nanoseconds (default: 30 s).
    max_backoff_ns: u64 = 30 * std.time.ns_per_s,
    /// Multiplier applied to the backoff after each attempt (default: 2).
    backoff_multiplier: u32 = 2,
    /// Add random jitter to avoid thundering-herd retries (default: true).
    jitter: bool = true,

    /// A policy that performs no retries.
    pub const disabled: RetryPolicy = .{ .max_retries = 0 };

    /// Compute the base backoff for a given attempt (0-indexed), without jitter.
    /// The result is capped at `max_backoff_ns`.
    pub fn backoffNs(self: RetryPolicy, attempt: u32) u64 {
        // Compute multiplier^attempt via exponentiation by squaring with
        // saturating arithmetic, then multiply by initial_backoff_ns.
        var power: u64 = 1;
        var base: u64 = self.backoff_multiplier;
        var exp = attempt;
        while (exp > 0) {
            if (exp & 1 == 1) {
                power = power *| base;
            }
            exp >>= 1;
            if (exp > 0) {
                base = base *| base;
                if (base == std.math.maxInt(u64)) {
                    // Fully saturated; remaining bits won't change the result.
                    power = power *| base;
                    break;
                }
            }
        }
        return @min(self.initial_backoff_ns *| power, self.max_backoff_ns);
    }

    /// Compute backoff with optional jitter (uniform random in [0, backoff]).
    pub fn backoffWithJitterNs(self: RetryPolicy, io: std.Io, attempt: u32) u64 {
        const base = self.backoffNs(attempt);
        if (!self.jitter or base == 0) return base;
        // Uniformly sample [0, base] using an 8-byte CSPRNG draw.
        var raw: [8]u8 = undefined;
        io.random(&raw);
        const r: u64 = std.mem.readInt(u64, &raw, .little);
        return r % (base +| 1);
    }

    /// Compute the sleep duration for a retry attempt.
    /// If the server sent a Retry-After header, use the larger of
    /// the computed backoff and the server-requested delay.
    pub fn sleepNs(self: RetryPolicy, io: std.Io, attempt: u32, retry_after_ns: ?u64) u64 {
        const backoff = if (self.jitter) self.backoffWithJitterNs(io, attempt) else self.backoffNs(attempt);
        if (retry_after_ns) |ra| {
            return @max(backoff, ra);
        }
        return backoff;
    }

    /// Returns true if the HTTP status code is retryable.
    pub fn isRetryableStatus(status: http.Status) bool {
        return switch (status) {
            .too_many_requests, .bad_gateway, .service_unavailable, .gateway_timeout => true,
            else => false,
        };
    }
};

/// Parse a Retry-After header value in seconds-only format (e.g. "120").
/// Returns the value in nanoseconds, or null if the value is not a valid integer.
pub fn parseRetryAfterNs(value: []const u8) ?u64 {
    const trimmed = std.mem.trim(u8, value, " \t");
    const seconds = std.fmt.parseUnsigned(u64, trimmed, 10) catch return null;
    return seconds *| std.time.ns_per_s;
}

/// Search raw HTTP header bytes for a Retry-After header value.
pub fn findRetryAfterInBytes(bytes: []const u8) ?[]const u8 {
    const needle = "retry-after:";
    var it = std.mem.splitSequence(u8, bytes, "\r\n");
    // Skip status line.
    _ = it.next();
    while (it.next()) |line| {
        if (line.len == 0) break;
        if (line.len < needle.len) continue;
        if (std.ascii.eqlIgnoreCase(line[0..needle.len], needle)) {
            return std.mem.trim(u8, line[needle.len..], " \t");
        }
    }
    return null;
}

test "backoffNs: exponential growth" {
    // Arrange
    const policy = RetryPolicy{
        .initial_backoff_ns = 100,
        .backoff_multiplier = 2,
        .max_backoff_ns = 10_000,
        .jitter = false,
    };

    // Act / Assert
    try testing.expectEqual(@as(u64, 100), policy.backoffNs(0));
    try testing.expectEqual(@as(u64, 200), policy.backoffNs(1));
    try testing.expectEqual(@as(u64, 400), policy.backoffNs(2));
    try testing.expectEqual(@as(u64, 800), policy.backoffNs(3));
}

test "backoffNs: capped at max" {
    // Arrange
    const policy = RetryPolicy{
        .initial_backoff_ns = 100,
        .backoff_multiplier = 2,
        .max_backoff_ns = 300,
        .jitter = false,
    };

    // Act / Assert
    try testing.expectEqual(@as(u64, 100), policy.backoffNs(0));
    try testing.expectEqual(@as(u64, 200), policy.backoffNs(1));
    try testing.expectEqual(@as(u64, 300), policy.backoffNs(2)); // capped
    try testing.expectEqual(@as(u64, 300), policy.backoffNs(3)); // still capped
}

test "backoffNs: saturating multiply does not overflow" {
    // Arrange
    const policy = RetryPolicy{
        .initial_backoff_ns = std.math.maxInt(u64) - 1,
        .backoff_multiplier = 2,
        .max_backoff_ns = std.math.maxInt(u64),
        .jitter = false,
    };

    // Act
    // Should not overflow, saturates to maxInt then capped.
    const result = policy.backoffNs(5);

    // Assert
    try testing.expectEqual(std.math.maxInt(u64), result);
}

test "backoffWithJitterNs: result within bounds" {
    // Arrange
    const policy = RetryPolicy{
        .initial_backoff_ns = 1000,
        .backoff_multiplier = 2,
        .max_backoff_ns = 100_000,
        .jitter = true,
    };

    // Act / Assert
    // Run several times; result must be in [0, backoff].
    for (0..20) |_| {
        const base = policy.backoffNs(2);
        const jittered = policy.backoffWithJitterNs(std.testing.io, 2);
        try testing.expect(jittered <= base);
    }
}

test "backoffWithJitterNs: no jitter returns exact backoff" {
    // Arrange
    const policy = RetryPolicy{
        .initial_backoff_ns = 1000,
        .backoff_multiplier = 2,
        .max_backoff_ns = 100_000,
        .jitter = false,
    };

    // Act / Assert
    try testing.expectEqual(policy.backoffNs(1), policy.backoffWithJitterNs(std.testing.io, 1));
}

test "parseRetryAfterNs: valid integer" {
    // Act / Assert
    try testing.expectEqual(@as(u64, 120 * std.time.ns_per_s), parseRetryAfterNs("120").?);
}

test "parseRetryAfterNs: zero" {
    // Act / Assert
    try testing.expectEqual(@as(u64, 0), parseRetryAfterNs("0").?);
}

test "parseRetryAfterNs: whitespace trimmed" {
    // Act / Assert
    try testing.expectEqual(@as(u64, 5 * std.time.ns_per_s), parseRetryAfterNs("  5  ").?);
}

test "parseRetryAfterNs: invalid (date format)" {
    // Act / Assert
    try testing.expectEqual(@as(?u64, null), parseRetryAfterNs("Thu, 01 Dec 1994 16:00:00 GMT"));
}

test "parseRetryAfterNs: invalid (empty)" {
    // Act / Assert
    try testing.expectEqual(@as(?u64, null), parseRetryAfterNs(""));
}

test "parseRetryAfterNs: invalid (negative)" {
    // Act / Assert
    try testing.expectEqual(@as(?u64, null), parseRetryAfterNs("-1"));
}

test "isRetryableStatus: retryable statuses" {
    // Act / Assert
    try testing.expect(RetryPolicy.isRetryableStatus(.too_many_requests));
    try testing.expect(RetryPolicy.isRetryableStatus(.bad_gateway));
    try testing.expect(RetryPolicy.isRetryableStatus(.service_unavailable));
    try testing.expect(RetryPolicy.isRetryableStatus(.gateway_timeout));
}

test "isRetryableStatus: non-retryable statuses" {
    // Act / Assert
    try testing.expect(!RetryPolicy.isRetryableStatus(.not_found));
    try testing.expect(!RetryPolicy.isRetryableStatus(.internal_server_error));
    try testing.expect(!RetryPolicy.isRetryableStatus(.ok));
    try testing.expect(!RetryPolicy.isRetryableStatus(.bad_request));
}

test "sleepNs: without retry-after uses backoff" {
    // Arrange
    const policy = RetryPolicy{
        .initial_backoff_ns = 1000,
        .backoff_multiplier = 2,
        .max_backoff_ns = 100_000,
        .jitter = false,
    };

    // Act / Assert
    try testing.expectEqual(@as(u64, 1000), policy.sleepNs(std.testing.io, 0, null));
    try testing.expectEqual(@as(u64, 2000), policy.sleepNs(std.testing.io, 1, null));
}

test "sleepNs: retry-after overrides when larger" {
    // Arrange
    const policy = RetryPolicy{
        .initial_backoff_ns = 1000,
        .backoff_multiplier = 2,
        .max_backoff_ns = 100_000,
        .jitter = false,
    };

    // Act / Assert
    // retry-after = 50_000 is larger than backoff of 1000
    try testing.expectEqual(@as(u64, 50_000), policy.sleepNs(std.testing.io, 0, 50_000));
}

test "sleepNs: backoff used when larger than retry-after" {
    // Arrange
    const policy = RetryPolicy{
        .initial_backoff_ns = 100_000,
        .backoff_multiplier = 2,
        .max_backoff_ns = 1_000_000,
        .jitter = false,
    };

    // Act / Assert
    // backoff of 100_000 is larger than retry-after of 500
    try testing.expectEqual(@as(u64, 100_000), policy.sleepNs(std.testing.io, 0, 500));
}

test "disabled policy has zero max_retries" {
    // Act / Assert
    try testing.expectEqual(@as(u32, 0), RetryPolicy.disabled.max_retries);
}

test "findRetryAfterInBytes: found in raw headers" {
    // Arrange
    const raw = "HTTP/1.1 429 Too Many Requests\r\nContent-Type: application/json\r\nRetry-After: 30\r\n\r\n";

    // Act
    const result = findRetryAfterInBytes(raw);

    // Assert
    try testing.expect(result != null);
    try testing.expectEqualStrings("30", result.?);
}

test "findRetryAfterInBytes: case insensitive" {
    // Arrange
    const raw = "HTTP/1.1 503 Service Unavailable\r\nretry-after: 60\r\n\r\n";

    // Act
    const result = findRetryAfterInBytes(raw);

    // Assert
    try testing.expect(result != null);
    try testing.expectEqualStrings("60", result.?);
}

test "findRetryAfterInBytes: not found" {
    // Arrange
    const raw = "HTTP/1.1 500 Internal Server Error\r\nContent-Type: text/plain\r\n\r\n";

    // Act
    const result = findRetryAfterInBytes(raw);

    // Assert
    try testing.expect(result == null);
}
