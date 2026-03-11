const std = @import("std");
const testing = std.testing;
const http = std.http;
const kube_zig = @import("kube-zig");
const k8s = @import("k8s");

const MockTransport = kube_zig.MockTransport;
const Client = kube_zig.Client;
const Api = kube_zig.Api;
const WatchStream = kube_zig.WatchStream;
const DynamicApi = kube_zig.DynamicApi;
const DiscoveryClient = kube_zig.DiscoveryClient;

// ============================================================================
// Test helpers
// ============================================================================

/// Minimal pod JSON for list responses.
const pod_list_json =
    \\{"apiVersion":"v1","kind":"PodList","metadata":{"resourceVersion":"100"},"items":[{"metadata":{"name":"test-pod","namespace":"default","resourceVersion":"99"}}]}
;

/// Minimal pod JSON for get/create responses.
const pod_json =
    \\{"metadata":{"name":"test-pod","namespace":"default","resourceVersion":"99"}}
;

/// Minimal deployment JSON for create/update responses.
const deployment_json =
    \\{"metadata":{"name":"test-deploy","namespace":"default","resourceVersion":"50"}}
;

/// 404 Not Found JSON error response.
const not_found_json =
    \\{"kind":"Status","apiVersion":"v1","metadata":{},"status":"Failure","message":"pods \"missing\" not found","reason":"NotFound","code":404}
;

// ============================================================================
// Basic CRUD through Api(T)
// ============================================================================

test "Api(CoreV1Pod).list: parses pod list from mock response" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    // Act
    mock.respondWith(.ok, pod_list_json);

    // Assert
    var c = mock.client();
    defer c.deinit();

    const pods = Api(k8s.CoreV1Pod).init(&c, c.context(), "default");

    const result = try (try pods.list(.{})).value();
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.value.items.len);
    try testing.expectEqualStrings("test-pod", result.value.items[0].metadata.?.name.?);
}

test "Api(CoreV1Pod).get: parses single pod from mock response" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    // Act
    mock.respondWith(.ok, pod_json);

    // Assert
    var c = mock.client();
    defer c.deinit();

    const pods = Api(k8s.CoreV1Pod).init(&c, c.context(), "default");

    const result = try (try pods.get("test-pod")).value();
    defer result.deinit();

    try testing.expectEqualStrings("test-pod", result.value.metadata.?.name.?);
    try testing.expectEqualStrings("default", result.value.metadata.?.namespace.?);
}

test "Api(CoreV1Pod).create: sends POST with serialized body" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    // Act
    mock.respondWith(.created, pod_json);

    // Assert
    var c = mock.client();
    defer c.deinit();

    const pods = Api(k8s.CoreV1Pod).init(&c, c.context(), "default");
    const pod = k8s.CoreV1Pod{
        .metadata = .{ .name = "test-pod", .namespace = "default" },
    };

    const result = try (try pods.create(pod, .{})).value();
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), mock.requestCount());
    const req = mock.getRequest(0).?;
    try testing.expectEqual(http.Method.POST, req.method);
    try testing.expect(req.had_body_serializer);
    // The serialized body should contain the pod name.
    try testing.expect(req.serialized_body != null);
    try testing.expect(std.mem.indexOf(u8, req.serialized_body.?, "test-pod") != null);
}

test "Api(CoreV1Pod).delete: sends DELETE to correct path" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    // Act
    mock.respondWith(.ok, "{}");

    // Assert
    var c = mock.client();
    defer c.deinit();

    const pods = Api(k8s.CoreV1Pod).init(&c, c.context(), "default");

    const result = try pods.delete("test-pod", .{});
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), mock.requestCount());
    const req = mock.getRequest(0).?;
    try testing.expectEqual(http.Method.DELETE, req.method);
    try testing.expect(std.mem.indexOf(u8, req.path, "/namespaces/default/pods/test-pod") != null);
}

test "Api(AppsV1Deployment).create: sends to correct named-group path" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    // Act
    mock.respondWith(.created, deployment_json);

    // Assert
    var c = mock.client();
    defer c.deinit();

    const deploys = Api(k8s.AppsV1Deployment).init(&c, c.context(), "default");
    const deploy = k8s.AppsV1Deployment{
        .metadata = .{ .name = "test-deploy", .namespace = "default" },
    };

    const result = try (try deploys.create(deploy, .{})).value();
    defer result.deinit();

    const req = mock.getRequest(0).?;
    try testing.expect(std.mem.indexOf(u8, req.path, "/apis/apps/v1/namespaces/default/deployments") != null);
}

test "Api(CoreV1Node).get: cluster-scoped path has no namespace" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    // Act
    mock.respondWith(.ok,
        \\{"metadata":{"name":"node-1","resourceVersion":"10"}}
    );

    // Assert
    var c = mock.client();
    defer c.deinit();

    const nodes = Api(k8s.CoreV1Node).init(&c, c.context(), null);

    const result = try (try nodes.get("node-1")).value();
    defer result.deinit();

    const req = mock.getRequest(0).?;
    try testing.expect(std.mem.indexOf(u8, req.path, "/api/v1/nodes/node-1") != null);
    // Should NOT contain "namespaces"
    try testing.expect(std.mem.indexOf(u8, req.path, "namespaces") == null);
}

// ============================================================================
// Error handling
// ============================================================================

test "Api(CoreV1Pod).get: 404 response returns api_error with HttpNotFound" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    // Act
    mock.respondWith(.not_found, not_found_json);

    // Assert
    var c = mock.client();
    defer c.deinit();

    const pods = Api(k8s.CoreV1Pod).init(&c, c.context(), "default");

    const result = try pods.get("missing");

    switch (result) {
        .ok => try testing.expect(false), // should not be ok
        .api_error => |e| {
            defer e.deinit();
            try testing.expectEqual(http.Status.not_found, e.status);
            try testing.expectEqual(error.HttpNotFound, e.statusError());
        },
    }
}

test "Api(CoreV1Pod).get: transport error propagates" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    // Act
    // Don't enqueue any response; the mock will return HttpRequestFailed.

    // Assert
    var c = mock.client();
    defer c.deinit();

    const pods = Api(k8s.CoreV1Pod).init(&c, c.context(), "default");

    try testing.expectError(error.HttpRequestFailed, pods.get("test-pod"));
}

// ============================================================================
// Watch stream
// ============================================================================

test "WatchStream: parses ADDED/MODIFIED/DELETED events from mock stream" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    // Act
    const stream_body =
        \\{"type":"ADDED","object":{"metadata":{"name":"pod-1","namespace":"default","resourceVersion":"1"}}}
        \\{"type":"MODIFIED","object":{"metadata":{"name":"pod-1","namespace":"default","resourceVersion":"2"}}}
        \\{"type":"DELETED","object":{"metadata":{"name":"pod-1","namespace":"default","resourceVersion":"3"}}}
        \\
    ;

    // Assert
    mock.respondWithStream(.ok, stream_body);

    var c = mock.client();
    defer c.deinit();

    const pods = Api(k8s.CoreV1Pod).init(&c, c.context(), "default");

    var stream = try pods.watch(.{});
    defer stream.close();

    const ev1 = (try stream.next()).?;
    defer ev1.deinit();
    try testing.expect(ev1.event == .added);
    try testing.expectEqualStrings("pod-1", ev1.event.added.metadata.?.name.?);

    const ev2 = (try stream.next()).?;
    defer ev2.deinit();
    try testing.expect(ev2.event == .modified);
    try testing.expectEqualStrings("2", ev2.event.modified.metadata.?.resourceVersion.?);

    const ev3 = (try stream.next()).?;
    defer ev3.deinit();
    try testing.expect(ev3.event == .deleted);

    try testing.expect(try stream.next() == null);
}

test "WatchStream: resourceVersion is tracked" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    // Act
    const stream_body =
        \\{"type":"ADDED","object":{"metadata":{"name":"pod-1","namespace":"default","resourceVersion":"42"}}}
        \\
    ;
    // Note: the trailing `\\` produces a final newline, giving: {...}\n

    // Assert
    mock.respondWithStream(.ok, stream_body);

    var c = mock.client();
    defer c.deinit();

    const pods = Api(k8s.CoreV1Pod).init(&c, c.context(), "default");

    var stream = try pods.watch(.{});
    defer stream.close();

    const ev = (try stream.next()).?;
    defer ev.deinit();

    try testing.expectEqualStrings("42", stream.resourceVersion().?);
}

// ============================================================================
// Request inspection
// ============================================================================

test "Api(CoreV1Pod).list: label selector is included in request path" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    // Act
    mock.respondWith(.ok, pod_list_json);

    // Assert
    var c = mock.client();
    defer c.deinit();

    const pods = Api(k8s.CoreV1Pod).init(&c, c.context(), "default");

    const result = try (try pods.list(.{ .label_selector = "app=nginx" })).value();
    defer result.deinit();

    const req = mock.getRequest(0).?;
    try testing.expect(std.mem.indexOf(u8, req.path, "labelSelector=app") != null);
}

test "Api(CoreV1Pod).update: sends PUT with body serializer" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    // Act
    mock.respondWith(.ok, pod_json);

    // Assert
    var c = mock.client();
    defer c.deinit();

    const pods = Api(k8s.CoreV1Pod).init(&c, c.context(), "default");
    const pod = k8s.CoreV1Pod{
        .metadata = .{ .name = "test-pod", .namespace = "default", .resourceVersion = "99" },
    };

    const result = try (try pods.update("test-pod", pod, .{})).value();
    defer result.deinit();

    const req = mock.getRequest(0).?;
    try testing.expectEqual(http.Method.PUT, req.method);
    try testing.expect(req.had_body_serializer);
    try testing.expect(std.mem.indexOf(u8, req.path, "/namespaces/default/pods/test-pod") != null);
}

test "Multiple requests are recorded in order" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    // Act
    mock.respondWith(.ok, pod_list_json);
    mock.respondWith(.ok, pod_json);
    mock.respondWith(.ok, "{}");

    // Assert
    var c = mock.client();
    defer c.deinit();

    const pods = Api(k8s.CoreV1Pod).init(&c, c.context(), "default");

    const list_result = try (try pods.list(.{})).value();
    defer list_result.deinit();

    const get_result = try (try pods.get("test-pod")).value();
    defer get_result.deinit();

    const del_result = try pods.delete("test-pod", .{});
    defer del_result.deinit();

    try testing.expectEqual(@as(usize, 3), mock.requestCount());
    try testing.expectEqual(http.Method.GET, mock.getRequest(0).?.method);
    try testing.expectEqual(http.Method.GET, mock.getRequest(1).?.method);
    try testing.expectEqual(http.Method.DELETE, mock.getRequest(2).?.method);
}

// ============================================================================
// WatchStream: next/close/resourceVersion behavior
// ============================================================================

test "WatchStream: next returns null on empty stream" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    mock.respondWithStream(.ok, "");

    var c = mock.client();
    defer c.deinit();

    const pods = Api(k8s.CoreV1Pod).init(&c, c.context(), "default");

    // Act
    var stream = try pods.watch(.{});
    defer stream.close();

    // Assert
    try testing.expect(try stream.next() == null);
}

test "WatchStream: resourceVersion returns null before any events" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    const stream_body =
        \\{"type":"ADDED","object":{"metadata":{"name":"pod-1","namespace":"default","resourceVersion":"10"}}}
        \\
    ;
    mock.respondWithStream(.ok, stream_body);

    var c = mock.client();
    defer c.deinit();

    const pods = Api(k8s.CoreV1Pod).init(&c, c.context(), "default");

    var stream = try pods.watch(.{});
    defer stream.close();

    // Act / Assert
    try testing.expect(stream.resourceVersion() == null);

    const ev = (try stream.next()).?;
    defer ev.deinit();

    try testing.expectEqualStrings("10", stream.resourceVersion().?);
}

test "WatchStream: close is idempotent" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    mock.respondWithStream(.ok, "");

    var c = mock.client();
    defer c.deinit();

    const pods = Api(k8s.CoreV1Pod).init(&c, c.context(), "default");

    var stream = try pods.watch(.{});

    // Act
    stream.close();
    stream.close();

    // Assert: no panic or double-free
}

test "WatchStream: readLine rejects lines exceeding max_line_size" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    const line_len = WatchStream(k8s.CoreV1Pod).default_max_line_size + 1;
    const big_line = try testing.allocator.alloc(u8, line_len);
    defer testing.allocator.free(big_line);
    @memset(big_line, 'x');

    mock.respondWithStream(.ok, big_line);

    var c = mock.client();
    defer c.deinit();

    const pods = Api(k8s.CoreV1Pod).init(&c, c.context(), "default");

    var stream = try pods.watch(.{});
    defer stream.close();

    // Act / Assert
    try testing.expectError(error.LineTooLong, stream.next());
}

// ============================================================================
// collectAll pagination
// ============================================================================

test "collectAll: single page with no continue token returns all items" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    mock.respondWith(.ok,
        \\{"apiVersion":"v1","kind":"PodList","metadata":{"resourceVersion":"100"},"items":[{"metadata":{"name":"pod-1","namespace":"default"}},{"metadata":{"name":"pod-2","namespace":"default"}}]}
    );

    var c = mock.client();
    defer c.deinit();

    const pods = Api(k8s.CoreV1Pod).init(&c, c.context(), "default");

    // Act
    var result = try pods.collectAll(testing.allocator, .{}, .{ .page_size = 100 });
    defer result.deinit();

    // Assert
    try testing.expectEqual(@as(usize, 2), result.items.len);
    try testing.expectEqualStrings("pod-1", result.items[0].metadata.?.name.?);
    try testing.expectEqualStrings("pod-2", result.items[1].metadata.?.name.?);
    try testing.expectEqualStrings("100", result.resource_version.?);
}

test "collectAll: multi-page with continue tokens accumulates items" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    mock.respondWith(.ok,
        \\{"apiVersion":"v1","kind":"PodList","metadata":{"resourceVersion":"200","continue":"token-abc"},"items":[{"metadata":{"name":"pod-1","namespace":"default"}}]}
    );
    mock.respondWith(.ok,
        \\{"apiVersion":"v1","kind":"PodList","metadata":{"resourceVersion":"200","continue":"token-def"},"items":[{"metadata":{"name":"pod-2","namespace":"default"}}]}
    );
    mock.respondWith(.ok,
        \\{"apiVersion":"v1","kind":"PodList","metadata":{"resourceVersion":"200"},"items":[{"metadata":{"name":"pod-3","namespace":"default"}}]}
    );

    var c = mock.client();
    defer c.deinit();

    const pods = Api(k8s.CoreV1Pod).init(&c, c.context(), "default");

    // Act
    var result = try pods.collectAll(testing.allocator, .{}, .{ .page_size = 1 });
    defer result.deinit();

    // Assert
    try testing.expectEqual(@as(usize, 3), result.items.len);
    try testing.expectEqualStrings("pod-1", result.items[0].metadata.?.name.?);
    try testing.expectEqualStrings("pod-2", result.items[1].metadata.?.name.?);
    try testing.expectEqualStrings("pod-3", result.items[2].metadata.?.name.?);
}

test "collectAll: empty continue token treated as end of pagination" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    mock.respondWith(.ok,
        \\{"apiVersion":"v1","kind":"PodList","metadata":{"resourceVersion":"300","continue":""},"items":[{"metadata":{"name":"pod-1","namespace":"default"}}]}
    );

    var c = mock.client();
    defer c.deinit();

    const pods = Api(k8s.CoreV1Pod).init(&c, c.context(), "default");

    // Act
    var result = try pods.collectAll(testing.allocator, .{}, .{ .page_size = 100 });
    defer result.deinit();

    // Assert
    try testing.expectEqual(@as(usize, 1), result.items.len);
    try testing.expectEqual(@as(usize, 1), mock.requestCount());
}

test "collectAll: resource_version matches first page" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    mock.respondWith(.ok,
        \\{"apiVersion":"v1","kind":"PodList","metadata":{"resourceVersion":"500","continue":"more"},"items":[{"metadata":{"name":"pod-1","namespace":"default"}}]}
    );
    mock.respondWith(.ok,
        \\{"apiVersion":"v1","kind":"PodList","metadata":{"resourceVersion":"501"},"items":[{"metadata":{"name":"pod-2","namespace":"default"}}]}
    );

    var c = mock.client();
    defer c.deinit();

    const pods = Api(k8s.CoreV1Pod).init(&c, c.context(), "default");

    // Act
    var result = try pods.collectAll(testing.allocator, .{}, .{ .page_size = 1 });
    defer result.deinit();

    // Assert
    try testing.expectEqualStrings("500", result.resource_version.?);
}

// ============================================================================
// Discovery methods
// ============================================================================

/// Minimal APIResourceList JSON with a given resource name.
fn resourceListJson(comptime resource_name: []const u8) []const u8 {
    return "{\"groupVersion\":\"v1\",\"resources\":[{\"name\":\"" ++ resource_name ++ "\",\"singularName\":\"\",\"namespaced\":true,\"kind\":\"Pod\",\"verbs\":[\"get\"]}]}";
}

test "DiscoveryClient.hasResource: returns true when resource exists" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    mock.respondWith(.ok, comptime resourceListJson("pods"));

    var c = mock.client();
    defer c.deinit();

    var discovery = DiscoveryClient.init(testing.allocator, &c, c.context(), .{});
    defer discovery.deinit();

    // Act
    const result = try discovery.hasResource("", "v1", "pods");

    // Assert
    try testing.expect(result);
}

test "DiscoveryClient.hasResource: returns false when resource not in list" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    mock.respondWith(.ok, comptime resourceListJson("services"));

    var c = mock.client();
    defer c.deinit();

    var discovery = DiscoveryClient.init(testing.allocator, &c, c.context(), .{});
    defer discovery.deinit();

    // Act
    const result = try discovery.hasResource("", "v1", "pods");

    // Assert
    try testing.expect(!result);
}

test "DiscoveryClient.hasResource: returns false on 404" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    mock.respondWith(.not_found, not_found_json);

    var c = mock.client();
    defer c.deinit();

    var discovery = DiscoveryClient.init(testing.allocator, &c, c.context(), .{});
    defer discovery.deinit();

    // Act
    const result = try discovery.hasResource("nonexistent.io", "v1", "things");

    // Assert
    try testing.expect(!result);
}

test "DiscoveryClient.hasResource: returns error on 500" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    mock.respondWith(.internal_server_error,
        \\{"kind":"Status","apiVersion":"v1","metadata":{},"status":"Failure","message":"internal error","reason":"InternalError","code":500}
    );

    var c = mock.client();
    defer c.deinit();

    var discovery = DiscoveryClient.init(testing.allocator, &c, c.context(), .{});
    defer discovery.deinit();

    // Act / Assert
    try testing.expectError(error.HttpServerError, discovery.hasResource("", "v1", "pods"));
}

/// Minimal APIGroupList JSON containing the given groups.
const api_group_list_with_apps =
    \\{"groups":[{"name":"apps","versions":[{"groupVersion":"apps/v1","version":"v1"}],"preferredVersion":{"groupVersion":"apps/v1","version":"v1"}}]}
;

const api_group_list_without_apps =
    \\{"groups":[{"name":"batch","versions":[{"groupVersion":"batch/v1","version":"v1"}]}]}
;

test "DiscoveryClient.hasGroup: empty string returns true without request" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    var c = mock.client();
    defer c.deinit();

    var discovery = DiscoveryClient.init(testing.allocator, &c, c.context(), .{});
    defer discovery.deinit();

    // Act
    const result = try discovery.hasGroup("");

    // Assert
    try testing.expect(result);
    try testing.expectEqual(@as(usize, 0), mock.requestCount());
}

test "DiscoveryClient.hasGroup: returns true when group found" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    mock.respondWith(.ok, api_group_list_with_apps);

    var c = mock.client();
    defer c.deinit();

    var discovery = DiscoveryClient.init(testing.allocator, &c, c.context(), .{});
    defer discovery.deinit();

    // Act
    const result = try discovery.hasGroup("apps");

    // Assert
    try testing.expect(result);
}

test "DiscoveryClient.hasGroup: returns false when group not found" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    mock.respondWith(.ok, api_group_list_without_apps);

    var c = mock.client();
    defer c.deinit();

    var discovery = DiscoveryClient.init(testing.allocator, &c, c.context(), .{});
    defer discovery.deinit();

    // Act
    const result = try discovery.hasGroup("apps");

    // Assert
    try testing.expect(!result);
}

test "DiscoveryClient.findPreferredVersion: empty group returns v1" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    var c = mock.client();
    defer c.deinit();

    var discovery = DiscoveryClient.init(testing.allocator, &c, c.context(), .{});
    defer discovery.deinit();

    // Act
    const version = (try discovery.findPreferredVersion(testing.allocator, "")).?;
    defer testing.allocator.free(version);

    // Assert
    try testing.expectEqualStrings("v1", version);
}

test "DiscoveryClient.findPreferredVersion: returns preferredVersion when set" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    mock.respondWith(.ok, api_group_list_with_apps);

    var c = mock.client();
    defer c.deinit();

    var discovery = DiscoveryClient.init(testing.allocator, &c, c.context(), .{});
    defer discovery.deinit();

    // Act
    const version = (try discovery.findPreferredVersion(testing.allocator, "apps")).?;
    defer testing.allocator.free(version);

    // Assert
    try testing.expectEqualStrings("v1", version);
}

test "DiscoveryClient.findPreferredVersion: falls back to first version when preferredVersion null" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    mock.respondWith(.ok,
        \\{"groups":[{"name":"custom.io","versions":[{"groupVersion":"custom.io/v1beta1","version":"v1beta1"}]}]}
    );

    var c = mock.client();
    defer c.deinit();

    var discovery = DiscoveryClient.init(testing.allocator, &c, c.context(), .{});
    defer discovery.deinit();

    // Act
    const version = (try discovery.findPreferredVersion(testing.allocator, "custom.io")).?;
    defer testing.allocator.free(version);

    // Assert
    try testing.expectEqualStrings("v1beta1", version);
}

// ============================================================================
// applyInternal: Api(T)
// ============================================================================

test "Api(CoreV1Pod).apply: sends PATCH with apply content type and core apiVersion" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    mock.respondWith(.ok, pod_json);

    var c = mock.client();
    defer c.deinit();

    const pods = Api(k8s.CoreV1Pod).init(&c, c.context(), "default");
    const body = k8s.CoreV1Pod{
        .metadata = .{ .name = "test-pod" },
    };

    // Act
    const result = try (try pods.apply("test-pod", body, .{ .field_manager = "test" })).value();
    defer result.deinit();

    // Assert
    const req = mock.getRequest(0).?;
    try testing.expectEqual(http.Method.PATCH, req.method);
    try testing.expectEqualStrings("application/apply-patch+yaml", req.content_type.?);
    try testing.expect(req.payload != null);
    try testing.expect(std.mem.indexOf(u8, req.payload.?, "\"apiVersion\":\"v1\"") != null);
    try testing.expect(std.mem.indexOf(u8, req.payload.?, "\"kind\":\"Pod\"") != null);
}

test "Api(AppsV1Deployment).apply: named group has apiVersion apps/v1" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    mock.respondWith(.ok, deployment_json);

    var c = mock.client();
    defer c.deinit();

    const deploys = Api(k8s.AppsV1Deployment).init(&c, c.context(), "default");
    const body = k8s.AppsV1Deployment{
        .metadata = .{ .name = "test-deploy" },
    };

    // Act
    const result = try (try deploys.apply("test-deploy", body, .{ .field_manager = "test" })).value();
    defer result.deinit();

    // Assert
    const req = mock.getRequest(0).?;
    try testing.expectEqualStrings("application/apply-patch+yaml", req.content_type.?);
    try testing.expect(req.payload != null);
    try testing.expect(std.mem.indexOf(u8, req.payload.?, "\"apiVersion\":\"apps/v1\"") != null);
    try testing.expect(std.mem.indexOf(u8, req.payload.?, "\"kind\":\"Deployment\"") != null);
}

// ============================================================================
// applyInternal: DynamicApi
// ============================================================================

test "DynamicApi.apply: sets apiVersion and kind on object body" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    mock.respondWith(.ok, "{}");

    var c = mock.client();
    defer c.deinit();

    const api = try DynamicApi.init(&c, c.context(), .{
        .group = "apps",
        .version = "v1",
        .resource = "deployments",
        .kind = "Deployment",
        .namespaced = true,
    }, "default");

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        \\{"metadata":{"name":"test-deploy"}}
    ,
        .{},
    );
    defer parsed.deinit();

    // Act
    const result = try (try api.apply("test-deploy", parsed.value, .{ .field_manager = "test" })).value();
    defer result.deinit();

    // Assert
    const req = mock.getRequest(0).?;
    try testing.expectEqual(http.Method.PATCH, req.method);
    try testing.expectEqualStrings("application/apply-patch+yaml", req.content_type.?);
    try testing.expect(req.payload != null);
    try testing.expect(std.mem.indexOf(u8, req.payload.?, "\"apiVersion\":\"apps/v1\"") != null);
    try testing.expect(std.mem.indexOf(u8, req.payload.?, "\"kind\":\"Deployment\"") != null);
}

test "DynamicApi.apply: non-object body sent without apiVersion/kind injection" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    mock.respondWith(.ok, "{}");

    var c = mock.client();
    defer c.deinit();

    const api = try DynamicApi.init(&c, c.context(), .{
        .group = "",
        .version = "v1",
        .resource = "configmaps",
        .kind = "ConfigMap",
        .namespaced = true,
    }, "default");

    // Act
    const result = try (try api.apply("test-cm", .{ .string = "raw-content" }, .{ .field_manager = "test" })).value();
    defer result.deinit();

    // Assert
    const req = mock.getRequest(0).?;
    try testing.expect(req.payload != null);
    // A string body should not have apiVersion/kind injected.
    try testing.expect(std.mem.indexOf(u8, req.payload.?, "apiVersion") == null);
    try testing.expect(std.mem.indexOf(u8, req.payload.?, "kind") == null);
}

// ============================================================================
// Discovery caching
// ============================================================================

test "DiscoveryClient cache: hasResource twice for same group/version uses one request" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    mock.respondWith(.ok, comptime resourceListJson("pods"));

    var c = mock.client();
    defer c.deinit();

    var discovery = DiscoveryClient.init(testing.allocator, &c, c.context(), .{});
    defer discovery.deinit();

    // Act
    const r1 = try discovery.hasResource("", "v1", "pods");
    const r2 = try discovery.hasResource("", "v1", "pods");

    // Assert
    try testing.expect(r1);
    try testing.expect(r2);
    try testing.expectEqual(@as(usize, 1), mock.requestCount());
}

test "DiscoveryClient cache: hasResource then isResourceNamespaced shares cache" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    mock.respondWith(.ok, comptime resourceListJson("pods"));

    var c = mock.client();
    defer c.deinit();

    var discovery = DiscoveryClient.init(testing.allocator, &c, c.context(), .{});
    defer discovery.deinit();

    // Act
    const exists = try discovery.hasResource("", "v1", "pods");
    const namespaced = try discovery.isResourceNamespaced("", "v1", "pods");

    // Assert
    try testing.expect(exists);
    try testing.expect(namespaced != null);
    try testing.expect(namespaced.?);
    try testing.expectEqual(@as(usize, 1), mock.requestCount());
}

test "DiscoveryClient cache: TTL=0 disables caching" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    mock.respondWith(.ok, comptime resourceListJson("pods"));
    mock.respondWith(.ok, comptime resourceListJson("pods"));

    var c = mock.client();
    defer c.deinit();

    var discovery = DiscoveryClient.init(testing.allocator, &c, c.context(), .{ .cache_ttl_ns = 0 });
    defer discovery.deinit();

    // Act
    _ = try discovery.hasResource("", "v1", "pods");
    _ = try discovery.hasResource("", "v1", "pods");

    // Assert
    try testing.expectEqual(@as(usize, 2), mock.requestCount());
}

test "DiscoveryClient cache: invalidateCache forces re-fetch" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    mock.respondWith(.ok, comptime resourceListJson("pods"));
    mock.respondWith(.ok, comptime resourceListJson("pods"));

    var c = mock.client();
    defer c.deinit();

    var discovery = DiscoveryClient.init(testing.allocator, &c, c.context(), .{});
    defer discovery.deinit();

    // Act
    _ = try discovery.hasResource("", "v1", "pods");
    discovery.invalidateCache();
    _ = try discovery.hasResource("", "v1", "pods");

    // Assert
    try testing.expectEqual(@as(usize, 2), mock.requestCount());
}

test "DiscoveryClient cache: error responses are not cached" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    mock.respondWith(.internal_server_error,
        \\{"kind":"Status","apiVersion":"v1","metadata":{},"status":"Failure","message":"internal error","reason":"InternalError","code":500}
    );
    mock.respondWith(.ok, comptime resourceListJson("pods"));

    var c = mock.client();
    defer c.deinit();

    var discovery = DiscoveryClient.init(testing.allocator, &c, c.context(), .{});
    defer discovery.deinit();

    // Act
    const err_result = discovery.hasResource("", "v1", "pods");
    try testing.expectError(error.HttpServerError, err_result);

    const ok_result = try discovery.hasResource("", "v1", "pods");

    // Assert
    try testing.expect(ok_result);
    try testing.expectEqual(@as(usize, 2), mock.requestCount());
}

test "DiscoveryClient cache: hasGroup + findPreferredVersion share groups cache" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    mock.respondWith(.ok, api_group_list_with_apps);

    var c = mock.client();
    defer c.deinit();

    var discovery = DiscoveryClient.init(testing.allocator, &c, c.context(), .{});
    defer discovery.deinit();

    // Act
    const has = try discovery.hasGroup("apps");
    const version = try discovery.findPreferredVersion(testing.allocator, "apps");
    defer if (version) |v| testing.allocator.free(v);

    // Assert
    try testing.expect(has);
    try testing.expectEqualStrings("v1", version.?);
    try testing.expectEqual(@as(usize, 1), mock.requestCount());
}

test "DiscoveryClient cache: max_resource_cache_entries evicts oldest entry" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    mock.respondWith(.ok, comptime resourceListJson("things"));
    mock.respondWith(.ok, comptime resourceListJson("things"));
    mock.respondWith(.ok, comptime resourceListJson("things"));
    mock.respondWith(.ok, comptime resourceListJson("things"));

    var c = mock.client();
    defer c.deinit();

    var discovery = DiscoveryClient.init(testing.allocator, &c, c.context(), .{
        .max_resource_cache_entries = 2,
    });
    defer discovery.deinit();

    // Act
    _ = try discovery.hasResource("alpha.io", "v1", "things");
    _ = try discovery.hasResource("beta.io", "v1", "things");
    _ = try discovery.hasResource("gamma.io", "v1", "things");
    _ = try discovery.hasResource("alpha.io", "v1", "things");

    // Assert
    try testing.expectEqual(@as(usize, 4), mock.requestCount());
}

test "DiscoveryClient cache: entries within max limit are retained" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    mock.respondWith(.ok, comptime resourceListJson("things"));
    mock.respondWith(.ok, comptime resourceListJson("things"));

    var c = mock.client();
    defer c.deinit();

    var discovery = DiscoveryClient.init(testing.allocator, &c, c.context(), .{
        .max_resource_cache_entries = 2,
    });
    defer discovery.deinit();

    // Act
    _ = try discovery.hasResource("alpha.io", "v1", "things");
    _ = try discovery.hasResource("beta.io", "v1", "things");
    _ = try discovery.hasResource("alpha.io", "v1", "things");
    _ = try discovery.hasResource("beta.io", "v1", "things");

    // Assert
    try testing.expectEqual(@as(usize, 2), mock.requestCount());
}

// ============================================================================
// Connection pool observability
// ============================================================================

test "Client.poolStats: returns stats from mock transport" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    var c = mock.client();
    defer c.deinit();

    // Act
    const stats = c.poolStats();

    // Assert
    try testing.expect(stats != null);
    try testing.expectEqual(@as(u32, 0), stats.?.pool_size);
    try testing.expectEqual(@as(u32, 0), stats.?.free_connections);
    try testing.expectEqual(@as(u32, 0), stats.?.active_connections);
}

test "retry loop: transport error after 429 with Retry-After hint" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    mock.respondWithRetryAfterNs(.too_many_requests, "{}", 1);
    mock.respondWithTransportError();
    mock.respondWith(.ok, "{}");

    var c = mock.client();
    c.retry_policy = .{ .max_retries = 2, .initial_backoff_ns = 0, .max_backoff_ns = 0, .backoff_multiplier = 1, .jitter = false };
    defer c.deinit();
    const ctx = c.context();

    // Act
    const result = try c.getRaw("/api/v1/nodes", ctx);
    defer result.deinit();

    // Assert
    try testing.expect(result == .ok);
    try testing.expectEqual(@as(usize, 3), mock.requestCount());
}
