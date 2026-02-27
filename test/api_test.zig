const std = @import("std");
const kube_zig = @import("kube-zig");
const k8s = @import("k8s");

// resource_meta on namespaced core group resources
test "resource_meta: CoreV1Pod is namespaced with empty group" {
    // Act
    const meta = k8s.CoreV1Pod.resource_meta;

    // Assert
    try std.testing.expectEqualStrings("", meta.group);
    try std.testing.expectEqualStrings("v1", meta.version);
    try std.testing.expectEqualStrings("pods", meta.resource);
    try std.testing.expectEqualStrings("Pod", meta.kind);
    try std.testing.expect(meta.namespaced);
    try std.testing.expect(meta.list_kind == k8s.CoreV1PodList);
}

test "resource_meta: CoreV1Service is namespaced with empty group" {
    // Act
    const meta = k8s.CoreV1Service.resource_meta;

    // Assert
    try std.testing.expectEqualStrings("", meta.group);
    try std.testing.expectEqualStrings("v1", meta.version);
    try std.testing.expectEqualStrings("services", meta.resource);
    try std.testing.expect(meta.namespaced);
    try std.testing.expect(meta.list_kind == k8s.CoreV1ServiceList);
}

test "resource_meta: CoreV1ConfigMap is namespaced with empty group" {
    // Act
    const meta = k8s.CoreV1ConfigMap.resource_meta;

    // Assert
    try std.testing.expectEqualStrings("", meta.group);
    try std.testing.expectEqualStrings("v1", meta.version);
    try std.testing.expectEqualStrings("configmaps", meta.resource);
    try std.testing.expect(meta.namespaced);
    try std.testing.expect(meta.list_kind == k8s.CoreV1ConfigMapList);
}

test "resource_meta: CoreV1Secret is namespaced with empty group" {
    // Act
    const meta = k8s.CoreV1Secret.resource_meta;

    // Assert
    try std.testing.expectEqualStrings("", meta.group);
    try std.testing.expectEqualStrings("v1", meta.version);
    try std.testing.expectEqualStrings("secrets", meta.resource);
    try std.testing.expect(meta.namespaced);
    try std.testing.expect(meta.list_kind == k8s.CoreV1SecretList);
}

test "resource_meta: CoreV1ServiceAccount is namespaced with empty group" {
    // Act
    const meta = k8s.CoreV1ServiceAccount.resource_meta;

    // Assert
    try std.testing.expectEqualStrings("", meta.group);
    try std.testing.expectEqualStrings("v1", meta.version);
    try std.testing.expectEqualStrings("serviceaccounts", meta.resource);
    try std.testing.expect(meta.namespaced);
    try std.testing.expect(meta.list_kind == k8s.CoreV1ServiceAccountList);
}

// resource_meta on named group resources
test "resource_meta: AppsV1Deployment has apps group and is namespaced" {
    // Act
    const meta = k8s.AppsV1Deployment.resource_meta;

    // Assert
    try std.testing.expectEqualStrings("apps", meta.group);
    try std.testing.expectEqualStrings("v1", meta.version);
    try std.testing.expectEqualStrings("deployments", meta.resource);
    try std.testing.expectEqualStrings("Deployment", meta.kind);
    try std.testing.expect(meta.namespaced);
    try std.testing.expect(meta.list_kind == k8s.AppsV1DeploymentList);
}

test "resource_meta: AppsV1StatefulSet has apps group and is namespaced" {
    // Act
    const meta = k8s.AppsV1StatefulSet.resource_meta;

    // Assert
    try std.testing.expectEqualStrings("apps", meta.group);
    try std.testing.expectEqualStrings("v1", meta.version);
    try std.testing.expectEqualStrings("statefulsets", meta.resource);
    try std.testing.expect(meta.namespaced);
    try std.testing.expect(meta.list_kind == k8s.AppsV1StatefulSetList);
}

test "resource_meta: AppsV1DaemonSet has apps group and is namespaced" {
    // Act
    const meta = k8s.AppsV1DaemonSet.resource_meta;

    // Assert
    try std.testing.expectEqualStrings("apps", meta.group);
    try std.testing.expectEqualStrings("v1", meta.version);
    try std.testing.expectEqualStrings("daemonsets", meta.resource);
    try std.testing.expect(meta.namespaced);
    try std.testing.expect(meta.list_kind == k8s.AppsV1DaemonSetList);
}

test "resource_meta: BatchV1Job has batch group and is namespaced" {
    // Act
    const meta = k8s.BatchV1Job.resource_meta;

    // Assert
    try std.testing.expectEqualStrings("batch", meta.group);
    try std.testing.expectEqualStrings("v1", meta.version);
    try std.testing.expectEqualStrings("jobs", meta.resource);
    try std.testing.expectEqualStrings("Job", meta.kind);
    try std.testing.expect(meta.namespaced);
    try std.testing.expect(meta.list_kind == k8s.BatchV1JobList);
}

test "resource_meta: BatchV1CronJob has batch group and is namespaced" {
    // Act
    const meta = k8s.BatchV1CronJob.resource_meta;

    // Assert
    try std.testing.expectEqualStrings("batch", meta.group);
    try std.testing.expectEqualStrings("v1", meta.version);
    try std.testing.expectEqualStrings("cronjobs", meta.resource);
    try std.testing.expectEqualStrings("CronJob", meta.kind);
    try std.testing.expect(meta.namespaced);
    try std.testing.expect(meta.list_kind == k8s.BatchV1CronJobList);
}

test "resource_meta: NetworkingV1Ingress has networking.k8s.io group" {
    // Act
    const meta = k8s.NetworkingV1Ingress.resource_meta;

    // Assert
    try std.testing.expectEqualStrings("networking.k8s.io", meta.group);
    try std.testing.expectEqualStrings("v1", meta.version);
    try std.testing.expectEqualStrings("ingresses", meta.resource);
    try std.testing.expectEqualStrings("Ingress", meta.kind);
    try std.testing.expect(meta.namespaced);
    try std.testing.expect(meta.list_kind == k8s.NetworkingV1IngressList);
}

test "resource_meta: RbacV1Role has rbac.authorization.k8s.io group and is namespaced" {
    // Act
    const meta = k8s.RbacV1Role.resource_meta;

    // Assert
    try std.testing.expectEqualStrings("rbac.authorization.k8s.io", meta.group);
    try std.testing.expectEqualStrings("v1", meta.version);
    try std.testing.expectEqualStrings("roles", meta.resource);
    try std.testing.expect(meta.namespaced);
    try std.testing.expect(meta.list_kind == k8s.RbacV1RoleList);
}

// resource_meta on cluster-scoped resources
test "resource_meta: CoreV1Node is cluster-scoped with empty group" {
    // Act
    const meta = k8s.CoreV1Node.resource_meta;

    // Assert
    try std.testing.expectEqualStrings("", meta.group);
    try std.testing.expectEqualStrings("v1", meta.version);
    try std.testing.expectEqualStrings("nodes", meta.resource);
    try std.testing.expectEqualStrings("Node", meta.kind);
    try std.testing.expect(!meta.namespaced);
    try std.testing.expect(meta.list_kind == k8s.CoreV1NodeList);
}

test "resource_meta: CoreV1Namespace is cluster-scoped with empty group" {
    // Act
    const meta = k8s.CoreV1Namespace.resource_meta;

    // Assert
    try std.testing.expectEqualStrings("", meta.group);
    try std.testing.expectEqualStrings("v1", meta.version);
    try std.testing.expectEqualStrings("namespaces", meta.resource);
    try std.testing.expectEqualStrings("Namespace", meta.kind);
    try std.testing.expect(!meta.namespaced);
    try std.testing.expect(meta.list_kind == k8s.CoreV1NamespaceList);
}

test "resource_meta: CoreV1PersistentVolume is cluster-scoped" {
    // Act
    const meta = k8s.CoreV1PersistentVolume.resource_meta;

    // Assert
    try std.testing.expectEqualStrings("", meta.group);
    try std.testing.expectEqualStrings("v1", meta.version);
    try std.testing.expectEqualStrings("persistentvolumes", meta.resource);
    try std.testing.expect(!meta.namespaced);
}

test "resource_meta: RbacV1ClusterRole is cluster-scoped with named group" {
    // Act
    const meta = k8s.RbacV1ClusterRole.resource_meta;

    // Assert
    try std.testing.expectEqualStrings("rbac.authorization.k8s.io", meta.group);
    try std.testing.expectEqualStrings("v1", meta.version);
    try std.testing.expectEqualStrings("clusterroles", meta.resource);
    try std.testing.expectEqualStrings("ClusterRole", meta.kind);
    try std.testing.expect(!meta.namespaced);
    try std.testing.expect(meta.list_kind == k8s.RbacV1ClusterRoleList);
}

test "resource_meta: RbacV1ClusterRoleBinding is cluster-scoped with named group" {
    // Act
    const meta = k8s.RbacV1ClusterRoleBinding.resource_meta;

    // Assert
    try std.testing.expectEqualStrings("rbac.authorization.k8s.io", meta.group);
    try std.testing.expectEqualStrings("v1", meta.version);
    try std.testing.expectEqualStrings("clusterrolebindings", meta.resource);
    try std.testing.expect(!meta.namespaced);
    try std.testing.expect(meta.list_kind == k8s.RbacV1ClusterRoleBindingList);
}

test "resource_meta: NetworkingV1IngressClass is cluster-scoped with named group" {
    // Act
    const meta = k8s.NetworkingV1IngressClass.resource_meta;

    // Assert
    try std.testing.expectEqualStrings("networking.k8s.io", meta.group);
    try std.testing.expectEqualStrings("v1", meta.version);
    try std.testing.expectEqualStrings("ingressclasses", meta.resource);
    try std.testing.expect(!meta.namespaced);
    try std.testing.expect(meta.list_kind == k8s.NetworkingV1IngressClassList);
}

// Non-resource types lack resource_meta
test "non-resource types do not have resource_meta" {
    // Act / Assert
    comptime {
        if (@hasDecl(k8s.CoreV1PodSpec, "resource_meta")) @compileError("PodSpec");
        if (@hasDecl(k8s.CoreV1Container, "resource_meta")) @compileError("Container");
        if (@hasDecl(k8s.AppsV1DeploymentSpec, "resource_meta")) @compileError("DeploymentSpec");
        if (@hasDecl(k8s.AppsV1DeploymentStatus, "resource_meta")) @compileError("DeploymentStatus");
        if (@hasDecl(k8s.MetaV1ObjectMeta, "resource_meta")) @compileError("ObjectMeta");
        if (@hasDecl(k8s.CoreV1ContainerPort, "resource_meta")) @compileError("ContainerPort");
        if (@hasDecl(k8s.CoreV1ServiceSpec, "resource_meta")) @compileError("ServiceSpec");
        if (@hasDecl(k8s.CoreV1NodeSpec, "resource_meta")) @compileError("NodeSpec");
    }
}

// Api(T) comptime instantiation with real K8s types
test "Api(T) instantiates for all resource type categories" {
    // Act / Assert
    comptime {
        // Namespaced, core group
        _ = kube_zig.Api(k8s.CoreV1Pod);
        // Namespaced, named group
        _ = kube_zig.Api(k8s.AppsV1Deployment);
        // Namespaced, batch group
        _ = kube_zig.Api(k8s.BatchV1Job);
        // Namespaced, dotted group
        _ = kube_zig.Api(k8s.NetworkingV1Ingress);
        // Cluster-scoped, core group
        _ = kube_zig.Api(k8s.CoreV1Node);
        _ = kube_zig.Api(k8s.CoreV1Namespace);
        _ = kube_zig.Api(k8s.CoreV1PersistentVolume);
        // Cluster-scoped, named group
        _ = kube_zig.Api(k8s.RbacV1ClusterRole);
    }
}

// Subresource method existence
test "Api(T) has status subresource methods on supported types" {
    // Act / Assert
    comptime {
        for (.{
            kube_zig.Api(k8s.CoreV1Pod),
            kube_zig.Api(k8s.AppsV1Deployment),
            kube_zig.Api(k8s.CoreV1Node),
            kube_zig.Api(k8s.CoreV1Namespace),
        }) |ApiType| {
            _ = &ApiType.getStatus;
            _ = &ApiType.updateStatus;
            _ = &ApiType.patchStatus;
        }
    }
}

test "Api(T) has scale subresource methods on scalable types" {
    // Act / Assert
    comptime {
        for (.{
            kube_zig.Api(k8s.AppsV1Deployment),
            kube_zig.Api(k8s.AppsV1StatefulSet),
        }) |ApiType| {
            _ = @TypeOf(ApiType.getScale);
            _ = @TypeOf(ApiType.updateScale);
            _ = @TypeOf(ApiType.patchScale);
        }
    }
}

test "Api(CoreV1Pod) has getLogs and evict methods" {
    // Act / Assert
    comptime {
        const PodApi = kube_zig.Api(k8s.CoreV1Pod);
        _ = &PodApi.getLogs;
        _ = kube_zig.LogOptions;
        _ = @TypeOf(PodApi.evict);
    }
}

// Watch method and type existence
test "Api(T) has watch and watchAll methods on namespaced types" {
    // Act / Assert
    comptime {
        for (.{
            kube_zig.Api(k8s.CoreV1Pod),
            kube_zig.Api(k8s.AppsV1Deployment),
            kube_zig.Api(k8s.BatchV1Job),
        }) |ApiType| {
            _ = &ApiType.watch;
            _ = &ApiType.watchAll;
        }
        _ = kube_zig.WatchOptions;

        // Cluster-scoped has watch but not necessarily watchAll
        _ = &kube_zig.Api(k8s.CoreV1Node).watch;
    }
}

test "Watch types instantiate with real K8s types" {
    // Act / Assert
    comptime {
        _ = kube_zig.WatchEvent(k8s.CoreV1Pod);
        _ = kube_zig.WatchStream(k8s.CoreV1Pod);
        _ = kube_zig.ParsedEvent(k8s.CoreV1Pod);
        _ = kube_zig.WatchEvent(k8s.AppsV1Deployment);
        _ = kube_zig.WatchEvent(k8s.CoreV1Node);
    }
}

// Pagination, patch, listAll, apply
test "Api(T) has collectAll and pagination types" {
    // Act / Assert
    comptime {
        const PodApi = kube_zig.Api(k8s.CoreV1Pod);
        if (!@hasDecl(PodApi, "collectAll")) @compileError("missing collectAll");
        if (!@hasDecl(PodApi, "collectAllAcrossNamespaces")) @compileError("missing collectAllAcrossNamespaces");
        if (!@hasDecl(PodApi, "PagerOptions")) @compileError("missing PagerOptions");
        if (!@hasDecl(PodApi, "CollectedList")) @compileError("missing CollectedList");

        const NodeApi = kube_zig.Api(k8s.CoreV1Node);
        if (!@hasDecl(NodeApi, "collectAll")) @compileError("missing collectAll for cluster-scoped");
    }
}

test "Api(T) has patch and listAll methods" {
    // Act / Assert
    comptime {
        const PodApi = kube_zig.Api(k8s.CoreV1Pod);
        _ = &PodApi.patch;
        _ = kube_zig.PatchType;
        _ = kube_zig.PatchOptions;
        _ = &PodApi.listAll;
        _ = &kube_zig.Api(k8s.AppsV1Deployment).listAll;
    }
}

test "Api(T) has apply and applyStatus methods" {
    // Act / Assert
    comptime {
        for (.{
            kube_zig.Api(k8s.CoreV1Pod),
            kube_zig.Api(k8s.AppsV1Deployment),
            kube_zig.Api(k8s.CoreV1Node),
        }) |ApiType| {
            _ = &ApiType.apply;
            _ = &ApiType.applyStatus;
        }
        _ = kube_zig.ApplyOptions;
    }
}

// SSA utilities existence
test "managed_fields and ssa modules are accessible" {
    // Act / Assert
    comptime {
        _ = kube_zig.managed_fields;
        _ = &kube_zig.managed_fields.getManagedFields;
        _ = &kube_zig.managed_fields.getFieldManagers;
        _ = &kube_zig.managed_fields.findManager;
        _ = &kube_zig.managed_fields.isFieldManager;
        _ = &kube_zig.managed_fields.isApplyManager;

        _ = kube_zig.ssa;
        _ = kube_zig.ssa.ConflictInfo;
        _ = &kube_zig.ssa.isApplyConflict;
        _ = &kube_zig.ssa.extractConflictInfo;
    }
}
