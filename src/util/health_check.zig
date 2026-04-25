//! Type-erased health check callback for liveness and readiness probes.
//!
//! Provides a simple `HealthCheck` type that wraps a typed context pointer
//! and a check function behind a type-erased interface. This allows
//! subsystems to register health checks without exposing their concrete types.

const std = @import("std");
const testing = std.testing;

/// Type-erased health check callback.
///
/// Returns `true` for healthy, `false` for unhealthy.
pub const HealthCheck = struct {
    ctx: *anyopaque,
    check_fn: *const fn (ctx: *anyopaque, io: std.Io) bool,

    /// Create a health check from a typed context pointer and function.
    pub fn fromTypedCtx(
        comptime Ctx: type,
        ctx: *Ctx,
        comptime func: *const fn (c: *Ctx, io: std.Io) bool,
    ) HealthCheck {
        const Wrapper = struct {
            fn wrapped(raw: *anyopaque, io: std.Io) bool {
                const typed: *Ctx = @ptrCast(@alignCast(raw));
                return func(typed, io);
            }
        };
        return .{ .ctx = @ptrCast(ctx), .check_fn = Wrapper.wrapped };
    }
};

test "HealthCheck type-erasure: returns true" {
    // Arrange
    const Ctx = struct { val: bool };
    var ctx = Ctx{ .val = true };
    const check = HealthCheck.fromTypedCtx(Ctx, &ctx, struct {
        fn f(c: *Ctx, _: std.Io) bool {
            return c.val;
        }
    }.f);

    // Act / Assert
    try testing.expect(check.check_fn(check.ctx, std.testing.io));
}

test "HealthCheck type-erasure: returns false" {
    // Arrange
    const Ctx = struct { val: bool };
    var ctx = Ctx{ .val = false };
    const check = HealthCheck.fromTypedCtx(Ctx, &ctx, struct {
        fn f(c: *Ctx, _: std.Io) bool {
            return c.val;
        }
    }.f);

    // Act / Assert
    try testing.expect(!check.check_fn(check.ctx, std.testing.io));
}
