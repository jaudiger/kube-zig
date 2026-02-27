// Auto-generated from Kubernetes OpenAPI spec.
// Do not edit manually. Regenerate with: zig build generate

const std = @import("std");
const json = std.json;
const meta_v1 = @import("meta_v1.zig");

/// BasicSchedulingPolicy indicates that standard Kubernetes scheduling behavior should be used.
pub const SchedulingV1alpha1BasicSchedulingPolicy = std.json.Value;

/// GangSchedulingPolicy defines the parameters for gang scheduling.
pub const SchedulingV1alpha1GangSchedulingPolicy = struct {
    /// MinCount is the minimum number of pods that must be schedulable or scheduled at the same time for the scheduler to admit the entire group. It must be a positive integer.
    minCount: i32,
};

/// PodGroup represents a set of pods with a common scheduling policy.
pub const SchedulingV1alpha1PodGroup = struct {
    /// Name is a unique identifier for the PodGroup within the Workload. It must be a DNS label. This field is immutable.
    name: []const u8,
    /// Policy defines the scheduling policy for this PodGroup.
    policy: SchedulingV1alpha1PodGroupPolicy,
};

/// PodGroupPolicy defines the scheduling configuration for a PodGroup.
pub const SchedulingV1alpha1PodGroupPolicy = struct {
    /// Basic specifies that the pods in this group should be scheduled using standard Kubernetes scheduling behavior.
    basic: ?SchedulingV1alpha1BasicSchedulingPolicy = null,
    /// Gang specifies that the pods in this group should be scheduled using all-or-nothing semantics.
    gang: ?SchedulingV1alpha1GangSchedulingPolicy = null,
};

/// TypedLocalObjectReference allows to reference typed object inside the same namespace.
pub const SchedulingV1alpha1TypedLocalObjectReference = struct {
    /// APIGroup is the group for the resource being referenced. If APIGroup is empty, the specified Kind must be in the core API group. For any other third-party types, setting APIGroup is required. It must be a DNS subdomain.
    apiGroup: ?[]const u8 = null,
    /// Kind is the type of resource being referenced. It must be a path segment name.
    kind: []const u8,
    /// Name is the name of resource being referenced. It must be a path segment name.
    name: []const u8,
};

/// Workload allows for expressing scheduling constraints that should be used when managing lifecycle of workloads from scheduling perspective, including scheduling, preemption, eviction and other phases.
pub const SchedulingV1alpha1Workload = struct {
    pub const resource_meta = .{
        .group = "scheduling.k8s.io",
        .version = "v1alpha1",
        .kind = "Workload",
        .resource = "workloads",
        .namespaced = true,
        .list_kind = SchedulingV1alpha1WorkloadList,
    };

    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard object's metadata. Name must be a DNS subdomain.
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// Spec defines the desired behavior of a Workload.
    spec: SchedulingV1alpha1WorkloadSpec,
};

/// WorkloadList contains a list of Workload resources.
pub const SchedulingV1alpha1WorkloadList = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Items is the list of Workloads.
    items: []const SchedulingV1alpha1Workload,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard list metadata.
    metadata: ?meta_v1.MetaV1ListMeta = null,
};

/// WorkloadSpec defines the desired state of a Workload.
pub const SchedulingV1alpha1WorkloadSpec = struct {
    /// ControllerRef is an optional reference to the controlling object, such as a Deployment or Job. This field is intended for use by tools like CLIs to provide a link back to the original workload definition. When set, it cannot be changed.
    controllerRef: ?SchedulingV1alpha1TypedLocalObjectReference = null,
    /// PodGroups is the list of pod groups that make up the Workload. The maximum number of pod groups is 8. This field is immutable.
    podGroups: []const SchedulingV1alpha1PodGroup,
};
