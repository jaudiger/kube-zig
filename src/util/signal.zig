//! OS signal handling for graceful shutdown.
//!
//! Captures SIGTERM and SIGINT and provides mechanisms to block until
//! a signal is received, enabling clean shutdown of Kubernetes controllers.
//!
//! Signal handlers are process-global in POSIX, so only one `SignalHandler`
//! should be active per process.
//!
//! Usage:
//! ```zig
//! const signal = @import("kube-zig").signal;
//!
//! var handler = try signal.SignalHandler.init();
//! // ... start controllers ...
//! _ = handler.wait(); // blocks until SIGTERM/SIGINT
//! // ... call shutdown/stop ...
//! ```

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

/// Returns true if the current platform supports POSIX signals.
fn isPosixSupported() bool {
    return switch (builtin.os.tag) {
        .linux, .macos => true,
        else => false,
    };
}

/// Process-global flag set by the signal handler.
var signal_received = std.atomic.Value(u32).init(0);
/// The signal number that was received.
var received_signal = std.atomic.Value(i32).init(0);

/// Registers OS signal handlers for graceful shutdown.
///
/// Captures SIGTERM and SIGINT and provides a `wait()` method that blocks
/// until one of these signals is received.
///
/// Signal handlers are process-global in POSIX. Only one `SignalHandler`
/// should be active per process. Creating multiple instances is safe but
/// they all share the same underlying atomic flags.
pub const SignalHandler = struct {
    /// Register signal handlers for SIGTERM and SIGINT.
    ///
    /// Returns `error.UnsupportedPlatform` on platforms without POSIX signal support.
    pub fn init() error{UnsupportedPlatform}!SignalHandler {
        if (comptime !isPosixSupported()) return error.UnsupportedPlatform;

        const sa = std.posix.Sigaction{
            .handler = .{ .handler = signalHandler },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.TERM, &sa, null);
        std.posix.sigaction(std.posix.SIG.INT, &sa, null);
        return .{};
    }

    /// Block until SIGTERM or SIGINT is received.
    /// Returns the signal number that was received.
    pub fn wait(self: SignalHandler) i32 {
        _ = self;
        while (signal_received.load(.acquire) == 0) {
            std.Thread.Futex.wait(&signal_received, 0);
        }
        return received_signal.load(.acquire);
    }

    /// Returns true if a signal has been received.
    pub fn isSignaled(self: SignalHandler) bool {
        _ = self;
        return signal_received.load(.acquire) != 0;
    }

    /// Returns the signal number that was received, or null if none.
    pub fn getSignal(self: SignalHandler) ?i32 {
        _ = self;
        if (!signal_received.load(.acquire)) return null;
        return received_signal.load(.acquire);
    }

    /// Reset the signal state. Primarily useful for tests.
    pub fn reset(self: SignalHandler) void {
        _ = self;
        signal_received.store(0, .release);
        received_signal.store(0, .release);
    }
};

/// Signal handler function. Must be async-signal-safe: only atomic stores
/// and futex wake.
fn signalHandler(sig: c_int) callconv(.c) void {
    received_signal.store(sig, .release);
    signal_received.store(1, .release);
    std.Thread.Futex.wake(&signal_received, std.math.maxInt(u32));
}

/// Type-erased callback invoked when a signal is received.
pub const ShutdownCallback = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque) void,

    /// Create a callback from a typed pointer and function.
    pub fn fromTypedCtx(comptime Ctx: type, ctx: *Ctx, comptime func: *const fn (c: *Ctx) void) ShutdownCallback {
        const Wrapper = struct {
            fn wrapped(raw: *anyopaque) void {
                const typed: *Ctx = @ptrCast(@alignCast(raw));
                func(typed);
            }
        };
        return .{ .ctx = @ptrCast(ctx), .func = Wrapper.wrapped };
    }
};

/// Handle returned by `setupShutdown`. Holds the signal handler and
/// the background thread that waits for signals.
pub const ShutdownHandle = struct {
    handler: SignalHandler,
    thread: std.Thread,
};

/// Register signal handlers and spawn a background thread that waits for
/// SIGTERM/SIGINT, then invokes all provided callbacks in order.
///
/// Returns a `ShutdownHandle` whose `thread` field should be joined during
/// cleanup.
///
/// Usage:
/// ```zig
/// const handle = try signal.setupShutdown(&.{
///     signal.ShutdownCallback.fromTypedCtx(
///         Client, &client, Client.shutdown,
///     ),
/// });
/// // ... run application ...
/// handle.thread.join();
/// ```
pub fn setupShutdown(callbacks: []const ShutdownCallback) !ShutdownHandle {
    const handler = try SignalHandler.init();
    const thread = try std.Thread.spawn(.{}, shutdownThreadFn, .{callbacks});
    return .{ .handler = handler, .thread = thread };
}

fn shutdownThreadFn(callbacks: []const ShutdownCallback) void {
    const handler = SignalHandler{};
    _ = handler.wait();
    for (callbacks) |cb| {
        cb.func(cb.ctx);
    }
}

test "SignalHandler: init and reset" {
    // Arrange
    if (comptime !isPosixSupported()) return error.SkipZigTest;

    // Act
    var handler = try SignalHandler.init();

    // Assert
    try testing.expect(!handler.isSignaled());
    try testing.expect(handler.getSignal() == null);

    // Reset should work even when no signal received.
    handler.reset();

    try testing.expect(!handler.isSignaled());
}

test "SignalHandler: manual flag set simulates signal" {
    // Arrange
    if (comptime !isPosixSupported()) return error.SkipZigTest;

    // Act
    var handler = try SignalHandler.init();
    defer handler.reset();

    // Assert
    // Directly set the atomic to simulate signal receipt.
    signal_received.store(1, .release);
    received_signal.store(std.posix.SIG.TERM, .release);

    try testing.expect(handler.isSignaled());
    try testing.expectEqual(@as(i32, std.posix.SIG.TERM), handler.getSignal().?);
}

test "ShutdownCallback: fromTypedCtx calls function" {
    // Arrange
    const Context = struct {
        called: bool = false,
        fn shutdown(self: *@This()) void {
            self.called = true;
        }
    };
    var ctx = Context{};
    const cb = ShutdownCallback.fromTypedCtx(Context, &ctx, Context.shutdown);

    // Act
    cb.func(cb.ctx);

    // Assert
    try testing.expect(ctx.called);
}

test "ShutdownCallback: multiple callbacks" {
    // Arrange
    const Counter = struct {
        count: u32 = 0,
        fn increment(self: *@This()) void {
            self.count += 1;
        }
    };
    var c1 = Counter{};
    var c2 = Counter{};
    const callbacks = [_]ShutdownCallback{
        ShutdownCallback.fromTypedCtx(Counter, &c1, Counter.increment),
        ShutdownCallback.fromTypedCtx(Counter, &c2, Counter.increment),
    };

    // Act
    for (&callbacks) |cb| {
        cb.func(cb.ctx);
    }

    // Assert
    try testing.expectEqual(@as(u32, 1), c1.count);
    try testing.expectEqual(@as(u32, 1), c2.count);
}
