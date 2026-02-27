//! Fire-and-forget Kubernetes Event recorder.
//!
//! Wraps `Api(CoreV1Event).create()` to emit core/v1 Event objects. Errors
//! during event creation are logged and silently discarded so that events
//! never block a controller's reconcile loop. Event names are deterministic
//! hashes of the involved object reference and reason string.

const std = @import("std");
const client_mod = @import("../client/Client.zig");
const Client = client_mod.Client;
const Context = client_mod.Context;
const Api_mod = @import("../api/Api.zig");
const logging_mod = @import("../util/logging.zig");
const LogField = logging_mod.Field;
const time_mod = @import("../util/time.zig");
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

/// Fire-and-forget Kubernetes Event recorder.
///
/// Creates core/v1 Event objects via `Api(CoreV1Event).create()`.
/// Errors are silently discarded so events never block the controller's
/// reconcile loop.
///
/// Thread-safe by immutability: all fields are set at init and never mutated.
///
/// ```zig
/// const recorder = EventRecorder.init(&client, "my-controller", "my-controller-pod-abc");
/// recorder.event(
///     .{ .apiVersion = "v1", .kind = "Pod", .name = "my-pod", .namespace = "default", .uid = "abc-123" },
///     "default",
///     .normal,
///     "SuccessfulCreate",
///     "Created pod my-pod",
/// );
/// ```
pub const EventRecorder = struct {
    client: *Client,
    /// Source component name (appears in `source.component` and `reportingComponent`).
    component: []const u8,
    /// Reporting instance identity (e.g. pod name, appears in `reportingInstance`).
    instance: []const u8,

    /// Create an EventRecorder. No allocations; all fields are borrowed.
    pub fn init(client: *Client, component: []const u8, instance: []const u8) EventRecorder {
        return .{
            .client = client,
            .component = component,
            .instance = instance,
        };
    }

    /// Record a Kubernetes Event (fire-and-forget).
    ///
    /// `ref` identifies the involved object. `namespace` is the namespace
    /// in which to create the Event. When `null`, the namespace is derived
    /// from `ref.namespace`, falling back to `"default"`.
    /// Errors are silently discarded.
    pub fn event(
        self: EventRecorder,
        ref: CoreV1ObjectReference,
        namespace: ?[]const u8,
        event_type: EventType,
        reason: []const u8,
        message: []const u8,
    ) void {
        self.client.logger.debug("recording event", &.{
            LogField.string("kind", ref.kind orelse ""),
            LogField.string("namespace", ref.namespace orelse ""),
            LogField.string("name", ref.name orelse ""),
            LogField.string("reason", reason),
        });
        self.eventInner(ref, namespace, event_type, reason, message) catch |err| {
            self.client.logger.warn("event creation failed", &.{
                LogField.string("error", @errorName(err)),
            });
        };
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

    fn eventInner(
        self: EventRecorder,
        ref: CoreV1ObjectReference,
        namespace: ?[]const u8,
        event_type: EventType,
        reason: []const u8,
        message: []const u8,
    ) !void {
        const CoreV1Event = types.CoreV1Event;
        const EventApi = Api_mod.Api(CoreV1Event);

        const effective_ns = resolveNamespace(namespace, ref);

        var ts_buf: [27]u8 = undefined;
        const now_str = time_mod.bufNow(.micros, &ts_buf);

        var name_buf: [253]u8 = undefined;
        const event_name = generateEventName(&name_buf, ref, reason);

        const ev = CoreV1Event{
            .apiVersion = "v1",
            .kind = "Event",
            .metadata = .{
                .name = event_name,
                .namespace = effective_ns,
            },
            .involvedObject = ref,
            .reason = reason,
            .message = message,
            .type = event_type.toValue(),
            .firstTimestamp = now_str,
            .lastTimestamp = now_str,
            .count = 1,
            .source = .{ .component = self.component },
            .reportingComponent = self.component,
            .reportingInstance = self.instance,
        };

        const api = EventApi.init(self.client, self.client.context(), effective_ns);
        const result = try api.create(ev, .{});
        switch (result) {
            .ok => |parsed| parsed.deinit(),
            .api_error => |err_resp| err_resp.deinit(),
        }
    }
};

const CoreV1ObjectReference = types.CoreV1ObjectReference;

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
