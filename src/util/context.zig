//! Cancellation and deadline propagation for concurrent operations.
//!
//! `Context` is a lightweight, pass-by-value token that carries a
//! cancellation signal and optional deadline. It is modelled after
//! Go's `context.Context` and is threaded through API calls, informers,
//! and reconcilers so that shutdown signals propagate cleanly.
//!
//! `CancelSource` owns the cancellation flag. Multiple sources can be
//! chained via `withCancel` to form a tree where cancelling any ancestor
//! cancels all descendants.

const std = @import("std");
const Futex = std.Thread.Futex;
const tracing = @import("tracing.zig");
pub const SpanContext = tracing.SpanContext;

/// Owns the cancellation flag. Call `cancel()` to propagate to all
/// contexts derived from this source.
///
/// When used with `Context.withCancel()`, the source's `parent` pointer
/// is set to form a linked list of ancestor sources. `isCanceled()`
/// walks this chain so that cancellation at any ancestor level is
/// observed, regardless of depth.
///
/// A given `CancelSource` should be passed to `withCancel()` at most
/// once; calling it again would overwrite the `parent` link.
pub const CancelSource = struct {
    done: std.atomic.Value(u32),
    parent: ?*const CancelSource = null,

    pub fn init() CancelSource {
        return .{ .done = std.atomic.Value(u32).init(0) };
    }

    /// Signal cancellation to all holders of a `Context` derived from
    /// this source.
    pub fn cancel(self: *CancelSource) void {
        self.done.store(1, .release);
        Futex.wake(&self.done, std.math.maxInt(u32));
    }

    /// Returns true if `cancel()` has been called on this source or
    /// any ancestor in the parent chain.
    pub fn isCanceled(self: *const CancelSource) bool {
        if (self.done.load(.acquire) != 0) return true;
        var ancestor = self.parent;
        while (ancestor) |cs| {
            if (cs.done.load(.acquire) != 0) return true;
            ancestor = cs.parent;
        }
        return false;
    }

    /// Obtain a `Context` backed by this source's cancellation flag.
    pub fn context(self: *const CancelSource) Context {
        return .{
            .cancel = self,
            .deadline_ns = null,
        };
    }
};

/// A lightweight, pass-by-value cancellation token and deadline carrier.
///
/// `Context` does not own any resources. It borrows a pointer to a
/// `CancelSource` whose parent chain encodes the full cancellation
/// ancestry. It is safe to copy and pass around freely.
pub const Context = struct {
    cancel: *const CancelSource,
    deadline_ns: ?i128 = null,
    span_context: ?SpanContext = null,

    /// A context that is never canceled and has no deadline.
    /// Uses a file-level static so the pointer remains valid for the
    /// lifetime of the program.
    pub fn background() Context {
        return .{
            .cancel = &background_source,
            .deadline_ns = null,
        };
    }

    /// Returns true if cancellation has been signaled (at any level in
    /// the ancestor chain) or the deadline has passed.
    pub fn isCanceled(self: Context) bool {
        if (self.cancel.isCanceled()) return true;
        if (self.deadline_ns) |dl| {
            return std.time.nanoTimestamp() >= dl;
        }
        return false;
    }

    /// Returns `error.Canceled` if the context is done, otherwise void.
    pub fn check(self: Context) error{Canceled}!void {
        if (self.isCanceled()) return error.Canceled;
    }

    /// Derive a child context with a tighter deadline.
    /// The effective deadline is `min(parent, absolute_deadline_ns)`.
    pub fn withDeadline(self: Context, absolute_deadline_ns: i128) Context {
        const effective = if (self.deadline_ns) |parent_dl|
            @min(parent_dl, absolute_deadline_ns)
        else
            absolute_deadline_ns;
        return .{
            .cancel = self.cancel,
            .deadline_ns = effective,
            .span_context = self.span_context,
        };
    }

    /// Derive a child context that expires `timeout_ns` nanoseconds from now.
    pub fn withTimeout(self: Context, timeout_ns: u64) Context {
        const now = std.time.nanoTimestamp();
        return self.withDeadline(now + @as(i128, timeout_ns));
    }

    /// Derive a child context carrying the given span context for trace propagation.
    pub fn withSpanContext(self: Context, sc: SpanContext) Context {
        return .{
            .cancel = self.cancel,
            .deadline_ns = self.deadline_ns,
            .span_context = sc,
        };
    }

    /// Derive a child context that links the given `CancelSource` into
    /// the cancellation chain. The child is canceled when either the
    /// new source or any ancestor source is canceled.
    ///
    /// This sets `child_cancel.parent` to the current context's source,
    /// forming a linked list that `isCanceled()` walks in full.
    pub fn withCancel(self: Context, child_cancel: *CancelSource) Context {
        child_cancel.parent = self.cancel;
        return .{
            .cancel = child_cancel,
            .deadline_ns = self.deadline_ns,
            .span_context = self.span_context,
        };
    }

    /// Returns the remaining time until the deadline in nanoseconds,
    /// or `null` if there is no deadline. Returns 0 if already expired.
    pub fn remainingNs(self: Context) ?i128 {
        const dl = self.deadline_ns orelse return null;
        const now = std.time.nanoTimestamp();
        const rem = dl - now;
        return if (rem < 0) 0 else rem;
    }
};

var background_source = CancelSource{ .done = std.atomic.Value(u32).init(0) };

/// Sleep for up to `ns` nanoseconds, waking early if `ctx` is canceled.
/// Returns `error.Canceled` if the context was canceled before the full
/// duration elapsed, otherwise returns void.
pub fn interruptibleSleep(ctx: Context, ns: u64) error{Canceled}!void {
    const start = std.time.Instant.now() catch return pollingSleep(ctx, ns);

    while (true) {
        try ctx.check();

        // Compute how many nanoseconds remain from the requested sleep.
        const elapsed = (std.time.Instant.now() catch return pollingSleep(ctx, ns)).since(start);
        if (elapsed >= ns) break;
        var wait_ns: u64 = ns - elapsed;

        // Clamp to deadline if present.
        if (ctx.deadline_ns) |dl| {
            const now = std.time.nanoTimestamp();
            if (now >= dl) return error.Canceled;
            const until_dl: u64 = std.math.cast(u64, dl - now) orelse 0;
            if (until_dl == 0) return error.Canceled;
            wait_ns = @min(wait_ns, until_dl);
        }

        // When ancestor cancel sources exist, we cannot futex-wait on
        // multiple addresses simultaneously, so cap individual waits at
        // 1 second and poll the ancestor chain between iterations.
        if (ctx.cancel.parent != null) {
            wait_ns = @min(wait_ns, 1 * std.time.ns_per_s);
        }

        Futex.timedWait(&ctx.cancel.done, 0, wait_ns) catch |err| switch (err) {
            error.Timeout => {},
        };

        // The futex woke: either the flag changed (cancel) or timeout elapsed.
        // Loop back to re-check cancellation and remaining time.
    }

    // Final check after full sleep.
    try ctx.check();
}

/// Fallback polling sleep for platforms where `Instant.now()` is unavailable.
fn pollingSleep(ctx: Context, ns: u64) error{Canceled}!void {
    const chunk: u64 = 100 * std.time.ns_per_ms;
    var remaining: u64 = ns;

    while (remaining > 0) {
        try ctx.check();

        if (ctx.deadline_ns) |dl| {
            const now = std.time.nanoTimestamp();
            if (now >= dl) return error.Canceled;
            const until_dl: u64 = std.math.cast(u64, @min(@as(i128, remaining), dl - now)) orelse 0;
            remaining = @min(remaining, until_dl);
            if (remaining == 0) return error.Canceled;
        }

        const sleep_for = @min(remaining, chunk);
        std.Thread.sleep(sleep_for);
        remaining -= sleep_for;
    }

    try ctx.check();
}

test "background context is never canceled" {
    // Act / Assert
    const ctx = Context.background();
    try std.testing.expect(!ctx.isCanceled());
    try ctx.check();
}

test "CancelSource: cancel propagates to context" {
    // Act / Assert
    var cs = CancelSource.init();
    const ctx = cs.context();
    try std.testing.expect(!ctx.isCanceled());
    cs.cancel();
    try std.testing.expect(ctx.isCanceled());
    try std.testing.expectError(error.Canceled, ctx.check());
}

test "withDeadline: child inherits tighter deadline" {
    // Act / Assert
    var cs = CancelSource.init();
    const parent = cs.context();
    const now = std.time.nanoTimestamp();
    const child = parent.withDeadline(now - 1); // already expired
    try std.testing.expect(child.isCanceled());
}

test "withDeadline: parent deadline wins when tighter" {
    // Act / Assert
    var cs = CancelSource.init();
    const now = std.time.nanoTimestamp();
    const parent = cs.context().withDeadline(now + 1_000_000); // 1 ms
    const child = parent.withDeadline(now + 1_000_000_000); // 1 s
    // Child should have the parent's deadline since it's tighter.
    try std.testing.expectEqual(parent.deadline_ns.?, child.deadline_ns.?);
}

test "withTimeout: creates deadline in the future" {
    // Act / Assert
    var cs = CancelSource.init();
    const ctx = cs.context().withTimeout(1_000_000_000); // 1 s
    try std.testing.expect(!ctx.isCanceled());
    try std.testing.expect(ctx.deadline_ns != null);
}

test "remainingNs: returns null when no deadline" {
    // Act / Assert
    const ctx = Context.background();
    try std.testing.expectEqual(null, ctx.remainingNs());
}

test "remainingNs: returns 0 for expired deadline" {
    // Act / Assert
    var cs = CancelSource.init();
    const now = std.time.nanoTimestamp();
    const ctx = cs.context().withDeadline(now - 1_000);
    const rem = ctx.remainingNs().?;
    try std.testing.expectEqual(@as(i128, 0), rem);
}

test "remainingNs: returns positive for future deadline" {
    // Act / Assert
    var cs = CancelSource.init();
    const ctx = cs.context().withTimeout(10 * std.time.ns_per_s);
    const rem = ctx.remainingNs().?;
    try std.testing.expect(rem > 0);
}

test "interruptibleSleep: returns immediately when already canceled" {
    // Act / Assert
    var cs = CancelSource.init();
    cs.cancel();
    const ctx = cs.context();
    try std.testing.expectError(error.Canceled, interruptibleSleep(ctx, 10 * std.time.ns_per_s));
}

test "interruptibleSleep: completes full sleep when not canceled" {
    // Act / Assert
    var cs = CancelSource.init();
    const ctx = cs.context();
    // Sleep for a very short duration.
    try interruptibleSleep(ctx, 1 * std.time.ns_per_ms);
}

test "interruptibleSleep: deadline causes early return" {
    // Act / Assert
    var cs = CancelSource.init();
    const ctx = cs.context().withTimeout(1 * std.time.ns_per_ms);
    const result = interruptibleSleep(ctx, 10 * std.time.ns_per_s);
    try std.testing.expectError(error.Canceled, result);
}

test "CancelSource: multiple contexts share cancellation" {
    // Act / Assert
    var cs = CancelSource.init();
    const ctx1 = cs.context();
    const ctx2 = cs.context();
    const ctx3 = ctx1.withTimeout(60 * std.time.ns_per_s);
    try std.testing.expect(!ctx1.isCanceled());
    try std.testing.expect(!ctx2.isCanceled());
    try std.testing.expect(!ctx3.isCanceled());
    cs.cancel();
    try std.testing.expect(ctx1.isCanceled());
    try std.testing.expect(ctx2.isCanceled());
    try std.testing.expect(ctx3.isCanceled());
}

test "withSpanContext: carries span context" {
    // Arrange
    const ctx = Context.background();
    try std.testing.expect(ctx.span_context == null);

    // Act / Assert
    const sc = SpanContext{
        .trace_id = tracing.TraceId.generate(),
        .span_id = tracing.SpanId.generate(),
        .trace_flags = SpanContext.sampled_flag,
    };
    const child = ctx.withSpanContext(sc);
    try std.testing.expect(child.span_context != null);
    try std.testing.expect(child.span_context.?.isValid());
}

test "withDeadline preserves span context" {
    // Act / Assert
    var cs = CancelSource.init();
    const sc = SpanContext{
        .trace_id = tracing.TraceId.generate(),
        .span_id = tracing.SpanId.generate(),
        .trace_flags = 0,
    };
    const ctx = cs.context().withSpanContext(sc);
    const now = std.time.nanoTimestamp();
    const child = ctx.withDeadline(now + 1_000_000_000);
    try std.testing.expect(child.span_context != null);
    try std.testing.expectEqualSlices(u8, &sc.trace_id.bytes, &child.span_context.?.trace_id.bytes);
}

test "withCancel: child cancel propagates" {
    // Arrange
    var parent_cs = CancelSource.init();
    var child_cs = CancelSource.init();
    const merged = parent_cs.context().withCancel(&child_cs);

    // Act
    child_cs.cancel();

    // Assert
    try std.testing.expect(merged.isCanceled());
    try std.testing.expectError(error.Canceled, merged.check());
}

test "withCancel: parent cancel propagates" {
    // Arrange
    var parent_cs = CancelSource.init();
    var child_cs = CancelSource.init();
    const merged = parent_cs.context().withCancel(&child_cs);

    // Act
    parent_cs.cancel();

    // Assert
    try std.testing.expect(merged.isCanceled());
    try std.testing.expectError(error.Canceled, merged.check());
}

test "withCancel: not canceled when neither source canceled" {
    // Arrange
    var parent_cs = CancelSource.init();
    var child_cs = CancelSource.init();

    // Act
    const merged = parent_cs.context().withCancel(&child_cs);

    // Assert
    try std.testing.expect(!merged.isCanceled());
    try merged.check();
}

test "withCancel: propagates through withDeadline" {
    // Arrange
    var parent_cs = CancelSource.init();
    var child_cs = CancelSource.init();
    const merged = parent_cs.context().withCancel(&child_cs);
    const now = std.time.nanoTimestamp();
    const with_dl = merged.withDeadline(now + 10 * std.time.ns_per_s);

    // Act
    parent_cs.cancel();

    // Assert
    try std.testing.expect(with_dl.isCanceled());
}

test "withCancel: propagates through withSpanContext" {
    // Arrange
    var parent_cs = CancelSource.init();
    var child_cs = CancelSource.init();
    const merged = parent_cs.context().withCancel(&child_cs);
    const sc = SpanContext{
        .trace_id = tracing.TraceId.generate(),
        .span_id = tracing.SpanId.generate(),
        .trace_flags = SpanContext.sampled_flag,
    };
    const with_sc = merged.withSpanContext(sc);

    // Act
    child_cs.cancel();

    // Assert
    try std.testing.expect(with_sc.isCanceled());
}

test "withCancel: interruptibleSleep respects child cancel" {
    // Arrange
    var parent_cs = CancelSource.init();
    var child_cs = CancelSource.init();
    child_cs.cancel();
    const merged = parent_cs.context().withCancel(&child_cs);

    // Act / Assert
    try std.testing.expectError(error.Canceled, interruptibleSleep(merged, 10 * std.time.ns_per_s));
}

test "withCancel: interruptibleSleep respects parent cancel" {
    // Arrange
    var parent_cs = CancelSource.init();
    var child_cs = CancelSource.init();
    parent_cs.cancel();
    const merged = parent_cs.context().withCancel(&child_cs);

    // Act / Assert
    try std.testing.expectError(error.Canceled, interruptibleSleep(merged, 10 * std.time.ns_per_s));
}

test "interruptibleSleep: cancel wakes futex immediately" {
    // Arrange
    var cs = CancelSource.init();
    const ctx = cs.context();

    const CancelThread = struct {
        fn run(source: *CancelSource) void {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            source.cancel();
        }
    };
    const thread = try std.Thread.spawn(.{}, CancelThread.run, .{&cs});

    // Act
    const start = try std.time.Instant.now();
    const result = interruptibleSleep(ctx, 60 * std.time.ns_per_s);
    const elapsed = (try std.time.Instant.now()).since(start);

    // Assert
    try std.testing.expectError(error.Canceled, result);
    try std.testing.expect(elapsed < 500 * std.time.ns_per_ms);

    thread.join();
}

test "withCancel: grandparent cancel propagates through chain" {
    // Arrange
    var grandparent_cs = CancelSource.init();
    var parent_cs = CancelSource.init();
    var child_cs = CancelSource.init();
    const level1 = grandparent_cs.context().withCancel(&parent_cs);
    const level2 = level1.withCancel(&child_cs);

    // Act
    grandparent_cs.cancel();

    // Assert
    try std.testing.expect(level2.isCanceled());
    try std.testing.expectError(error.Canceled, level2.check());
}

test "withCancel: mid-chain cancel propagates to leaf" {
    // Arrange
    var root_cs = CancelSource.init();
    var mid_cs = CancelSource.init();
    var leaf_cs = CancelSource.init();
    const mid_ctx = root_cs.context().withCancel(&mid_cs);
    const leaf_ctx = mid_ctx.withCancel(&leaf_cs);

    // Act
    mid_cs.cancel();

    // Assert
    try std.testing.expect(leaf_ctx.isCanceled());
    try std.testing.expect(!root_cs.context().isCanceled());
}

test "withCancel: leaf cancel does not affect ancestors" {
    // Arrange
    var root_cs = CancelSource.init();
    var mid_cs = CancelSource.init();
    var leaf_cs = CancelSource.init();
    const mid_ctx = root_cs.context().withCancel(&mid_cs);
    _ = mid_ctx.withCancel(&leaf_cs);

    // Act
    leaf_cs.cancel();

    // Assert
    try std.testing.expect(!root_cs.isCanceled());
    try std.testing.expect(!mid_cs.isCanceled());
}

test "withCancel: depth-4 chain propagates from root" {
    // Arrange
    var cs0 = CancelSource.init();
    var cs1 = CancelSource.init();
    var cs2 = CancelSource.init();
    var cs3 = CancelSource.init();
    const ctx1 = cs0.context().withCancel(&cs1);
    const ctx2 = ctx1.withCancel(&cs2);
    const ctx3 = ctx2.withCancel(&cs3);

    // Act
    cs0.cancel();

    // Assert
    try std.testing.expect(ctx3.isCanceled());
}
