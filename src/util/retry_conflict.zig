//! Automatic retry logic for Kubernetes HTTP 409 Conflict errors.
//!
//! Wraps an action function with exponential backoff, retrying only on
//! `error.HttpConflict` up to a configurable maximum. Supports
//! cancellation via a `Context` so that long backoff sleeps can be
//! interrupted. Intended for update/patch loops where optimistic
//! concurrency conflicts are expected.

const std = @import("std");
const context_mod = @import("context.zig");
const Context = context_mod.Context;
const RetryPolicy = @import("retry.zig").RetryPolicy;
const testing = std.testing;

/// Default retry policy for conflict retries: 5 attempts, 10ms initial
/// backoff with doubling, 1s cap, and jitter enabled. Shorter than
/// HTTP-level retries since conflicts are expected to resolve quickly.
pub const default_conflict_policy: RetryPolicy = .{
    .max_retries = 5,
    .initial_backoff_ns = 10 * std.time.ns_per_ms, // 10ms
    .max_backoff_ns = 1 * std.time.ns_per_s, // 1s cap
    .backoff_multiplier = 2,
    .jitter = true,
};

/// Test helper: deterministic policy with minimal backoff.
const test_policy: RetryPolicy = .{
    .max_retries = 3,
    .initial_backoff_ns = 1,
    .max_backoff_ns = 10,
    .backoff_multiplier = 2,
    .jitter = false,
};

/// Retry `actionFn` on HTTP 409 Conflict errors with exponential backoff.
///
/// Parameters:
///   - `Ctx`: type of the context value forwarded to `actionFn`.
///   - `ctx`: context instance passed as the sole argument to `actionFn`.
///   - `actionFn`: comptime function `fn(Ctx) E!T` to execute on each attempt.
///   - `policy`: controls max retries, backoff timing, and jitter.
///   - `cancel_ctx`: cancellation context; when canceled, the next backoff
///     sleep returns `error.Canceled` immediately.
///
/// On each `error.HttpConflict` the function sleeps according to the
/// retry policy and tries again, up to `policy.max_retries` times. Any
/// other error, or retries exhausted, is returned immediately.
///
/// Works for both `E!void` and `E!T` return types. The action function
/// may use any error set (not restricted to `anyerror`).
pub fn retryOnConflict(
    io: std.Io,
    comptime Ctx: type,
    ctx: Ctx,
    comptime actionFn: anytype,
    policy: RetryPolicy,
    cancel_ctx: Context,
) @typeInfo(@TypeOf(actionFn)).@"fn".return_type.? {
    var attempt: u32 = 0;
    while (true) {
        return actionFn(ctx) catch |err| {
            if (err == error.HttpConflict and attempt < policy.max_retries) {
                const sleep_ns = policy.sleepNs(io, attempt, null);
                context_mod.interruptibleSleep(io, cancel_ctx, sleep_ns) catch return error.Canceled;
                attempt += 1;
                continue;
            }
            return err;
        };
    }
}

test "retryOnConflict: void action succeeds on first try" {
    // Arrange
    const Ctx = struct {
        calls: *u32,

        // Act
        fn action(self: @This()) anyerror!void {
            self.calls.* += 1;
        }
    };

    // Assert
    var calls: u32 = 0;

    try retryOnConflict(std.testing.io, Ctx, .{ .calls = &calls }, Ctx.action, test_policy, Context.background());

    try testing.expectEqual(@as(u32, 1), calls);
}

test "retryOnConflict: void action retries on HttpConflict then succeeds" {
    // Arrange
    const Ctx = struct {
        calls: *u32,

        // Act
        fn action(self: @This()) anyerror!void {
            self.calls.* += 1;
            if (self.calls.* < 3) return error.HttpConflict;
        }
    };

    // Assert
    var calls: u32 = 0;

    try retryOnConflict(std.testing.io, Ctx, .{ .calls = &calls }, Ctx.action, test_policy, Context.background());

    try testing.expectEqual(@as(u32, 3), calls);
}

test "retryOnConflict: void action exhausts retries" {
    // Arrange
    const Ctx = struct {
        calls: *u32,

        // Act
        fn action(self: @This()) anyerror!void {
            self.calls.* += 1;
            return error.HttpConflict;
        }
    };

    // Assert
    var calls: u32 = 0;

    const result = retryOnConflict(std.testing.io, Ctx, .{ .calls = &calls }, Ctx.action, test_policy, Context.background());
    try testing.expectError(error.HttpConflict, result);

    try testing.expectEqual(@as(u32, 4), calls);
}

test "retryOnConflict: success returns value" {
    // Arrange
    const Ctx = struct {
        calls: *u32,

        // Act
        fn action(self: @This()) anyerror!u32 {
            self.calls.* += 1;
            return 42;
        }
    };

    // Assert
    var calls: u32 = 0;

    const result = try retryOnConflict(std.testing.io, Ctx, .{ .calls = &calls }, Ctx.action, test_policy, Context.background());

    try testing.expectEqual(@as(u32, 42), result);
    try testing.expectEqual(@as(u32, 1), calls);
}

test "retryOnConflict: retries on HttpConflict then returns value" {
    // Arrange
    const Ctx = struct {
        calls: *u32,

        // Act
        fn action(self: @This()) anyerror!u32 {
            self.calls.* += 1;
            if (self.calls.* < 3) return error.HttpConflict;
            return self.calls.*;
        }
    };

    // Assert
    var calls: u32 = 0;

    const result = try retryOnConflict(std.testing.io, Ctx, .{ .calls = &calls }, Ctx.action, test_policy, Context.background());

    try testing.expectEqual(@as(u32, 3), result);
    try testing.expectEqual(@as(u32, 3), calls);
}

test "retryOnConflict: propagates non-conflict error" {
    // Arrange
    const Ctx = struct {
        calls: *u32,

        // Act
        fn action(self: @This()) anyerror!u32 {
            self.calls.* += 1;
            return error.HttpNotFound;
        }
    };

    // Assert
    var calls: u32 = 0;

    const result = retryOnConflict(std.testing.io, Ctx, .{ .calls = &calls }, Ctx.action, test_policy, Context.background());
    try testing.expectError(error.HttpNotFound, result);

    try testing.expectEqual(@as(u32, 1), calls);
}

test "default_conflict_policy has expected values" {
    // Act
    const policy = default_conflict_policy;

    // Assert
    try testing.expectEqual(@as(u32, 5), policy.max_retries);
    try testing.expectEqual(@as(u64, 10 * std.time.ns_per_ms), policy.initial_backoff_ns);
    try testing.expectEqual(@as(u64, 1 * std.time.ns_per_s), policy.max_backoff_ns);
    try testing.expectEqual(@as(u32, 2), policy.backoff_multiplier);
    try testing.expect(policy.jitter);
}

test "retryOnConflict: max_retries=0 does not retry" {
    // Arrange
    const Ctx = struct {
        calls: *u32,

        // Act
        fn action(self: @This()) anyerror!void {
            self.calls.* += 1;
            return error.HttpConflict;
        }
    };

    // Assert
    var calls: u32 = 0;
    const no_retry_policy: RetryPolicy = .{
        .max_retries = 0,
        .initial_backoff_ns = 1,
        .max_backoff_ns = 10,
        .backoff_multiplier = 2,
        .jitter = false,
    };

    const result = retryOnConflict(std.testing.io, Ctx, .{ .calls = &calls }, Ctx.action, no_retry_policy, Context.background());
    try testing.expectError(error.HttpConflict, result);

    try testing.expectEqual(@as(u32, 1), calls);
}

test "retryOnConflict: returns Canceled when context is already canceled" {
    // Arrange
    const Ctx = struct {
        calls: *u32,

        // Act
        fn action(self: @This()) anyerror!void {
            self.calls.* += 1;
            return error.HttpConflict;
        }
    };

    // Assert
    var calls: u32 = 0;
    var cs = context_mod.CancelSource.init();
    cs.cancel(std.testing.io);

    // returns Canceled immediately.
    const result = retryOnConflict(std.testing.io, Ctx, .{ .calls = &calls }, Ctx.action, test_policy, cs.context());
    try testing.expectError(error.Canceled, result);

    try testing.expectEqual(@as(u32, 1), calls);
}

test "retryOnConflict: returns Canceled when context is canceled while retrying" {
    // Arrange
    const Ctx = struct {
        calls: *u32,

        // Act
        fn action(self: @This()) anyerror!void {
            self.calls.* += 1;
            return error.HttpConflict;
        }
    };

    // Assert
    var calls: u32 = 0;
    var cs = context_mod.CancelSource.init();
    const long_backoff_policy: RetryPolicy = .{
        .max_retries = 5,
        .initial_backoff_ns = 10 * std.time.ns_per_s,
        .max_backoff_ns = 10 * std.time.ns_per_s,
        .backoff_multiplier = 1,
        .jitter = false,
    };

    // Cancel from another thread after a short delay.
    const cancel_thread = try std.Thread.spawn(.{}, struct {
        fn run(io: std.Io, cancel_source: *context_mod.CancelSource) void {
            std.Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .{ .nanoseconds = 50 * std.time.ns_per_ms } }, io) catch {};
            cancel_source.cancel(io);
        }
    }.run, .{ std.testing.io, &cs });

    const result = retryOnConflict(std.testing.io, Ctx, .{ .calls = &calls }, Ctx.action, long_backoff_policy, cs.context());
    try testing.expectError(error.Canceled, result);

    try testing.expectEqual(@as(u32, 1), calls);

    cancel_thread.join();
}
