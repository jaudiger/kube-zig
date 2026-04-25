const std = @import("std");
const k8s = @import("k8s");

const testing = std.testing;
const json = std.json;

// Helper
fn parseFixture(comptime T: type, comptime path: []const u8) !json.Parsed(T) {
    const data = @embedFile(path);
    return json.parseFromSlice(T, testing.allocator, data, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

// Pod round-trip
test "Pod: parse fixture round-trip" {
    // Arrange
    const parsed = try parseFixture(k8s.CoreV1Pod, "fixtures/pod.json");
    defer parsed.deinit();

    // Act
    const pod = parsed.value;
    const container = pod.spec.?.containers[0];
    const port = container.ports.?[0];

    // Assert
    try testing.expectEqualStrings("v1", pod.apiVersion.?);
    try testing.expectEqualStrings("Pod", pod.kind.?);
    try testing.expectEqualStrings("nginx-pod", pod.metadata.?.name.?);
    try testing.expectEqualStrings("default", pod.metadata.?.namespace.?);
    try testing.expectEqualStrings("abc-123", pod.metadata.?.uid.?);
    try testing.expectEqual(@as(usize, 1), pod.spec.?.containers.len);
    try testing.expectEqualStrings("nginx", container.name);
    try testing.expectEqualStrings("nginx:1.25", container.image.?);
    try testing.expectEqual(@as(i32, 80), port.containerPort);
    try testing.expectEqualStrings("TCP", port.protocol.?);
}

// Deployment round-trip
test "Deployment: parse fixture round-trip" {
    // Arrange
    const parsed = try parseFixture(k8s.AppsV1Deployment, "fixtures/deployment.json");
    defer parsed.deinit();

    // Act
    const deploy = parsed.value;
    const containers = deploy.spec.?.template.spec.?.containers;
    const port = containers[0].ports.?[0];

    // Assert
    try testing.expectEqualStrings("apps/v1", deploy.apiVersion.?);
    try testing.expectEqualStrings("Deployment", deploy.kind.?);
    try testing.expectEqualStrings("nginx-deployment", deploy.metadata.?.name.?);
    try testing.expectEqualStrings("default", deploy.metadata.?.namespace.?);
    try testing.expectEqual(@as(?i32, 3), deploy.spec.?.replicas);
    try testing.expectEqual(@as(usize, 1), containers.len);
    try testing.expectEqualStrings("nginx", containers[0].name);
    try testing.expectEqualStrings("nginx:1.25", containers[0].image.?);
    try testing.expectEqual(@as(i32, 80), port.containerPort);
    try testing.expectEqualStrings("TCP", port.protocol.?);
}

// Service round-trip
test "Service: parse fixture round-trip" {
    // Arrange
    const parsed = try parseFixture(k8s.CoreV1Service, "fixtures/service.json");
    defer parsed.deinit();

    // Act
    const svc = parsed.value;
    const port = svc.spec.?.ports.?[0];

    // Assert
    try testing.expectEqualStrings("v1", svc.apiVersion.?);
    try testing.expectEqualStrings("Service", svc.kind.?);
    try testing.expectEqualStrings("my-service", svc.metadata.?.name.?);
    try testing.expectEqualStrings("default", svc.metadata.?.namespace.?);
    try testing.expectEqualStrings("ClusterIP", svc.spec.?.type.?);
    try testing.expectEqual(@as(i32, 80), port.port);
    try testing.expectEqualStrings("TCP", port.protocol.?);
    try testing.expectEqualStrings("http", port.name.?);
}

// PodList round-trip
test "PodList: parse fixture round-trip" {
    // Arrange
    const parsed = try parseFixture(k8s.CoreV1PodList, "fixtures/pod_list.json");
    defer parsed.deinit();

    // Act
    const list = parsed.value;
    const first = list.items[0];
    const second = list.items[1];

    // Assert
    try testing.expectEqual(@as(usize, 2), list.items.len);
    try testing.expectEqualStrings("12345", list.metadata.?.resourceVersion.?);
    try testing.expectEqualStrings("pod-a", first.metadata.?.name.?);
    try testing.expectEqualStrings("default", first.metadata.?.namespace.?);
    try testing.expectEqualStrings("app", first.spec.?.containers[0].name);
    try testing.expectEqualStrings("busybox", first.spec.?.containers[0].image.?);
    try testing.expectEqualStrings("pod-b", second.metadata.?.name.?);
    try testing.expectEqualStrings("kube-system", second.metadata.?.namespace.?);
    try testing.expectEqualStrings("sidecar", second.spec.?.containers[0].name);
    try testing.expectEqualStrings("envoy:latest", second.spec.?.containers[0].image.?);
}

// DeploymentList round-trip
test "DeploymentList: parse fixture round-trip" {
    // Arrange
    const parsed = try parseFixture(k8s.AppsV1DeploymentList, "fixtures/deployment_list.json");
    defer parsed.deinit();

    // Act
    const list = parsed.value;
    const deploy = list.items[0];

    // Assert
    try testing.expectEqual(@as(usize, 1), list.items.len);
    try testing.expectEqualStrings("67890", list.metadata.?.resourceVersion.?);
    try testing.expectEqualStrings("my-deploy", deploy.metadata.?.name.?);
    try testing.expectEqual(@as(?i32, 2), deploy.spec.?.replicas);
}

// ServiceList round-trip
test "ServiceList: parse fixture round-trip" {
    // Arrange
    const parsed = try parseFixture(k8s.CoreV1ServiceList, "fixtures/service_list.json");
    defer parsed.deinit();

    // Act
    const list = parsed.value;
    const svc = list.items[0];
    const port = svc.spec.?.ports.?[0];

    // Assert
    try testing.expectEqual(@as(usize, 1), list.items.len);
    try testing.expectEqualStrings("11111", list.metadata.?.resourceVersion.?);
    try testing.expectEqualStrings("backend-svc", svc.metadata.?.name.?);
    try testing.expectEqualStrings("NodePort", svc.spec.?.type.?);
    try testing.expectEqual(@as(i32, 8080), port.port);
    try testing.expectEqualStrings("TCP", port.protocol.?);
}

// Status round-trip
test "Status: parse delete fixture round-trip" {
    // Arrange
    const parsed = try parseFixture(k8s.MetaV1Status, "fixtures/status_delete.json");
    defer parsed.deinit();

    // Act
    const status = parsed.value;
    const details = status.details.?;

    // Assert
    try testing.expectEqualStrings("Success", status.status.?);
    try testing.expectEqual(@as(?i32, 200), status.code);
    try testing.expectEqualStrings("nginx-deployment", details.name.?);
    try testing.expectEqualStrings("apps", details.group.?);
    try testing.expectEqualStrings("deployments", details.kind.?);
    try testing.expectEqualStrings("def-456", details.uid.?);
}

test "Status: parse forbidden fixture round-trip" {
    // Arrange
    const parsed = try parseFixture(k8s.MetaV1Status, "fixtures/status_forbidden.json");
    defer parsed.deinit();

    // Act
    const status = parsed.value;

    // Assert
    try testing.expectEqualStrings("Failure", status.status.?);
    try testing.expectEqualStrings("Forbidden", status.reason.?);
    try testing.expectEqual(@as(?i32, 403), status.code);
    try testing.expect(std.mem.find(u8, status.message.?, "forbidden") != null);
    try testing.expect(std.mem.find(u8, status.message.?, "system:anonymous") != null);
}

test "Status: parse not_found fixture round-trip" {
    // Arrange
    const parsed = try parseFixture(k8s.MetaV1Status, "fixtures/status_not_found.json");
    defer parsed.deinit();

    // Act
    const status = parsed.value;
    const details = status.details.?;

    // Assert
    try testing.expectEqualStrings("Failure", status.status.?);
    try testing.expectEqualStrings("NotFound", status.reason.?);
    try testing.expectEqual(@as(?i32, 404), status.code);
    try testing.expectEqualStrings("nonexistent", details.name.?);
    try testing.expectEqualStrings("pods", details.kind.?);
}

// OOM edge cases
test "OOM during parse returns OutOfMemory for all resource types" {
    // Arrange
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const alloc = failing.allocator();
    const opts: json.ParseOptions = .{ .ignore_unknown_fields = true, .allocate = .alloc_always };

    // Act / Assert
    try testing.expectError(error.OutOfMemory, json.parseFromSlice(k8s.CoreV1Pod, alloc, @embedFile("fixtures/pod.json"), opts));
    try testing.expectError(error.OutOfMemory, json.parseFromSlice(k8s.CoreV1PodList, alloc, @embedFile("fixtures/pod_list.json"), opts));
    try testing.expectError(error.OutOfMemory, json.parseFromSlice(k8s.AppsV1Deployment, alloc, @embedFile("fixtures/deployment.json"), opts));
    try testing.expectError(error.OutOfMemory, json.parseFromSlice(k8s.MetaV1Status, alloc, @embedFile("fixtures/status_delete.json"), opts));
}

// Empty / minimal JSON
test "Pod: parse minimal empty object succeeds" {
    // Arrange
    const data = "{\"spec\":{\"containers\":[]}}";

    // Act
    const parsed = try json.parseFromSlice(k8s.CoreV1Pod, testing.allocator, data, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    // Assert
    try testing.expect(parsed.value.metadata == null);
    try testing.expect(parsed.value.apiVersion == null);
    try testing.expectEqual(@as(usize, 0), parsed.value.spec.?.containers.len);
}

test "Status: parse minimal object with only code" {
    // Arrange
    const data = "{\"code\":500}";

    // Act
    const parsed = try json.parseFromSlice(k8s.MetaV1Status, testing.allocator, data, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    // Assert
    try testing.expectEqual(@as(?i32, 500), parsed.value.code);
    try testing.expect(parsed.value.status == null);
    try testing.expect(parsed.value.message == null);
    try testing.expect(parsed.value.reason == null);
    try testing.expect(parsed.value.details == null);
}

// Unknown fields are ignored
test "Pod: unknown fields in JSON are silently ignored" {
    // Arrange
    const data =
        \\{"spec":{"containers":[]}, "unknownField": "should be ignored", "extra": 42}
    ;

    // Act
    const parsed = try json.parseFromSlice(k8s.CoreV1Pod, testing.allocator, data, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    // Assert
    try testing.expectEqual(@as(usize, 0), parsed.value.spec.?.containers.len);
}

// Memory safety: deinit frees all allocations
test "deinit frees all memory for all fixture types" {
    // Arrange
    const pod = try parseFixture(k8s.CoreV1Pod, "fixtures/pod.json");
    const deploy_list = try parseFixture(k8s.AppsV1DeploymentList, "fixtures/deployment_list.json");
    const delete_status = try parseFixture(k8s.MetaV1Status, "fixtures/status_delete.json");
    const forbidden = try parseFixture(k8s.MetaV1Status, "fixtures/status_forbidden.json");
    const not_found = try parseFixture(k8s.MetaV1Status, "fixtures/status_not_found.json");

    // Act / Assert
    not_found.deinit();
    forbidden.deinit();
    delete_status.deinit();
    deploy_list.deinit();
    pod.deinit();
}
