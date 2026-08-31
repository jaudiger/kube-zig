//! Asynchronous Kubernetes Event recorder.
//!
//! Wraps `Api(CoreV1Event).create()` to emit core/v1 Event objects from a
//! dedicated background task so that callers are never blocked by slow
//! apiserver responses. Events are enqueued via `event()`, which is
//! non-blocking and returns immediately. The task drains the queue and issues
//! the HTTP POST. Errors during event creation are logged and silently
//! discarded.
//!
//! Lifecycle: `init` -> `start` -> `event` (any number of times) ->
//! `shutdown` or `cancel` -> `join` -> `deinit`. `shutdown` drains queued
//! events, while `cancel` aborts delivery and drops queued events. The recorder
//! can be registered with a `ControllerManager` via `runnable()`.
//!
//! Event names are deterministic hashes of the involved object reference and
//! reason string, so repeated events for the same object/reason produce the
//! same Kubernetes Event name and can be counted by the apiserver.

const std = @import("std");
const client_mod = @import("../client/Client.zig");
const Client = client_mod.Client;
const Api_mod = @import("../api/Api.zig");
const manager_mod = @import("../controller/manager.zig");
const Runnable = manager_mod.Runnable;
const RunError = manager_mod.RunError;
const logging_mod = @import("../util/logging.zig");
const Logger = logging_mod.Logger;
const LogField = logging_mod.Field;
const time_mod = @import("../util/time.zig");
const RingQueue = @import("../util/ring_queue.zig").RingQueue;
const types = @import("types");
const testing = std.testing;

/// Kubernetes event type (matches core/v1 Event `.type` field).
pub const EventType = enum {
    normal,
    warning,

    /// Return the Kubernetes API string representation.
    pub fn toValue(self: EventType) []const u8 {
        return switch (self) {
            .normal => "Normal",
            .warning => "Warning",
        };
    }
};

/// A single event pending delivery to the apiserver.
///
/// All string fields are owned by the arena; deinit frees everything at once.
const QueuedEvent = struct {
    arena: std.heap.ArenaAllocator,
    ref: CoreV1ObjectReference,
    namespace: ?[]const u8,
    event_type: EventType,
    reason: []const u8,
    message: []const u8,
    /// RFC 3339 timestamp captured at the moment event() was called.
    timestamp: []const u8,

    fn deinit(self: *QueuedEvent) void {
        self.arena.deinit();
    }
};

/// Asynchronous Kubernetes Event recorder backed by an owned IO task.
///
/// `event()` is non-blocking: it deep-copies the arguments into a per-record
/// arena, enqueues the record, and returns. A background task drains the queue
/// and issues the HTTP POST. On overflow the event is dropped and a warning is
/// logged; the caller is never stalled.
///
/// Enqueueing is thread-safe. Lifecycle methods must not be called after
/// `deinit()`.
pub const EventRecorder = struct {
    allocator: std.mem.Allocator,
    client: *Client,
    /// Source component name (appears in `source.component` and `reportingComponent`).
    component: []const u8,
    /// Reporting instance identity (appears in `reportingInstance`).
    instance: []const u8,
    logger: Logger,

    mutex: std.Io.Mutex,
    /// Wakeup epoch: producers bump this and wake the task.
    cond_epoch: std.atomic.Value(u32),
    state: std.atomic.Value(State),
    cancel_source: client_mod.CancelSource,
    dispatch_ctx: ?client_mod.Context,

    queue: RingQueue(QueuedEvent),
    worker_task: ?std.Io.Future(std.Io.Cancelable!void),
    join_mutex: std.Io.Mutex,

    /// Events dropped due to queue overflow, OOM, or forced cancellation.
    dropped_total: std.atomic.Value(u64),

    pub const State = enum(u8) { idle, running, stopping, canceling, stopped };

    pub const Options = struct {
        /// Maximum number of events that can be queued at once.
        /// Events beyond this limit are dropped with a warning log.
        max_queue_size: usize = 1024,
        logger: Logger = Logger.noop,
    };

    /// Create a recorder in `idle` state. No task is spawned.
    pub fn init(
        allocator: std.mem.Allocator,
        client: *Client,
        component: []const u8,
        instance: []const u8,
        opts: Options,
    ) EventRecorder {
        return .{
            .allocator = allocator,
            .client = client,
            .component = component,
            .instance = instance,
            .logger = opts.logger.withScope("event_recorder"),
            .mutex = .init,
            .cond_epoch = std.atomic.Value(u32).init(0),
            .state = std.atomic.Value(State).init(.idle),
            .cancel_source = .init(),
            .dispatch_ctx = null,
            .queue = .{ .max_capacity = opts.max_queue_size },
            .worker_task = null,
            .join_mutex = .init,
            .dropped_total = std.atomic.Value(u64).init(0),
        };
    }

    /// Release owned memory. The recorder must have been joined.
    pub fn deinit(self: *EventRecorder, io: std.Io) void {
        std.debug.assert(self.state.load(.acquire) == .idle or self.state.load(.acquire) == .stopped);
        std.debug.assert(self.worker_task == null);
        self.cancel_source.deinit(io);
        while (self.queue.pop()) |item| {
            var mutable = item;
            mutable.deinit();
        }
        self.queue.deinit(self.allocator);
    }

    /// Spawn the background task. Transitions from `idle` to `running`.
    pub fn start(self: *EventRecorder, io: std.Io) RunError!void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        std.debug.assert(self.state.load(.acquire) == .idle);
        self.dispatch_ctx = self.client.context().withCancel(io, &self.cancel_source);
        self.state.store(.running, .release);
        self.worker_task = io.concurrent(run, .{ self, io }) catch |err| {
            self.dispatch_ctx = null;
            self.cancel_source.deinit(io);
            self.state.store(.idle, .release);
            return err;
        };
    }

    /// Request graceful shutdown without waiting. Queued events are drained.
    pub fn shutdown(self: *EventRecorder, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        switch (self.state.load(.acquire)) {
            .idle => self.state.store(.stopped, .release),
            .running => self.state.store(.stopping, .release),
            .stopping, .canceling, .stopped => return,
        }
        self.wake(io);
    }

    /// Request immediate cancellation without waiting. `join()` applies the
    /// task cancellation and drops undelivered events.
    pub fn cancel(self: *EventRecorder, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        switch (self.state.load(.acquire)) {
            .idle => self.state.store(.stopped, .release),
            .running, .stopping => self.state.store(.canceling, .release),
            .canceling, .stopped => return,
        }
        self.wake(io);
    }

    /// Wait for the background task to exit.
    pub fn join(self: *EventRecorder, io: std.Io) void {
        self.join_mutex.lockUncancelable(io);
        defer self.join_mutex.unlock(io);

        if (self.worker_task) |*task| {
            if (self.state.load(.acquire) == .canceling) {
                task.cancel(io) catch {};
            } else {
                task.await(io) catch {};
            }
            self.mutex.lockUncancelable(io);
            self.worker_task = null;
            self.dispatch_ctx = null;
            self.state.store(.stopped, .release);
            self.mutex.unlock(io);
        }
    }

    /// Gracefully shut down and wait for the task to finish.
    pub fn stop(self: *EventRecorder, io: std.Io) void {
        self.shutdown(io);
        self.join(io);
    }

    /// Return a `Runnable` that plugs this recorder into a `ControllerManager`.
    pub fn runnable(self: *EventRecorder) Runnable {
        return Runnable.fromTyped(EventRecorder, self);
    }

    /// Enqueue a Kubernetes Event (non-blocking, fire-and-forget).
    ///
    /// Deep-copies all string arguments into a per-record arena and pushes
    /// the record onto the internal queue. Returns immediately. Drops the
    /// event (with a warning log) if the queue is full, OOM occurs, or the
    /// recorder has been shut down.
    pub fn event(
        self: *EventRecorder,
        io: std.Io,
        ref: CoreV1ObjectReference,
        namespace: ?[]const u8,
        event_type: EventType,
        reason: []const u8,
        message: []const u8,
    ) void {
        self.logger.debug("recording event", &.{
            LogField.string("kind", ref.kind orelse ""),
            LogField.string("namespace", ref.namespace orelse ""),
            LogField.string("name", ref.name orelse ""),
            LogField.string("reason", reason),
        });

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        const a = arena.allocator();

        // Deep-copy all borrowed slices into the arena.
        const ref_copy = dupeRef(a, ref) catch {
            arena.deinit();
            self.recordDrop("OOM copying ref");
            return;
        };
        const ns_copy: ?[]const u8 = if (namespace) |ns| a.dupe(u8, ns) catch {
            arena.deinit();
            self.recordDrop("OOM copying namespace");
            return;
        } else null;
        const reason_copy = a.dupe(u8, reason) catch {
            arena.deinit();
            self.recordDrop("OOM copying reason");
            return;
        };
        const message_copy = a.dupe(u8, message) catch {
            arena.deinit();
            self.recordDrop("OOM copying message");
            return;
        };
        var ts_buf: [time_mod.Precision.micros.bufLen()]u8 = undefined;
        const ts_slice = time_mod.bufNow(io, .micros, &ts_buf);
        const ts_copy = a.dupe(u8, ts_slice) catch {
            arena.deinit();
            self.recordDrop("OOM copying timestamp");
            return;
        };

        const record = QueuedEvent{
            .arena = arena,
            .ref = ref_copy,
            .namespace = ns_copy,
            .event_type = event_type,
            .reason = reason_copy,
            .message = message_copy,
            .timestamp = ts_copy,
        };

        self.pushRecord(io, record);
    }

    fn pushRecord(self: *EventRecorder, io: std.Io, record: QueuedEvent) void {
        const ok: bool = blk: {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            if (self.state.load(.acquire) != .running) {
                self.recordDrop("recorder shut down");
                break :blk false;
            }
            self.queue.push(self.allocator, record) catch {
                self.recordDrop("queue full");
                break :blk false;
            };
            break :blk true;
        };
        if (ok) {
            self.wake(io);
        } else {
            var mutable = record;
            mutable.deinit();
        }
    }

    fn recordDrop(self: *EventRecorder, reason: []const u8) void {
        _ = self.dropped_total.fetchAdd(1, .monotonic);
        self.logger.warn("event dropped", &.{LogField.string("reason", reason)});
    }

    fn wake(self: *EventRecorder, io: std.Io) void {
        _ = self.cond_epoch.fetchAdd(1, .release);
        io.futexWake(u32, &self.cond_epoch.raw, std.math.maxInt(u32));
    }

    fn run(self: *EventRecorder, io: std.Io) std.Io.Cancelable!void {
        defer {
            self.state.store(.stopped, .release);
            self.discardQueued(io);
        }

        while (true) {
            self.mutex.lockUncancelable(io);
            while (self.queue.count == 0 and self.state.load(.acquire) == .running) {
                const observed = self.cond_epoch.load(.acquire);
                self.mutex.unlock(io);
                io.futexWait(u32, &self.cond_epoch.raw, observed) catch |err| return err;
                self.mutex.lockUncancelable(io);
            }

            const state = self.state.load(.acquire);
            if (state == .canceling or (state == .stopping and self.queue.count == 0)) {
                self.mutex.unlock(io);
                return;
            }

            const item = self.queue.pop() orelse {
                self.mutex.unlock(io);
                continue;
            };
            self.mutex.unlock(io);

            var mutable = item;
            defer mutable.deinit();
            self.dispatch(io, mutable) catch |err| {
                if (err == error.Canceled) {
                    self.recordDrop("recorder canceled");
                    return err;
                }
                self.logger.warn("event creation failed", &.{
                    LogField.string("error", @errorName(err)),
                });
            };
        }
    }

    fn discardQueued(self: *EventRecorder, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        var dropped: u64 = 0;
        while (self.queue.pop()) |item| {
            var mutable = item;
            mutable.deinit();
            dropped += 1;
        }
        if (dropped > 0) {
            _ = self.dropped_total.fetchAdd(dropped, .monotonic);
            self.logger.warn("events dropped on task shutdown", &.{
                LogField.uint("count", dropped),
            });
        }
    }

    fn dispatch(self: *EventRecorder, io: std.Io, item: QueuedEvent) std.Io.Cancelable!void {
        const CoreV1Event = types.CoreV1Event;
        const EventApi = Api_mod.Api(CoreV1Event);

        const effective_ns = resolveNamespace(item.namespace, item.ref);

        var name_buf: [253]u8 = undefined;
        const event_name = generateEventName(&name_buf, item.ref, item.reason);

        const ev = CoreV1Event{
            .apiVersion = "v1",
            .kind = "Event",
            .metadata = .{
                .name = event_name,
                .namespace = effective_ns,
            },
            .involvedObject = item.ref,
            .reason = item.reason,
            .message = item.message,
            .type = item.event_type.toValue(),
            .firstTimestamp = item.timestamp,
            .lastTimestamp = item.timestamp,
            .count = 1,
            .source = .{ .component = self.component },
            .reportingComponent = self.component,
            .reportingInstance = self.instance,
        };

        const api = EventApi.init(self.client, self.dispatch_ctx.?, effective_ns);
        const result = api.create(io, ev, .{}) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            self.logger.warn("event creation failed", &.{
                LogField.string("error", @errorName(err)),
            });
            return;
        };

        var unwrapped = result.unwrap();
        switch (unwrapped) {
            .ok => |parsed| parsed.deinit(),
            .failure => |*f| {
                defer f.deinit();
                const status_msg = if (f.statusObj()) |s| (s.message orelse "") else "";
                self.logger.warn("event creation api error", &.{
                    LogField.string("status", @tagName(f.status)),
                    LogField.string("message", status_msg),
                });
            },
        }
    }

    /// Resolve the effective namespace for the Event object.
    /// Priority: explicit namespace > ref.namespace > "default".
    fn resolveNamespace(namespace: ?[]const u8, ref: CoreV1ObjectReference) []const u8 {
        if (namespace) |ns| {
            if (ns.len > 0) return ns;
        }
        if (ref.namespace) |ns| {
            if (ns.len > 0) return ns;
        }
        return "default";
    }
};

const CoreV1ObjectReference = types.CoreV1ObjectReference;

fn dupeOptStr(allocator: std.mem.Allocator, s: ?[]const u8) error{OutOfMemory}!?[]const u8 {
    const v = s orelse return null;
    return try allocator.dupe(u8, v);
}

fn dupeRef(allocator: std.mem.Allocator, ref: CoreV1ObjectReference) error{OutOfMemory}!CoreV1ObjectReference {
    return .{
        .apiVersion = try dupeOptStr(allocator, ref.apiVersion),
        .fieldPath = try dupeOptStr(allocator, ref.fieldPath),
        .kind = try dupeOptStr(allocator, ref.kind),
        .name = try dupeOptStr(allocator, ref.name),
        .namespace = try dupeOptStr(allocator, ref.namespace),
        .resourceVersion = try dupeOptStr(allocator, ref.resourceVersion),
        .uid = try dupeOptStr(allocator, ref.uid),
    };
}

/// Generate a deterministic event name: `{obj_name}.{8_hex_digits}`.
///
/// The hex suffix is a Wyhash of the object reference fields and reason,
/// ensuring different events for the same object get distinct names.
/// Object name is truncated to 244 chars (253 max - 1 dot - 8 hex).
pub fn generateEventName(buf: *[253]u8, ref: CoreV1ObjectReference, reason: []const u8) []const u8 {
    const obj_name = ref.name orelse "unknown";
    const max_prefix = 244;
    const prefix_len = @min(obj_name.len, max_prefix);

    var h = std.hash.Wyhash.init(0);
    h.update(obj_name);
    h.update(&[_]u8{0xff});
    h.update(ref.namespace orelse "");
    h.update(&[_]u8{0xff});
    h.update(ref.uid orelse "");
    h.update(&[_]u8{0xff});
    h.update(ref.apiVersion orelse "");
    h.update(&[_]u8{0xff});
    h.update(ref.kind orelse "");
    h.update(&[_]u8{0xff});
    h.update(reason);
    const hash_val = h.final();

    @memcpy(buf[0..prefix_len], obj_name[0..prefix_len]);
    buf[prefix_len] = '.';

    const hex_chars = "0123456789abcdef";
    inline for (0..8) |i| {
        const shift: u6 = @intCast((7 - i) * 4);
        const nibble: u4 = @truncate(hash_val >> shift);
        buf[prefix_len + 1 + i] = hex_chars[nibble];
    }

    return buf[0 .. prefix_len + 1 + 8];
}

test "EventType.toValue: normal" {
    // Act / Assert
    try testing.expectEqualStrings("Normal", EventType.normal.toValue());
}

test "EventType.toValue: warning" {
    // Act / Assert
    try testing.expectEqualStrings("Warning", EventType.warning.toValue());
}

test "generateEventName: produces name with hash suffix" {
    // Arrange
    const ref = CoreV1ObjectReference{
        .apiVersion = "v1",
        .kind = "Pod",
        .name = "my-pod",
        .namespace = "default",
        .uid = "abc-123",
    };
    var buf: [253]u8 = undefined;

    // Act
    const name = generateEventName(&buf, ref, "SuccessfulCreate");

    // Assert
    // Format: "my-pod." + 8 hex chars = 15 chars
    try testing.expectEqual(15, name.len);
    try testing.expectEqualStrings("my-pod.", name[0..7]);

    // Verify hex suffix contains only valid hex chars
    for (name[7..]) |c| {
        try testing.expect(std.ascii.isHex(c));
    }
}

test "generateEventName: different reasons produce different names" {
    // Arrange
    const ref = CoreV1ObjectReference{
        .apiVersion = "v1",
        .kind = "Pod",
        .name = "my-pod",
        .namespace = "default",
        .uid = "abc-123",
    };
    var buf1: [253]u8 = undefined;
    var buf2: [253]u8 = undefined;

    // Act
    const name1 = generateEventName(&buf1, ref, "Created");
    const name2 = generateEventName(&buf2, ref, "Deleted");

    // Assert
    // Same prefix, different hash suffix
    try testing.expectEqualStrings("my-pod.", name1[0..7]);
    try testing.expectEqualStrings("my-pod.", name2[0..7]);
    try testing.expect(!std.mem.eql(u8, name1, name2));
}

test "generateEventName: handles null fields" {
    // Arrange
    const ref = CoreV1ObjectReference{};
    var buf: [253]u8 = undefined;

    // Act
    const name = generateEventName(&buf, ref, "SomeReason");

    // Assert
    // Should use "unknown" as prefix: "unknown." + 8 hex = 16 chars
    try testing.expectEqual(16, name.len);
    try testing.expectEqualStrings("unknown.", name[0..8]);

    for (name[8..]) |c| {
        try testing.expect(std.ascii.isHex(c));
    }
}

test "generateEventName: truncates names longer than 244 chars" {
    // Arrange
    const long_name = "a" ** 300; // 300 chars
    const ref = CoreV1ObjectReference{
        .name = long_name,
        .namespace = "default",
    };
    var buf: [253]u8 = undefined;

    // Act
    const name = generateEventName(&buf, ref, "Created");

    // Assert
    try testing.expectEqual(253, name.len);
    try testing.expectEqual('.', name[244]);
    // Verify hex suffix
    for (name[245..]) |c| {
        try testing.expect(std.ascii.isHex(c));
    }
}

test "EventRecorder: overflow drops events and increments counter" {
    // Arrange
    const io = std.testing.io;
    const mock_mod = @import("../client/mock.zig");
    var mock = mock_mod.MockTransport.init(testing.allocator);
    defer mock.deinit();

    var client = try mock.client(io);
    defer client.deinit(io);

    const ref = CoreV1ObjectReference{
        .apiVersion = "v1",
        .kind = "Pod",
        .name = "my-pod",
        .namespace = "default",
        .uid = "abc-123",
    };

    var recorder = EventRecorder.init(testing.allocator, &client, "test", "test-pod", .{
        .max_queue_size = 2,
    });
    defer recorder.deinit(io);

    // Act
    for (0..5) |_| {
        recorder.event(io, ref, null, .normal, "TestReason", "test message");
    }

    // Assert: at least 3 of the 5 events were dropped.
    try testing.expect(recorder.dropped_total.load(.acquire) >= 3);
}

test "EventRecorder: end-to-end via mock transport" {
    // Arrange
    const io = std.testing.io;
    const mock_mod = @import("../client/mock.zig");
    var mock = mock_mod.MockTransport.init(testing.allocator);
    defer mock.deinit();

    try mock.respondWith(.created, "{\"apiVersion\":\"v1\",\"kind\":\"Event\",\"metadata\":{\"name\":\"my-pod.00000000\",\"namespace\":\"default\"}}");

    var client = try mock.client(io);
    defer client.deinit(io);

    const ref = CoreV1ObjectReference{
        .apiVersion = "v1",
        .kind = "Pod",
        .name = "my-pod",
        .namespace = "default",
        .uid = "abc-123",
    };

    var recorder = EventRecorder.init(testing.allocator, &client, "ctrl", "ctrl-pod-1", .{});
    defer recorder.deinit(io);

    // Act
    try recorder.start(io);
    recorder.event(io, ref, null, .normal, "Created", "created pod");

    std.Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .{ .nanoseconds = 50 * std.time.ns_per_ms } }, io) catch {};
    recorder.stop(io);

    // Assert: exactly one POST to the events endpoint was issued.
    try testing.expectEqual(1, mock.requests.items.len);
    try testing.expectEqual(std.http.Method.POST, mock.requests.items[0].method);
    try testing.expect(std.mem.startsWith(u8, mock.requests.items[0].path, "/api/v1/namespaces/default/events"));
    try testing.expectEqual(0, recorder.dropped_total.load(.acquire));
}
