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
    mutex: std.Thread.Mutex = .{},
    tokens: f64,
    max_tokens: f64,
    refill_rate_ns: f64, // tokens per nanosecond
    last_refill: std.time.Instant,
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
    pub fn init(config: Config) error{TimerUnsupported}!?RateLimiter {
        if (config.qps <= 0.0 or config.burst == 0) return null;

        const now = std.time.Instant.now() catch return error.TimerUnsupported;
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
    pub fn acquire(self: *RateLimiter, ctx: Context) error{Canceled}!void {
        while (true) {
            try ctx.check();

            const sleep_ns = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();

                self.refill();

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
            try context_mod.interruptibleSleep(ctx, sleep_ns);
        }
    }

    /// Consume a token (allowing the balance to go negative / into debt)
    /// and return the wait duration in nanoseconds before the token is
    /// replenished. Returns 0 when a token is immediately available.
    ///
    /// Used by the overall rate limiter in WorkQueue to compute a global
    /// delay that is combined (via max) with per-key backoff.
    pub fn reserve(self: *RateLimiter) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.refill();

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
    pub fn tryAcquire(self: *RateLimiter) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.refill();

        if (self.tokens >= 1.0) {
            self.tokens -= 1.0;
            return true;
        }
        return false;
    }

    /// Refill tokens based on elapsed time. Must be called with mutex held.
    fn refill(self: *RateLimiter) void {
        const now = std.time.Instant.now() catch return;
        const elapsed_ns: f64 = @floatFromInt(now.since(self.last_refill));
        const new_tokens = elapsed_ns * self.refill_rate_ns;

        if (new_tokens > 0.0) {
            self.tokens = @min(self.tokens + new_tokens, self.max_tokens);
            self.last_refill = now;
        }
    }
};

test "init with defaults returns non-null" {
    // Act
    const limiter = try RateLimiter.init(.{});

    // Assert
    try testing.expect(limiter != null);
}

test "init with disabled config returns null" {
    // Act
    const limiter = try RateLimiter.init(RateLimiter.Config.disabled);

    // Assert
    try testing.expect(limiter == null);
}

test "init with zero qps returns null" {
    // Act
    const limiter = try RateLimiter.init(.{ .qps = 0.0, .burst = 10 });

    // Assert
    try testing.expect(limiter == null);
}

test "init with zero burst returns null" {
    // Act
    const limiter = try RateLimiter.init(.{ .qps = 5.0, .burst = 0 });

    // Assert
    try testing.expect(limiter == null);
}

test "init: starts with full bucket" {
    // Arrange
    var limiter = (try RateLimiter.init(.{ .qps = 10.0, .burst = 5 })).?;
    _ = &limiter;

    // Act / Assert
    try testing.expectEqual(@as(f64, 5.0), limiter.max_tokens);
    try testing.expect(limiter.tokens == limiter.max_tokens);
}

test "tryAcquire: consumes tokens" {
    // Arrange
    var limiter = (try RateLimiter.init(.{ .qps = 10.0, .burst = 3 })).?;

    // Act
    try testing.expect(limiter.tryAcquire());
    try testing.expect(limiter.tryAcquire());
    try testing.expect(limiter.tryAcquire());

    // Assert
    try testing.expect(!limiter.tryAcquire());
}

test "acquire: consumes token from full bucket" {
    // Arrange
    var limiter = (try RateLimiter.init(.{ .qps = 10.0, .burst = 5 })).?;

    // Act
    try limiter.acquire(Context.background());

    // Assert
    try testing.expect(limiter.tokens < limiter.max_tokens);
}

test "refill: tokens accumulate over time" {
    // Arrange
    var limiter = (try RateLimiter.init(.{ .qps = 1000.0, .burst = 5 })).?;

    // Act
    // Drain all tokens.
    for (0..5) |_| {
        try testing.expect(limiter.tryAcquire());
    }
    try testing.expect(!limiter.tryAcquire());

    // Assert
    std.Thread.sleep(10 * std.time.ns_per_ms);

    try testing.expect(limiter.tryAcquire());
}

test "acquire: returns Canceled when context is already canceled" {
    // Arrange
    var limiter = (try RateLimiter.init(.{ .qps = 10.0, .burst = 5 })).?;
    var cs = context_mod.CancelSource.init();
    cs.cancel();
    const ctx = cs.context();

    // Act / Assert
    try testing.expectError(error.Canceled, limiter.acquire(ctx));
}

test "acquire: returns Canceled when context is canceled while waiting" {
    // Arrange
    var limiter = (try RateLimiter.init(.{ .qps = 1.0, .burst = 1 })).?;
    try testing.expect(limiter.tryAcquire());
    try testing.expect(!limiter.tryAcquire());

    // Act
    var cs = context_mod.CancelSource.init();
    const ctx = cs.context();

    // Assert
    // Cancel from another thread after a short delay.
    const cancel_thread = try std.Thread.spawn(.{}, struct {
        fn run(cancel_source: *context_mod.CancelSource) void {
            std.Thread.sleep(50 * std.time.ns_per_ms);
            cancel_source.cancel();
        }
    }.run, .{&cs});

    try testing.expectError(error.Canceled, limiter.acquire(ctx));

    cancel_thread.join();
}

test "tryAcquire: concurrent access from multiple threads" {
    // Arrange
    var limiter = (try RateLimiter.init(.{ .qps = 1.0, .burst = 10 })).?;
    var success_count = std.atomic.Value(u32).init(0);

    // Act
    const Worker = struct {
        fn run(lim: *RateLimiter, counter: *std.atomic.Value(u32)) void {
            for (0..5) |_| {
                if (lim.tryAcquire()) {
                    _ = counter.fetchAdd(1, .monotonic);
                }
            }
        }
    };

    // Assert
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{ &limiter, &success_count });
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
    var limiter = (try RateLimiter.init(.{ .qps = 10.0, .burst = 5 })).?;

    // Act
    const delay = limiter.reserve();

    // Assert
    try testing.expectEqual(@as(u64, 0), delay);
    try testing.expect(limiter.tokens < limiter.max_tokens);
}

test "reserve: returns positive delay when exhausted" {
    // Arrange
    var limiter = (try RateLimiter.init(.{ .qps = 10.0, .burst = 2 })).?;

    // Act
    const d1 = limiter.reserve();
    const d2 = limiter.reserve();
    const d3 = limiter.reserve(); // bucket now empty, should return delay

    // Assert
    try testing.expectEqual(@as(u64, 0), d1);
    try testing.expectEqual(@as(u64, 0), d2);
    try testing.expect(d3 > 0);
}

test "reserve: debt accumulates across calls" {
    // Arrange
    var limiter = (try RateLimiter.init(.{ .qps = 10.0, .burst = 1 })).?;

    // Act
    _ = limiter.reserve(); // consumes the 1 available token
    const d1 = limiter.reserve(); // first debt call
    const d2 = limiter.reserve(); // second debt call, more debt

    // Assert
    try testing.expect(d1 > 0);
    try testing.expect(d2 > d1); // deeper debt means longer wait
}

test "reserve: debt repays over time" {
    // Arrange
    var limiter = (try RateLimiter.init(.{ .qps = 1000.0, .burst = 1 })).?;

    // Act
    _ = limiter.reserve(); // consume the one token
    const d1 = limiter.reserve(); // go into debt

    // Assert
    try testing.expect(d1 > 0);

    // Wait for refill to repay the debt.
    std.Thread.sleep(10 * std.time.ns_per_ms);

    // After waiting, a token should be available again.
    const d2 = limiter.reserve();
    try testing.expectEqual(@as(u64, 0), d2);
}
