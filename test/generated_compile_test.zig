const std = @import("std");
const k8s = @import("k8s");

const testing = std.testing;

// Comptime: all generated types exist
test "all generated types exist" {
    // Act / Assert
    comptime {
        _ = k8s.MetaV1ObjectMeta;
        _ = k8s.MetaV1ListMeta;
        _ = k8s.MetaV1LabelSelector;
        _ = k8s.MetaV1Status;
        _ = k8s.MetaV1StatusDetails;
        _ = k8s.CoreV1Pod;
        _ = k8s.CoreV1PodList;
        _ = k8s.CoreV1PodSpec;
        _ = k8s.CoreV1PodTemplateSpec;
        _ = k8s.CoreV1Container;
        _ = k8s.CoreV1ContainerPort;
        _ = k8s.CoreV1Service;
        _ = k8s.CoreV1ServiceList;
        _ = k8s.CoreV1ServiceSpec;
        _ = k8s.CoreV1ServicePort;
        _ = k8s.AppsV1Deployment;
        _ = k8s.AppsV1DeploymentList;
        _ = k8s.AppsV1DeploymentSpec;
        _ = k8s.AppsV1DeploymentStatus;
        _ = k8s.AppsV1DeploymentCondition;
    }
}

// Default init produces all-null struct
test "default init produces all-null Pod" {
    // Act
    const pod = k8s.CoreV1Pod{};

    // Assert
    try testing.expectEqual(null, pod.apiVersion);
    try testing.expectEqual(null, pod.kind);
    try testing.expectEqual(null, pod.metadata);
    try testing.expectEqual(null, pod.spec);
}

test "default init produces all-null Deployment" {
    // Act
    const deploy = k8s.AppsV1Deployment{};

    // Assert
    try testing.expectEqual(null, deploy.apiVersion);
    try testing.expectEqual(null, deploy.kind);
    try testing.expectEqual(null, deploy.metadata);
    try testing.expectEqual(null, deploy.spec);
    try testing.expectEqual(null, deploy.status);
}

// Nested references work
test "nested type references compile" {
    // Act / Assert
    comptime {
        // Deployment.spec.template.spec.containers
        const zeroes = std.mem.zeroes;
        _ = @TypeOf(zeroes(k8s.AppsV1DeploymentSpec).template);
        _ = @TypeOf(zeroes(k8s.CoreV1PodTemplateSpec).spec);
        _ = @TypeOf(zeroes(k8s.CoreV1PodSpec).containers);
    }
}

// Quoted keyword fields accessible
test "quoted keyword fields are accessible" {
    // Arrange
    const svc_spec = k8s.CoreV1ServiceSpec{};
    const list_meta = k8s.MetaV1ListMeta{};
    const cond = k8s.AppsV1DeploymentCondition{ .status = "", .type = "" };

    // Act / Assert
    try testing.expectEqual(null, svc_spec.type);
    try testing.expectEqual(null, list_meta.@"continue");
    try testing.expectEqualStrings("", cond.type);
}

// Correct primitive types
test "ContainerPort.containerPort is i32 (required)" {
    // Arrange
    const info = @typeInfo(k8s.CoreV1ContainerPort);

    // Act / Assert
    inline for (info.@"struct".fields) |f| {
        if (std.mem.eql(u8, f.name, "containerPort")) {
            try testing.expect(f.type == i32);
        }
    }
}

test "DeploymentSpec.replicas is i32" {
    // Arrange
    const info = @typeInfo(k8s.AppsV1DeploymentSpec);

    // Act / Assert
    inline for (info.@"struct".fields) |f| {
        if (std.mem.eql(u8, f.name, "replicas")) {
            try testing.expect(f.type == ?i32);
        }
    }
}
