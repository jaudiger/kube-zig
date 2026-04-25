//! Circuit breaker for fail-fast protection against unhealthy endpoints.
//!
//! Implements the standard three-state pattern (closed, open, half-open) to
//! prevent cascading failures when a downstream service is unresponsive.
//! Thread-safe via a mutex protecting all state transitions. Configurable
//! failure threshold and recovery timeout; can be disabled entirely.

const std = @import("std");
const logging_mod = @import("logging.zig");
const Logger = logging_mod.Logger;
const LogField = logging_mod.Field;
const testing = std.testing;

/// Circuit breaker for fail-fast protection against unhealthy servers.
///
/// Implements the standard three-state pattern:
///   Closed --[failure threshold]--> Open
///   Open --[recovery timeout]--> Half-Open
///   Half-Open --[probe succeeds]--> Closed
///   Half-Open --[probe fails]--> Open
///
/// Thread-safe: uses a mutex to protect state transitions.
pub const CircuitBreaker = struct {
    mutex: std.Io.Mutex = .init,
    state: std.atomic.Value(State) = std.atomic.Value(State).init(.closed),
    consecutive_failures: u32 = 0,
    last_failure_time: ?std.Io.Clock.Timestamp = null,
    half_open_sent: bool = false,
    config: Config,
    logger: Logger = Logger.noop,

    /// The three states of a circuit breaker.
    pub const State = enum(u8) {
        /// Normal operation: all requests are allowed through.
        closed,
        /// Failure threshold reached: all requests are rejected.
        open,
        /// Recovery probe: exactly one request is allowed to test the endpoint.
        half_open,
    };

    /// Configuration for the circuit breaker.
    pub const Config = struct {
        /// Number of consecutive failures before the circuit opens (default: 5).
        failure_threshold: u32 = 5,
        /// How long to stay open before transitioning to half-open (default: 30s).
        recovery_timeout_ns: u64 = 30 * std.time.ns_per_s,
        /// Structured logger. Default is no-op.
        logger: Logger = Logger.noop,

        /// A config that disables the circuit breaker entirely.
        pub const disabled: Config = .{ .failure_threshold = 0 };
    };

    /// Initialize a circuit breaker. Returns null if config disables it.
    pub fn init(config: Config) error{TimerUnsupported}!?CircuitBreaker {
        if (config.failure_threshold == 0) return null;

        // The monotonic clock is always supported in the Io-based runtime,
        // so there's nothing to probe here anymore. The error is retained
        // for ABI compatibility with callers.
        return .{ .config = config, .logger = config.logger.withScope("circuit_breaker") };
    }

    /// Check if a request is allowed. Returns error.CircuitBreakerOpen if the
    /// circuit is open. In half-open state, allows exactly one probe request.
    pub fn allowRequest(self: *CircuitBreaker, io: std.Io) error{CircuitBreakerOpen}!void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        switch (self.state.raw) {
            .closed => return,
            .open => {
                // Check if recovery timeout has elapsed.
                if (self.last_failure_time) |lft| {
                    const elapsed_ns: i96 = lft.untilNow(io).raw.nanoseconds;
                    const elapsed: u64 = if (elapsed_ns < 0) 0 else @intCast(elapsed_ns);
                    if (elapsed >= self.config.recovery_timeout_ns) {
                        self.state.store(.half_open, .release);
                        self.half_open_sent = true;
                        self.logger.info("circuit breaker half-open", &.{
                            LogField.uint("recovery_timeout_ms", self.config.recovery_timeout_ns / std.time.ns_per_ms),
                        });
                        return; // allow this one probe
                    }
                }
                self.logger.warn("request rejected by circuit breaker", &.{});
                return error.CircuitBreakerOpen;
            },
            .half_open => {
                // A probe is already in-flight; reject all other requests.
                self.logger.warn("request rejected by circuit breaker", &.{});
                return error.CircuitBreakerOpen;
            },
        }
    }

    /// Record a successful outcome. Resets failure count and closes the circuit.
    pub fn recordSuccess(self: *CircuitBreaker, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const prev = self.state.raw;
        self.consecutive_failures = 0;
        self.state.store(.closed, .release);
        self.half_open_sent = false;

        if (prev != .closed) {
            self.logger.info("circuit breaker closed", &.{});
        }
    }

    /// Record a failure. Increments consecutive failure count.
    /// Trips to open if threshold is reached.
    pub fn recordFailure(self: *CircuitBreaker, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        self.consecutive_failures +|= 1;
        self.last_failure_time = .now(io, .awake);

        switch (self.state.raw) {
            .closed => {
                if (self.consecutive_failures >= self.config.failure_threshold) {
                    self.state.store(.open, .release);
                    self.logger.warn("circuit breaker opened", &.{
                        LogField.uint("consecutive_failures", @intCast(self.consecutive_failures)),
                        LogField.uint("recovery_timeout_ms", self.config.recovery_timeout_ns / std.time.ns_per_ms),
                    });
                }
            },
            .half_open => {
                // Probe failed; back to open, restart recovery timeout.
                self.state.store(.open, .release);
                self.half_open_sent = false;
                self.logger.warn("circuit breaker opened", &.{
                    LogField.uint("consecutive_failures", @intCast(self.consecutive_failures)),
                    LogField.uint("recovery_timeout_ms", self.config.recovery_timeout_ns / std.time.ns_per_ms),
                });
            },
            .open => {
                // Already open; just update last_failure_time.
            },
        }
    }

    /// Returns the current state (for observability/logging).
    pub fn getState(self: *CircuitBreaker) State {
        return self.state.load(.acquire);
    }
};

test "init with defaults returns non-null" {
    // Act
    const cb = try CircuitBreaker.init(.{});

    // Assert
    try testing.expect(cb != null);
}

test "init with disabled config returns null" {
    // Act
    const cb = try CircuitBreaker.init(CircuitBreaker.Config.disabled);

    // Assert
    try testing.expect(cb == null);
}

test "init with zero failure_threshold returns null" {
    // Act
    const cb = try CircuitBreaker.init(.{ .failure_threshold = 0 });

    // Assert
    try testing.expect(cb == null);
}

test "closed state allows requests" {
    // Arrange
    var cb = (try CircuitBreaker.init(.{ .failure_threshold = 5 })).?;

    // Act / Assert
    try cb.allowRequest(std.testing.io);
    try testing.expectEqual(CircuitBreaker.State.closed, cb.getState());
}

test "failures below threshold keep circuit closed" {
    // Arrange
    var cb = (try CircuitBreaker.init(.{ .failure_threshold = 5 })).?;

    // Act
    for (0..4) |_| {
        cb.recordFailure(std.testing.io);
    }

    // Assert
    try testing.expectEqual(CircuitBreaker.State.closed, cb.getState());
    try cb.allowRequest(std.testing.io);
}

test "failures at threshold trip to open" {
    // Arrange
    var cb = (try CircuitBreaker.init(.{ .failure_threshold = 3 })).?;

    // Act
    cb.recordFailure(std.testing.io);
    cb.recordFailure(std.testing.io);
    cb.recordFailure(std.testing.io);

    // Assert
    try testing.expectEqual(CircuitBreaker.State.open, cb.getState());
}

test "open state rejects requests" {
    // Arrange
    var cb = (try CircuitBreaker.init(.{
        .failure_threshold = 2,
        .recovery_timeout_ns = 60 * std.time.ns_per_s,
    })).?;

    // Act
    cb.recordFailure(std.testing.io);
    cb.recordFailure(std.testing.io);

    // Assert
    try testing.expectEqual(CircuitBreaker.State.open, cb.getState());
    try testing.expectError(error.CircuitBreakerOpen, cb.allowRequest(std.testing.io));
}

test "recovery timeout transitions to half-open" {
    // Arrange
    var cb = (try CircuitBreaker.init(.{
        .failure_threshold = 2,
        .recovery_timeout_ns = 1 * std.time.ns_per_ms,
    })).?;

    // Act
    // Trip the circuit.
    cb.recordFailure(std.testing.io);
    cb.recordFailure(std.testing.io);
    try testing.expectEqual(CircuitBreaker.State.open, cb.getState());

    // Assert
    // Wait for recovery timeout.
    std.Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .{ .nanoseconds = 2 * std.time.ns_per_ms } }, std.testing.io) catch {};

    try cb.allowRequest(std.testing.io);

    try testing.expectEqual(CircuitBreaker.State.half_open, cb.getState());
}

test "half-open probe success closes circuit" {
    // Arrange
    var cb = (try CircuitBreaker.init(.{
        .failure_threshold = 2,
        .recovery_timeout_ns = 1 * std.time.ns_per_ms,
    })).?;

    // Act
    // Trip to open, wait for recovery, allow probe.
    cb.recordFailure(std.testing.io);
    cb.recordFailure(std.testing.io);
    std.Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .{ .nanoseconds = 2 * std.time.ns_per_ms } }, std.testing.io) catch {};
    try cb.allowRequest(std.testing.io);
    try testing.expectEqual(CircuitBreaker.State.half_open, cb.getState());

    // Assert
    cb.recordSuccess(std.testing.io);

    try testing.expectEqual(CircuitBreaker.State.closed, cb.getState());
    try cb.allowRequest(std.testing.io); // requests flow normally again
}

test "half-open probe failure re-opens circuit" {
    // Arrange
    var cb = (try CircuitBreaker.init(.{
        .failure_threshold = 2,
        .recovery_timeout_ns = 1 * std.time.ns_per_ms,
    })).?;

    // Act
    // Trip to open, wait for recovery, allow probe.
    cb.recordFailure(std.testing.io);
    cb.recordFailure(std.testing.io);
    std.Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .{ .nanoseconds = 2 * std.time.ns_per_ms } }, std.testing.io) catch {};
    try cb.allowRequest(std.testing.io);

    // Assert
    cb.recordFailure(std.testing.io);

    try testing.expectEqual(CircuitBreaker.State.open, cb.getState());
    try testing.expectError(error.CircuitBreakerOpen, cb.allowRequest(std.testing.io));
}

test "success resets consecutive failure count" {
    // Arrange
    var cb = (try CircuitBreaker.init(.{ .failure_threshold = 3 })).?;

    // Act
    // Accumulate some failures (but not enough to trip).
    cb.recordFailure(std.testing.io);
    cb.recordFailure(std.testing.io);

    // Assert
    cb.recordSuccess(std.testing.io);

    cb.recordFailure(std.testing.io);
    cb.recordFailure(std.testing.io);
    try testing.expectEqual(CircuitBreaker.State.closed, cb.getState());
    cb.recordFailure(std.testing.io);
    try testing.expectEqual(CircuitBreaker.State.open, cb.getState());
}

test "concurrent access is safe" {
    // Arrange
    var cb = (try CircuitBreaker.init(.{
        .failure_threshold = 100,
        .recovery_timeout_ns = 1 * std.time.ns_per_ms,
    })).?;

    // Act
    const Worker = struct {
        fn run(io: std.Io, circuit_breaker: *CircuitBreaker) void {
            for (0..50) |i| {
                _ = circuit_breaker.allowRequest(io) catch {};
                if (i % 3 == 0) {
                    circuit_breaker.recordFailure(io);
                } else {
                    circuit_breaker.recordSuccess(io);
                }
            }
        }
    };

    // Assert
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{ std.testing.io, &cb });
    }
    for (&threads) |t| {
        t.join();
    }

    _ = cb.getState();
}

test "half-open allows only one probe" {
    // Arrange
    var cb = (try CircuitBreaker.init(.{
        .failure_threshold = 2,
        .recovery_timeout_ns = 1 * std.time.ns_per_ms,
    })).?;

    // Act
    // Trip to open, wait for recovery.
    cb.recordFailure(std.testing.io);
    cb.recordFailure(std.testing.io);
    std.Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .{ .nanoseconds = 2 * std.time.ns_per_ms } }, std.testing.io) catch {};

    // Assert
    try cb.allowRequest(std.testing.io);
    try testing.expectEqual(CircuitBreaker.State.half_open, cb.getState());

    try testing.expectError(error.CircuitBreakerOpen, cb.allowRequest(std.testing.io));

    // Complete probe, then requests flow again.
    cb.recordSuccess(std.testing.io);
    try cb.allowRequest(std.testing.io);
}

test "consecutive_failures saturates instead of wrapping" {
    // Arrange
    var cb = (try CircuitBreaker.init(.{ .failure_threshold = 5 })).?;
    cb.consecutive_failures = std.math.maxInt(u32);

    // Act
    cb.recordFailure(std.testing.io);

    // Assert
    try testing.expectEqual(std.math.maxInt(u32), cb.consecutive_failures);
}

test "getState returns correct state after various transitions" {
    // Arrange
    var cb = (try CircuitBreaker.init(.{
        .failure_threshold = 2,
        .recovery_timeout_ns = 1 * std.time.ns_per_ms,
    })).?;

    // Act
    try testing.expectEqual(CircuitBreaker.State.closed, cb.getState());

    // Assert
    // Trip to open.
    cb.recordFailure(std.testing.io);
    cb.recordFailure(std.testing.io);
    try testing.expectEqual(CircuitBreaker.State.open, cb.getState());

    // Wait and transition to half-open.
    std.Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .{ .nanoseconds = 2 * std.time.ns_per_ms } }, std.testing.io) catch {};
    try cb.allowRequest(std.testing.io);
    try testing.expectEqual(CircuitBreaker.State.half_open, cb.getState());

    // Close on success.
    cb.recordSuccess(std.testing.io);
    try testing.expectEqual(CircuitBreaker.State.closed, cb.getState());
}
