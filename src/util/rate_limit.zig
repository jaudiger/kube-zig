//! Token bucket rate limiter for controlling request throughput.
//!
//! Provides a thread-safe rate limiter that enforces a sustained queries-per-second
//! (QPS) limit with configurable burst capacity. Supports blocking acquisition
//! (with cancellation via Context), non-blocking try-acquire, and a reserve mode
//! that allows debt accumulation for use in work queue scheduling.

const std = @import("std");
const context_mod = @import("context.zig");
const Context = context_mod.Context;
const logging_mod = @import("logging.zig");
const Logger = logging_mod.Logger;
const LogField = logging_mod.Field;
const testing = std.testing;

/// Token bucket rate limiter.
///
/// Limits request throughput to a configured QPS with burst capacity
/// (default: 5 QPS, burst 10).
pub const RateLimiter = struct {
    mutex: std.Io.Mutex = .init,
    tokens: f64,
    max_tokens: f64,
    refill_rate_ns: f64, // tokens per nanosecond
    last_refill: std.Io.Clock.Timestamp,
    logger: Logger = Logger.noop,

    /// Configuration for the token bucket rate limiter.
    pub const Config = struct {
        /// Sustained queries per second. Set to 0 to disable.
        qps: f64 = 5.0,
        /// Maximum burst size above the sustained QPS rate.
        burst: u32 = 10,
        /// Structured logger. Default is no-op.
        logger: Logger = Logger.noop,

        /// A config that disables rate limiting entirely.
        pub const disabled: Config = .{ .qps = 0.0, .burst = 0 };
    };

    /// Initialize a rate limiter from the given config.
    /// Returns null if the config disables rate limiting.
    pub fn init(io: std.Io, config: Config) error{TimerUnsupported}!?RateLimiter {
        if (config.qps <= 0.0 or config.burst == 0) return null;

        const now: std.Io.Clock.Timestamp = .now(io, .awake);
        const max: f64 = @floatFromInt(config.burst);

        return .{
            .tokens = max, // start with a full bucket
            .max_tokens = max,
            .refill_rate_ns = config.qps / @as(f64, @floatFromInt(std.time.ns_per_s)),
            .last_refill = now,
            .logger = config.logger.withScope("rate_limit"),
        };
    }

    /// Block until a token is available, or return `error.Canceled`
    /// when the context signals cancellation.
    pub fn acquire(self: *RateLimiter, io: std.Io, ctx: Context) error{Canceled}!void {
        while (true) {
            try ctx.check(io);

            const sleep_ns = blk: {
                self.mutex.lockUncancelable(io);
                defer self.mutex.unlock(io);

                self.refill(io);

                if (self.tokens >= 1.0) {
                    self.tokens -= 1.0;
                    return;
                }

                // Calculate how long until one token is available.
                const deficit = 1.0 - self.tokens;
                break :blk @as(u64, @intFromFloat(@ceil(deficit / self.refill_rate_ns)));
            };

            self.logger.debug("rate limited", &.{
                LogField.uint("wait_ms", sleep_ns / std.time.ns_per_ms),
            });
            try context_mod.interruptibleSleep(io, ctx, sleep_ns);
        }
    }

    /// Consume a token (allowing the balance to go negative / into debt)
    /// and return the wait duration in nanoseconds before the token is
    /// replenished. Returns 0 when a token is immediately available.
    ///
    /// Used by the overall rate limiter in WorkQueue to compute a global
    /// delay that is combined (via max) with per-key backoff.
    pub fn reserve(self: *RateLimiter, io: std.Io) u64 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        self.refill(io);

        if (self.tokens >= 1.0) {
            self.tokens -= 1.0;
            return 0;
        }

        const deficit = 1.0 - self.tokens;
        self.tokens -= 1.0; // go into debt
        return @intFromFloat(@ceil(deficit / self.refill_rate_ns));
    }

    /// Try to acquire a token without blocking.
    /// Returns true if a token was consumed, false otherwise.
    pub fn tryAcquire(self: *RateLimiter, io: std.Io) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        self.refill(io);

        if (self.tokens >= 1.0) {
            self.tokens -= 1.0;
            return true;
        }
        return false;
    }

    /// Refill tokens based on elapsed time. Must be called with mutex held.
    fn refill(self: *RateLimiter, io: std.Io) void {
        const now: std.Io.Clock.Timestamp = .now(io, .awake);
        const elapsed_ns_i: i96 = self.last_refill.durationTo(now).raw.nanoseconds;
        if (elapsed_ns_i <= 0) return;
        const elapsed_ns: f64 = @floatFromInt(elapsed_ns_i);
        const new_tokens = elapsed_ns * self.refill_rate_ns;

        if (new_tokens > 0.0) {
            self.tokens = @min(self.tokens + new_tokens, self.max_tokens);
            self.last_refill = now;
        }
    }
};

test "init with defaults returns non-null" {
    // Act
    const limiter = try RateLimiter.init(std.testing.io, .{});

    // Assert
    try testing.expect(limiter != null);
}

test "init with disabled config returns null" {
    // Act
    const limiter = try RateLimiter.init(std.testing.io, RateLimiter.Config.disabled);

    // Assert
    try testing.expect(limiter == null);
}

test "init with zero qps returns null" {
    // Act
    const limiter = try RateLimiter.init(std.testing.io, .{ .qps = 0.0, .burst = 10 });

    // Assert
    try testing.expect(limiter == null);
}

test "init with zero burst returns null" {
    // Act
    const limiter = try RateLimiter.init(std.testing.io, .{ .qps = 5.0, .burst = 0 });

    // Assert
    try testing.expect(limiter == null);
}

test "init: starts with full bucket" {
    // Arrange
    var limiter = (try RateLimiter.init(std.testing.io, .{ .qps = 10.0, .burst = 5 })).?;
    _ = &limiter;

    // Act / Assert
    try testing.expectEqual(@as(f64, 5.0), limiter.max_tokens);
    try testing.expect(limiter.tokens == limiter.max_tokens);
}

test "tryAcquire: consumes tokens" {
    // Arrange
    var limiter = (try RateLimiter.init(std.testing.io, .{ .qps = 10.0, .burst = 3 })).?;

    // Act
    try testing.expect(limiter.tryAcquire(std.testing.io));
    try testing.expect(limiter.tryAcquire(std.testing.io));
    try testing.expect(limiter.tryAcquire(std.testing.io));

    // Assert
    try testing.expect(!limiter.tryAcquire(std.testing.io));
}

test "acquire: consumes token from full bucket" {
    // Arrange
    var limiter = (try RateLimiter.init(std.testing.io, .{ .qps = 10.0, .burst = 5 })).?;

    // Act
    try limiter.acquire(std.testing.io, Context.background());

    // Assert
    try testing.expect(limiter.tokens < limiter.max_tokens);
}

test "refill: tokens accumulate over time" {
    // Arrange
    var limiter = (try RateLimiter.init(std.testing.io, .{ .qps = 1000.0, .burst = 5 })).?;

    // Act
    // Drain all tokens.
    for (0..5) |_| {
        try testing.expect(limiter.tryAcquire(std.testing.io));
    }
    try testing.expect(!limiter.tryAcquire(std.testing.io));

    // Assert
    std.Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .{ .nanoseconds = 10 * std.time.ns_per_ms } }, std.testing.io) catch {};

    try testing.expect(limiter.tryAcquire(std.testing.io));
}

test "acquire: returns Canceled when context is already canceled" {
    // Arrange
    var limiter = (try RateLimiter.init(std.testing.io, .{ .qps = 10.0, .burst = 5 })).?;
    var cs = context_mod.CancelSource.init();
    cs.cancel(std.testing.io);
    const ctx = cs.context();

    // Act / Assert
    try testing.expectError(error.Canceled, limiter.acquire(std.testing.io, ctx));
}

test "acquire: returns Canceled when context is canceled while waiting" {
    // Arrange
    var limiter = (try RateLimiter.init(std.testing.io, .{ .qps = 1.0, .burst = 1 })).?;
    try testing.expect(limiter.tryAcquire(std.testing.io));
    try testing.expect(!limiter.tryAcquire(std.testing.io));

    // Act
    var cs = context_mod.CancelSource.init();
    const ctx = cs.context();

    // Assert
    // Cancel from another thread after a short delay.
    const cancel_thread = try std.Thread.spawn(.{}, struct {
        fn run(io: std.Io, cancel_source: *context_mod.CancelSource) void {
            std.Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .{ .nanoseconds = 50 * std.time.ns_per_ms } }, io) catch {};
            cancel_source.cancel(io);
        }
    }.run, .{ std.testing.io, &cs });

    try testing.expectError(error.Canceled, limiter.acquire(std.testing.io, ctx));

    cancel_thread.join();
}

test "tryAcquire: concurrent access from multiple threads" {
    // Arrange
    var limiter = (try RateLimiter.init(std.testing.io, .{ .qps = 1.0, .burst = 10 })).?;
    var success_count = std.atomic.Value(u32).init(0);

    // Act
    const Worker = struct {
        fn run(io: std.Io, lim: *RateLimiter, counter: *std.atomic.Value(u32)) void {
            for (0..5) |_| {
                if (lim.tryAcquire(io)) {
                    _ = counter.fetchAdd(1, .monotonic);
                }
            }
        }
    };

    // Assert
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{ std.testing.io, &limiter, &success_count });
    }
    for (&threads) |t| {
        t.join();
    }

    const total = success_count.load(.acquire);
    try testing.expect(total >= 1);
    try testing.expect(total <= 10); // Cannot exceed burst capacity
}

test "reserve: returns 0 when token available" {
    // Arrange
    var limiter = (try RateLimiter.init(std.testing.io, .{ .qps = 10.0, .burst = 5 })).?;

    // Act
    const delay = limiter.reserve(std.testing.io);

    // Assert
    try testing.expectEqual(@as(u64, 0), delay);
    try testing.expect(limiter.tokens < limiter.max_tokens);
}

test "reserve: returns positive delay when exhausted" {
    // Arrange
    var limiter = (try RateLimiter.init(std.testing.io, .{ .qps = 10.0, .burst = 2 })).?;

    // Act
    const d1 = limiter.reserve(std.testing.io);
    const d2 = limiter.reserve(std.testing.io);
    const d3 = limiter.reserve(std.testing.io); // bucket now empty, should return delay

    // Assert
    try testing.expectEqual(@as(u64, 0), d1);
    try testing.expectEqual(@as(u64, 0), d2);
    try testing.expect(d3 > 0);
}

test "reserve: debt accumulates across calls" {
    // Arrange
    var limiter = (try RateLimiter.init(std.testing.io, .{ .qps = 10.0, .burst = 1 })).?;

    // Act
    _ = limiter.reserve(std.testing.io); // consumes the 1 available token
    const d1 = limiter.reserve(std.testing.io); // first debt call
    const d2 = limiter.reserve(std.testing.io); // second debt call, more debt

    // Assert
    try testing.expect(d1 > 0);
    try testing.expect(d2 > d1); // deeper debt means longer wait
}

test "reserve: debt repays over time" {
    // Arrange
    var limiter = (try RateLimiter.init(std.testing.io, .{ .qps = 1000.0, .burst = 1 })).?;

    // Act
    _ = limiter.reserve(std.testing.io); // consume the one token
    const d1 = limiter.reserve(std.testing.io); // go into debt

    // Assert
    try testing.expect(d1 > 0);

    // Wait for refill to repay the debt.
    std.Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .{ .nanoseconds = 10 * std.time.ns_per_ms } }, std.testing.io) catch {};

    // After waiting, a token should be available again.
    const d2 = limiter.reserve(std.testing.io);
    try testing.expectEqual(@as(u64, 0), d2);
}
