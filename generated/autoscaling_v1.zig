// Auto-generated from Kubernetes OpenAPI spec.
// Do not edit manually. Regenerate with: zig build generate

const std = @import("std");
const json = std.json;
const meta_v1 = @import("meta_v1.zig");

/// CrossVersionObjectReference contains enough information to let you identify the referred resource.
pub const AutoscalingV1CrossVersionObjectReference = struct {
    /// apiVersion is the API version of the referent
    apiVersion: ?[]const u8 = null,
    /// kind is the kind of the referent; More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: []const u8,
    /// name is the name of the referent; More info: https://kubernetes.io/docs/concepts/overview/working-with-objects/names/#names
    name: []const u8,
};

/// configuration of a horizontal pod autoscaler.
pub const AutoscalingV1HorizontalPodAutoscaler = struct {
    pub const resource_meta = .{
        .group = "autoscaling",
        .version = "v1",
        .kind = "HorizontalPodAutoscaler",
        .resource = "horizontalpodautoscalers",
        .namespaced = true,
        .list_kind = AutoscalingV1HorizontalPodAutoscalerList,
    };

    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard object metadata. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// spec defines the behaviour of autoscaler. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#spec-and-status.
    spec: AutoscalingV1HorizontalPodAutoscalerSpec,
    /// status is the current information about the autoscaler.
    status: ?AutoscalingV1HorizontalPodAutoscalerStatus = null,
};

/// list of horizontal pod autoscaler objects.
pub const AutoscalingV1HorizontalPodAutoscalerList = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// items is the list of horizontal pod autoscaler objects.
    items: []const AutoscalingV1HorizontalPodAutoscaler,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard list metadata.
    metadata: ?meta_v1.MetaV1ListMeta = null,
};

/// specification of a horizontal pod autoscaler.
pub const AutoscalingV1HorizontalPodAutoscalerSpec = struct {
    /// maxReplicas is the upper limit for the number of pods that can be set by the autoscaler; cannot be smaller than MinReplicas.
    maxReplicas: i32,
    /// minReplicas is the lower limit for the number of replicas to which the autoscaler can scale down.  It defaults to 1 pod.  minReplicas is allowed to be 0 if the alpha feature gate HPAScaleToZero is enabled and at least one Object or External metric is configured.  Scaling is active as long as at least one metric value is available.
    minReplicas: ?i32 = null,
    /// reference to scaled resource; horizontal pod autoscaler will learn the current resource consumption and will set the desired number of pods by using its Scale subresource.
    scaleTargetRef: AutoscalingV1CrossVersionObjectReference,
    /// targetCPUUtilizationPercentage is the target average CPU utilization (represented as a percentage of requested CPU) over all the pods; if not specified the default autoscaling policy will be used.
    targetCPUUtilizationPercentage: ?i32 = null,
};

/// current status of a horizontal pod autoscaler
pub const AutoscalingV1HorizontalPodAutoscalerStatus = struct {
    /// currentCPUUtilizationPercentage is the current average CPU utilization over all pods, represented as a percentage of requested CPU, e.g. 70 means that an average pod is using now 70% of its requested CPU.
    currentCPUUtilizationPercentage: ?i32 = null,
    /// currentReplicas is the current number of replicas of pods managed by this autoscaler.
    currentReplicas: i32,
    /// desiredReplicas is the  desired number of replicas of pods managed by this autoscaler.
    desiredReplicas: i32,
    /// lastScaleTime is the last time the HorizontalPodAutoscaler scaled the number of pods; used by the autoscaler to control how often the number of pods is changed.
    lastScaleTime: ?meta_v1.MetaV1Time = null,
    /// observedGeneration is the most recent generation observed by this autoscaler.
    observedGeneration: ?i64 = null,
};

/// Scale represents a scaling request for a resource.
pub const AutoscalingV1Scale = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard object metadata; More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata.
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// spec defines the behavior of the scale. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#spec-and-status.
    spec: ?AutoscalingV1ScaleSpec = null,
    /// status is the current status of the scale. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#spec-and-status. Read-only.
    status: ?AutoscalingV1ScaleStatus = null,
};

/// ScaleSpec describes the attributes of a scale subresource.
pub const AutoscalingV1ScaleSpec = struct {
    /// replicas is the desired number of instances for the scaled object.
    replicas: ?i32 = null,
};

/// ScaleStatus represents the current status of a scale subresource.
pub const AutoscalingV1ScaleStatus = struct {
    /// replicas is the actual number of observed instances of the scaled object.
    replicas: i32,
    /// selector is the label query over pods that should match the replicas count. This is same as the label selector but in the string format to avoid introspection by clients. The string will be in the same format as the query-param syntax. More info about label selectors: https://kubernetes.io/docs/concepts/overview/working-with-objects/labels/
    selector: ?[]const u8 = null,
};
