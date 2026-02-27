// Auto-generated from Kubernetes OpenAPI spec.
// Do not edit manually. Regenerate with: zig build generate

const std = @import("std");
const json = std.json;
const meta_v1 = @import("meta_v1.zig");
const util_intstr = @import("util_intstr.zig");

/// Eviction evicts a pod from its node subject to certain policies and safety constraints. This is a subresource of Pod.  A request to cause such an eviction is created by POSTing to .../pods/<pod name>/evictions.
pub const PolicyV1Eviction = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// DeleteOptions may be provided
    deleteOptions: ?meta_v1.MetaV1DeleteOptions = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// ObjectMeta describes the pod that is being evicted.
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
};

/// PodDisruptionBudget is an object to define the max disruption that can be caused to a collection of pods
pub const PolicyV1PodDisruptionBudget = struct {
    pub const resource_meta = .{
        .group = "policy",
        .version = "v1",
        .kind = "PodDisruptionBudget",
        .resource = "poddisruptionbudgets",
        .namespaced = true,
        .list_kind = PolicyV1PodDisruptionBudgetList,
    };

    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard object's metadata. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// Specification of the desired behavior of the PodDisruptionBudget.
    spec: ?PolicyV1PodDisruptionBudgetSpec = null,
    /// Most recently observed status of the PodDisruptionBudget.
    status: ?PolicyV1PodDisruptionBudgetStatus = null,
};

/// PodDisruptionBudgetList is a collection of PodDisruptionBudgets.
pub const PolicyV1PodDisruptionBudgetList = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Items is a list of PodDisruptionBudgets
    items: []const PolicyV1PodDisruptionBudget,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard object's metadata. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata
    metadata: ?meta_v1.MetaV1ListMeta = null,
};

/// PodDisruptionBudgetSpec is a description of a PodDisruptionBudget.
pub const PolicyV1PodDisruptionBudgetSpec = struct {
    /// An eviction is allowed if at most "maxUnavailable" pods selected by "selector" are unavailable after the eviction, i.e. even in absence of the evicted pod. For example, one can prevent all voluntary evictions by specifying 0. This is a mutually exclusive setting with "minAvailable".
    maxUnavailable: ?util_intstr.UtilIntstrIntOrString = null,
    /// An eviction is allowed if at least "minAvailable" pods selected by "selector" will still be available after the eviction, i.e. even in the absence of the evicted pod.  So for example you can prevent all voluntary evictions by specifying "100%".
    minAvailable: ?util_intstr.UtilIntstrIntOrString = null,
    /// Label query over pods whose evictions are managed by the disruption budget. A null selector will match no pods, while an empty ({}) selector will select all pods within the namespace.
    selector: ?meta_v1.MetaV1LabelSelector = null,
    /// UnhealthyPodEvictionPolicy defines the criteria for when unhealthy pods should be considered for eviction. Current implementation considers healthy pods, as pods that have status.conditions item with type="Ready",status="True".
    unhealthyPodEvictionPolicy: ?[]const u8 = null,
};

/// PodDisruptionBudgetStatus represents information about the status of a PodDisruptionBudget. Status may trail the actual state of a system.
pub const PolicyV1PodDisruptionBudgetStatus = struct {
    /// Conditions contain conditions for PDB. The disruption controller sets the DisruptionAllowed condition. The following are known values for the reason field (additional reasons could be added in the future): - SyncFailed: The controller encountered an error and wasn't able to compute
    conditions: ?[]const meta_v1.MetaV1Condition = null,
    /// current number of healthy pods
    currentHealthy: i32,
    /// minimum desired number of healthy pods
    desiredHealthy: i32,
    /// DisruptedPods contains information about pods whose eviction was processed by the API server eviction subresource handler but has not yet been observed by the PodDisruptionBudget controller. A pod will be in this map from the time when the API server processed the eviction request to the time when the pod is seen by PDB controller as having been marked for deletion (or after a timeout). The key in the map is the name of the pod and the value is the time when the API server processed the eviction request. If the deletion didn't occur and a pod is still there it will be removed from the list automatically by PodDisruptionBudget controller after some time. If everything goes smooth this map should be empty for the most of the time. Large number of entries in the map may indicate problems with pod deletions.
    disruptedPods: ?json.ArrayHashMap(meta_v1.MetaV1Time) = null,
    /// Number of pod disruptions that are currently allowed.
    disruptionsAllowed: i32,
    /// total number of pods counted by this disruption budget
    expectedPods: i32,
    /// Most recent generation observed when updating this PDB status. DisruptionsAllowed and other status information is valid only if observedGeneration equals to PDB's object generation.
    observedGeneration: ?i64 = null,
};
