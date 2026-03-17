const std = @import("std");
const testing = std.testing;
const http = std.http;
const kube_zig = @import("kube-zig");
const k8s = @import("k8s");

const MockTransport = kube_zig.MockTransport;
const Reflector = kube_zig.Reflector;
const ReflectorEvent = kube_zig.ReflectorEvent;
const Store = kube_zig.Store;
const CancelSource = kube_zig.CancelSource;

const Pod = k8s.CoreV1Pod;

// ============================================================================
// Test data
// ============================================================================

/// Pod list with one item (rv 100).
const pod_list_one =
    \\{"apiVersion":"v1","kind":"PodList","metadata":{"resourceVersion":"100"},"items":[{"metadata":{"name":"pod-1","namespace":"default","resourceVersion":"99"}}]}
;

/// Pod list with two items (rv 100).
const pod_list_two =
    \\{"apiVersion":"v1","kind":"PodList","metadata":{"resourceVersion":"100"},"items":[{"metadata":{"name":"pod-1","namespace":"default","resourceVersion":"99"}},{"metadata":{"name":"pod-2","namespace":"default","resourceVersion":"98"}}]}
;

/// Empty pod list (rv 200).
const pod_list_empty =
    \\{"apiVersion":"v1","kind":"PodList","metadata":{"resourceVersion":"200"},"items":[]}
;

/// 410 Gone status JSON (for list error responses).
const gone_json =
    \\{"kind":"Status","apiVersion":"v1","metadata":{},"status":"Failure","message":"Gone","reason":"Gone","code":410}
;

/// Watch stream with an in-stream 410 ERROR event.
const watch_410_error =
    \\{"type":"ERROR","object":{"kind":"Status","code":410,"message":"Gone","reason":"Gone"}}
    \\
;

/// Watch stream with an ADDED event followed by clean end.
const watch_added_then_end =
    \\{"type":"ADDED","object":{"metadata":{"name":"pod-1","namespace":"default","resourceVersion":"101"}}}
    \\
;

/// Watch stream with a BOOKMARK event.
const watch_bookmark =
    \\{"type":"BOOKMARK","object":{"metadata":{"resourceVersion":"150"}}}
    \\
;

/// Watch stream with partial/corrupt JSON (truncated).
const watch_partial_json =
    \\{"type":"ADDED","object":{"metadata":{"na
;

// ============================================================================
// Helpers
// ============================================================================

/// Free an init_page's items (arena + entry wrapper for each, then the slice)
/// and its owned rv_buf.
fn freeInitPage(allocator: std.mem.Allocator, page: ReflectorEvent(Pod).InitPage) void {
    for (page.items) |item| {
        item.arena.deinit();
        allocator.destroy(item.arena);
    }
    allocator.free(page.items);
    if (page.rv_buf) |buf| allocator.free(buf);
}

// ============================================================================
// watch 410 triggers re-list
// ============================================================================

test "watch 410 triggers re-list" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    // Act
    // 1st: initial list succeeds.
    mock.respondWith(.ok, pod_list_one);
    // 2nd: watch stream sends in-stream 410 ERROR.
    mock.respondWithStream(.ok, watch_410_error);
    // 3rd: re-list after 410.
    mock.respondWith(.ok, pod_list_one);

    // Assert
    var c = mock.client();
    defer c.deinit();

    var reflector = Reflector(Pod).init(testing.allocator, &c, c.context(), "default", .{});
    defer reflector.deinit();

    // Step 1: initial listing returns init_page.
    const ev1 = (try reflector.step()).?;
    try testing.expect(ev1 == .init_page);
    freeInitPage(testing.allocator, ev1.init_page);
    try testing.expect(reflector.state == .watching);

    // Step 2: watching opens stream, reads ERROR 410, returns .gone.
    const ev2 = (try reflector.step()).?;
    try testing.expect(ev2 == .gone);
    try testing.expect(reflector.state == .gone);

    // Step 3: gone resets rv to "" (quorum read), returns null.
    const ev3 = try reflector.step();
    try testing.expect(ev3 == null);
    try testing.expect(reflector.state == .initial);
    try testing.expectEqualStrings("", reflector.resource_version.?);

    // Step 4: initial listing again, re-list succeeds.
    const ev4 = (try reflector.step()).?;
    try testing.expect(ev4 == .init_page);
    freeInitPage(testing.allocator, ev4.init_page);
    try testing.expect(reflector.state == .watching);
}

// ============================================================================
// network disconnect reconnects with resourceVersion
// ============================================================================

test "network disconnect reconnects with resourceVersion" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    // Act
    // 1st: initial list (rv 100).
    mock.respondWith(.ok, pod_list_one);
    // 2nd: watch stream with ADDED event (rv 101), then clean end.
    mock.respondWithStream(.ok, watch_added_then_end);
    // 3rd: reconnected watch stream with another event.
    mock.respondWithStream(.ok, watch_added_then_end);

    // Assert
    var c = mock.client();
    defer c.deinit();

    var reflector = Reflector(Pod).init(testing.allocator, &c, c.context(), "default", .{});
    defer reflector.deinit();

    // Step 1: list.
    const ev1 = (try reflector.step()).?;
    try testing.expect(ev1 == .init_page);
    freeInitPage(testing.allocator, ev1.init_page);

    // Step 2: watch ADDED event (rv updated to 101).
    const ev2 = (try reflector.step()).?;
    try testing.expect(ev2 == .watch_event);
    ev2.watch_event.deinit();
    try testing.expectEqualStrings("101", reflector.resource_version.?);

    // Step 3: stream ends cleanly, returns watch_ended.
    const ev3 = (try reflector.step()).?;
    try testing.expect(ev3 == .watch_ended);

    // Step 4: watch_ended transitions back to watching (null step).
    const ev4 = try reflector.step();
    try testing.expect(ev4 == null);
    try testing.expect(reflector.state == .watching);

    // Step 5: new watch opens, reconnected with rv=101.
    const ev5 = (try reflector.step()).?;
    try testing.expect(ev5 == .watch_event);
    ev5.watch_event.deinit();

    // Verify: the reconnected watch request (3rd request, index 2) uses rv=101.
    const req = mock.getRequest(2).?;
    try testing.expect(std.mem.indexOf(u8, req.path, "resourceVersion=101") != null);
}

// ============================================================================
// bookmark updates resourceVersion
// ============================================================================

test "bookmark updates resourceVersion" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    // Act
    mock.respondWith(.ok, pod_list_one);
    mock.respondWithStream(.ok, watch_bookmark);

    // Assert
    var c = mock.client();
    defer c.deinit();

    var reflector = Reflector(Pod).init(testing.allocator, &c, c.context(), "default", .{});
    defer reflector.deinit();

    // Step 1: list (rv 100).
    const ev1 = (try reflector.step()).?;
    freeInitPage(testing.allocator, ev1.init_page);
    try testing.expectEqualStrings("100", reflector.resource_version.?);

    // Step 2: watch reads BOOKMARK rv=150. Returns null (internal-only step).
    const ev2 = try reflector.step();
    try testing.expect(ev2 == null);
    try testing.expectEqualStrings("150", reflector.resource_version.?);
}

// ============================================================================
// repeated failures use backoff
// ============================================================================

test "repeated failures use backoff" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    // Act
    // Don't enqueue any responses; every list attempt fails with HttpRequestFailed.

    // Assert
    var c = mock.client();
    defer c.deinit();

    var reflector = Reflector(Pod).init(testing.allocator, &c, c.context(), "default", .{});
    defer reflector.deinit();

    // Each step should return .transient_error with incrementing backoff.
    for (0..5) |i| {
        const ev = (try reflector.step()).?;
        try testing.expect(ev == .transient_error);
        try testing.expectEqual(@as(u32, @intCast(i + 1)), reflector.consecutive_errors);
        try testing.expectEqual(@as(u32, @intCast(i + 1)), reflector.backoff_attempt);
    }

    // Verify errors accumulated.
    try testing.expectEqual(@as(u32, 5), reflector.consecutive_errors);

    // Backoff should return non-zero sleep durations.
    const backoff_ns = reflector.retry_policy.sleepNs(reflector.backoff_attempt, null);
    try testing.expect(backoff_ns > 0);
}

// ============================================================================
// context cancellation stops reflector
// ============================================================================

test "context cancellation stops reflector" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    // Act
    var cs = CancelSource.init();
    cs.cancel();

    // Assert
    var c = mock.client();
    defer c.deinit();

    var reflector = Reflector(Pod).init(testing.allocator, &c, cs.context(), "default", .{});
    defer reflector.deinit();

    // step() should return error.Canceled immediately.
    try testing.expectError(error.Canceled, reflector.step());
}

// ============================================================================
// empty re-list after 410 clears cache
// ============================================================================

test "empty re-list after 410 clears cache" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    // Act
    // 1st: initial list with 2 pods.
    mock.respondWith(.ok, pod_list_two);
    // 2nd: watch stream sends 410 ERROR.
    mock.respondWithStream(.ok, watch_410_error);
    // 3rd: re-list returns empty list.
    mock.respondWith(.ok, pod_list_empty);

    // Assert
    var c = mock.client();
    defer c.deinit();

    var reflector = Reflector(Pod).init(testing.allocator, &c, c.context(), "default", .{});
    defer reflector.deinit();

    var store = Store(Pod).init(testing.allocator);
    defer store.deinit();

    // Step 1: list returns 2 items. Populate the store.
    const ev1 = (try reflector.step()).?;
    try testing.expect(ev1 == .init_page);
    const replace_result1 = try store.replace(ev1.init_page.items);
    replace_result1.release();
    testing.allocator.free(ev1.init_page.items);
    if (ev1.init_page.rv_buf) |buf| testing.allocator.free(buf);
    try testing.expectEqual(@as(u32, 2), store.len());

    // Step 2: watch returns 410 ERROR.
    const ev2 = (try reflector.step()).?;
    try testing.expect(ev2 == .gone);

    // Step 3: gone resets rv.
    _ = try reflector.step();

    // Step 4: re-list returns empty init_page.
    const ev4 = (try reflector.step()).?;
    try testing.expect(ev4 == .init_page);
    try testing.expect(ev4.init_page.is_last);
    try testing.expectEqual(@as(usize, 0), ev4.init_page.items.len);

    // Use replace to get the items that were deleted.
    const replace_result2 = try store.replace(ev4.init_page.items);
    testing.allocator.free(ev4.init_page.items);
    if (ev4.init_page.rv_buf) |buf| testing.allocator.free(buf);

    // Verify 2 items were removed.
    try testing.expectEqual(@as(usize, 2), replace_result2.entries.len);

    // Release removed entries.
    replace_result2.release();

    // Store should now be empty.
    try testing.expectEqual(@as(u32, 0), store.len());
}

// ============================================================================
// partial JSON line treated as disconnect
// ============================================================================

test "partial JSON line treated as disconnect" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    // Act
    mock.respondWith(.ok, pod_list_one);
    mock.respondWithStream(.ok, watch_partial_json);

    // Assert
    var c = mock.client();
    defer c.deinit();

    var reflector = Reflector(Pod).init(testing.allocator, &c, c.context(), "default", .{});
    defer reflector.deinit();

    // Step 1: list succeeds.
    const ev1 = (try reflector.step()).?;
    freeInitPage(testing.allocator, ev1.init_page);

    // Step 2: watch opens, reads partial JSON, results in transient error.
    const ev2 = (try reflector.step()).?;
    try testing.expect(ev2 == .transient_error);
    try testing.expectEqual(@as(u32, 1), reflector.consecutive_errors);
    // Watch stream should be closed (reflector will retry).
    try testing.expect(reflector.watch_stream == null);
}

// ============================================================================
// 410 on initial list retries without resourceVersion
// ============================================================================

test "410 on initial list retries without resourceVersion" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    // Act
    // 1st: initial list returns 410.
    mock.respondWith(.gone, gone_json);
    // 2nd: re-list succeeds.
    mock.respondWith(.ok, pod_list_one);

    // Assert
    var c = mock.client();
    defer c.deinit();

    var reflector = Reflector(Pod).init(testing.allocator, &c, c.context(), "default", .{});
    defer reflector.deinit();

    // Step 1: initial list returns 410 Gone.
    const ev1 = (try reflector.step()).?;
    try testing.expect(ev1 == .gone);
    try testing.expect(reflector.state == .gone);

    // Step 2: gone resets rv to "" (quorum read).
    const ev2 = try reflector.step();
    try testing.expect(ev2 == null);
    try testing.expectEqualStrings("", reflector.resource_version.?);

    // Step 3: re-list succeeds.
    const ev3 = (try reflector.step()).?;
    try testing.expect(ev3 == .init_page);
    try testing.expect(ev3.init_page.is_last);
    freeInitPage(testing.allocator, ev3.init_page);
    try testing.expect(reflector.state == .watching);

    // Verify: the re-list request (2nd request, index 1) used rv="" (empty)
    // rather than rv="0" which is used for the initial list.
    const req = mock.getRequest(1).?;
    // The path should contain resourceVersion= (empty value) indicating a
    // quorum read, not resourceVersion=0.
    try testing.expect(std.mem.indexOf(u8, req.path, "resourceVersion=0") == null);
}

// ============================================================================
// ReflectorState.isValidTransition allows valid transitions
// ============================================================================

test "isValidTransition allows all valid transitions" {
    // Arrange
    const State = kube_zig.ReflectorState;

    const valid_transitions = .{
        .{ State.initial, State.listing },
        .{ State.listing, State.watching },
        .{ State.listing, State.gone },
        .{ State.listing, State.failed },
        .{ State.watching, State.watch_ended },
        .{ State.watching, State.gone },
        .{ State.watching, State.failed },
        .{ State.watch_ended, State.watching },
        .{ State.gone, State.initial },
    };

    // Act / Assert
    inline for (valid_transitions) |pair| {
        try testing.expect(State.isValidTransition(pair[0], pair[1]));
    }
}

// ============================================================================
// ReflectorState.isValidTransition rejects invalid transitions
// ============================================================================

test "isValidTransition rejects invalid transitions" {
    // Arrange
    const State = kube_zig.ReflectorState;

    const invalid_transitions = .{
        .{ State.initial, State.watching },
        .{ State.initial, State.gone },
        .{ State.listing, State.initial },
        .{ State.watching, State.listing },
        .{ State.watch_ended, State.gone },
        .{ State.gone, State.watching },
        .{ State.failed, State.initial },
        .{ State.failed, State.watching },
    };

    // Act / Assert
    inline for (invalid_transitions) |pair| {
        try testing.expect(!State.isValidTransition(pair[0], pair[1]));
    }
}
