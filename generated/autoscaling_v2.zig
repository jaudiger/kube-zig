// Auto-generated from Kubernetes OpenAPI spec.
// Do not edit manually. Regenerate with: zig build generate

const std = @import("std");
const json = std.json;
const api_resource = @import("api_resource.zig");
const meta_v1 = @import("meta_v1.zig");

/// ContainerResourceMetricSource indicates how to scale on a resource metric known to Kubernetes, as specified in requests and limits, describing each pod in the current scale target (e.g. CPU or memory).  The values will be averaged together before being compared to the target.  Such metrics are built in to Kubernetes, and have special scaling options on top of those available to normal per-pod metrics using the "pods" source.  Only one "target" type should be set.
pub const AutoscalingV2ContainerResourceMetricSource = struct {
    /// container is the name of the container in the pods of the scaling target
    container: []const u8,
    /// name is the name of the resource in question.
    name: []const u8,
    /// target specifies the target value for the given metric
    target: AutoscalingV2MetricTarget,
};

/// ContainerResourceMetricStatus indicates the current value of a resource metric known to Kubernetes, as specified in requests and limits, describing a single container in each pod in the current scale target (e.g. CPU or memory).  Such metrics are built in to Kubernetes, and have special scaling options on top of those available to normal per-pod metrics using the "pods" source.
pub const AutoscalingV2ContainerResourceMetricStatus = struct {
    /// container is the name of the container in the pods of the scaling target
    container: []const u8,
    /// current contains the current value for the given metric
    current: AutoscalingV2MetricValueStatus,
    /// name is the name of the resource in question.
    name: []const u8,
};

/// CrossVersionObjectReference contains enough information to let you identify the referred resource.
pub const AutoscalingV2CrossVersionObjectReference = struct {
    /// apiVersion is the API version of the referent
    apiVersion: ?[]const u8 = null,
    /// kind is the kind of the referent; More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: []const u8,
    /// name is the name of the referent; More info: https://kubernetes.io/docs/concepts/overview/working-with-objects/names/#names
    name: []const u8,
};

/// ExternalMetricSource indicates how to scale on a metric not associated with any Kubernetes object (for example length of queue in cloud messaging service, or QPS from loadbalancer running outside of cluster).
pub const AutoscalingV2ExternalMetricSource = struct {
    /// metric identifies the target metric by name and selector
    metric: AutoscalingV2MetricIdentifier,
    /// target specifies the target value for the given metric
    target: AutoscalingV2MetricTarget,
};

/// ExternalMetricStatus indicates the current value of a global metric not associated with any Kubernetes object.
pub const AutoscalingV2ExternalMetricStatus = struct {
    /// current contains the current value for the given metric
    current: AutoscalingV2MetricValueStatus,
    /// metric identifies the target metric by name and selector
    metric: AutoscalingV2MetricIdentifier,
};

/// HPAScalingPolicy is a single policy which must hold true for a specified past interval.
pub const AutoscalingV2HPAScalingPolicy = struct {
    /// periodSeconds specifies the window of time for which the policy should hold true. PeriodSeconds must be greater than zero and less than or equal to 1800 (30 min).
    periodSeconds: i32,
    /// type is used to specify the scaling policy.
    type: []const u8,
    /// value contains the amount of change which is permitted by the policy. It must be greater than zero
    value: i32,
};

/// HPAScalingRules configures the scaling behavior for one direction via scaling Policy Rules and a configurable metric tolerance.
pub const AutoscalingV2HPAScalingRules = struct {
    /// policies is a list of potential scaling polices which can be used during scaling. If not set, use the default values: - For scale up: allow doubling the number of pods, or an absolute change of 4 pods in a 15s window. - For scale down: allow all pods to be removed in a 15s window.
    policies: ?[]const AutoscalingV2HPAScalingPolicy = null,
    /// selectPolicy is used to specify which policy should be used. If not set, the default value Max is used.
    selectPolicy: ?[]const u8 = null,
    /// stabilizationWindowSeconds is the number of seconds for which past recommendations should be considered while scaling up or scaling down. StabilizationWindowSeconds must be greater than or equal to zero and less than or equal to 3600 (one hour). If not set, use the default values: - For scale up: 0 (i.e. no stabilization is done). - For scale down: 300 (i.e. the stabilization window is 300 seconds long).
    stabilizationWindowSeconds: ?i32 = null,
    /// tolerance is the tolerance on the ratio between the current and desired metric value under which no updates are made to the desired number of replicas (e.g. 0.01 for 1%). Must be greater than or equal to zero. If not set, the default cluster-wide tolerance is applied (by default 10%).
    tolerance: ?api_resource.ApiResourceQuantity = null,
};

/// HorizontalPodAutoscaler is the configuration for a horizontal pod autoscaler, which automatically manages the replica count of any resource implementing the scale subresource based on the metrics specified.
pub const AutoscalingV2HorizontalPodAutoscaler = struct {
    pub const resource_meta = .{
        .group = "autoscaling",
        .version = "v2",
        .kind = "HorizontalPodAutoscaler",
        .resource = "horizontalpodautoscalers",
        .namespaced = true,
        .list_kind = AutoscalingV2HorizontalPodAutoscalerList,
    };

    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// metadata is the standard object metadata. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// spec is the specification for the behaviour of the autoscaler. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#spec-and-status.
    spec: AutoscalingV2HorizontalPodAutoscalerSpec,
    /// status is the current information about the autoscaler.
    status: ?AutoscalingV2HorizontalPodAutoscalerStatus = null,
};

/// HorizontalPodAutoscalerBehavior configures the scaling behavior of the target in both Up and Down directions (scaleUp and scaleDown fields respectively).
pub const AutoscalingV2HorizontalPodAutoscalerBehavior = struct {
    /// scaleDown is scaling policy for scaling Down. If not set, the default value is to allow to scale down to minReplicas pods, with a 300 second stabilization window (i.e., the highest recommendation for the last 300sec is used).
    scaleDown: ?AutoscalingV2HPAScalingRules = null,
    /// scaleUp is scaling policy for scaling Up. If not set, the default value is the higher of:
    scaleUp: ?AutoscalingV2HPAScalingRules = null,
};

/// HorizontalPodAutoscalerCondition describes the state of a HorizontalPodAutoscaler at a certain point.
pub const AutoscalingV2HorizontalPodAutoscalerCondition = struct {
    /// lastTransitionTime is the last time the condition transitioned from one status to another
    lastTransitionTime: ?meta_v1.MetaV1Time = null,
    /// message is a human-readable explanation containing details about the transition
    message: ?[]const u8 = null,
    /// reason is the reason for the condition's last transition.
    reason: ?[]const u8 = null,
    /// status is the status of the condition (True, False, Unknown)
    status: []const u8,
    /// type describes the current condition
    type: []const u8,
};

/// HorizontalPodAutoscalerList is a list of horizontal pod autoscaler objects.
pub const AutoscalingV2HorizontalPodAutoscalerList = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// items is the list of horizontal pod autoscaler objects.
    items: []const AutoscalingV2HorizontalPodAutoscaler,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// metadata is the standard list metadata.
    metadata: ?meta_v1.MetaV1ListMeta = null,
};

/// HorizontalPodAutoscalerSpec describes the desired functionality of the HorizontalPodAutoscaler.
pub const AutoscalingV2HorizontalPodAutoscalerSpec = struct {
    /// behavior configures the scaling behavior of the target in both Up and Down directions (scaleUp and scaleDown fields respectively). If not set, the default HPAScalingRules for scale up and scale down are used.
    behavior: ?AutoscalingV2HorizontalPodAutoscalerBehavior = null,
    /// maxReplicas is the upper limit for the number of replicas to which the autoscaler can scale up. It cannot be less that minReplicas.
    maxReplicas: i32,
    /// metrics contains the specifications for which to use to calculate the desired replica count (the maximum replica count across all metrics will be used).  The desired replica count is calculated multiplying the ratio between the target value and the current value by the current number of pods.  Ergo, metrics used must decrease as the pod count is increased, and vice-versa.  See the individual metric source types for more information about how each type of metric must respond. If not set, the default metric will be set to 80% average CPU utilization.
    metrics: ?[]const AutoscalingV2MetricSpec = null,
    /// minReplicas is the lower limit for the number of replicas to which the autoscaler can scale down.  It defaults to 1 pod.  minReplicas is allowed to be 0 if the alpha feature gate HPAScaleToZero is enabled and at least one Object or External metric is configured.  Scaling is active as long as at least one metric value is available.
    minReplicas: ?i32 = null,
    /// scaleTargetRef points to the target resource to scale, and is used to the pods for which metrics should be collected, as well as to actually change the replica count.
    scaleTargetRef: AutoscalingV2CrossVersionObjectReference,
};

/// HorizontalPodAutoscalerStatus describes the current status of a horizontal pod autoscaler.
pub const AutoscalingV2HorizontalPodAutoscalerStatus = struct {
    /// conditions is the set of conditions required for this autoscaler to scale its target, and indicates whether or not those conditions are met.
    conditions: ?[]const AutoscalingV2HorizontalPodAutoscalerCondition = null,
    /// currentMetrics is the last read state of the metrics used by this autoscaler.
    currentMetrics: ?[]const AutoscalingV2MetricStatus = null,
    /// currentReplicas is current number of replicas of pods managed by this autoscaler, as last seen by the autoscaler.
    currentReplicas: ?i32 = null,
    /// desiredReplicas is the desired number of replicas of pods managed by this autoscaler, as last calculated by the autoscaler.
    desiredReplicas: i32,
    /// lastScaleTime is the last time the HorizontalPodAutoscaler scaled the number of pods, used by the autoscaler to control how often the number of pods is changed.
    lastScaleTime: ?meta_v1.MetaV1Time = null,
    /// observedGeneration is the most recent generation observed by this autoscaler.
    observedGeneration: ?i64 = null,
};

/// MetricIdentifier defines the name and optionally selector for a metric
pub const AutoscalingV2MetricIdentifier = struct {
    /// name is the name of the given metric
    name: []const u8,
    /// selector is the string-encoded form of a standard kubernetes label selector for the given metric When set, it is passed as an additional parameter to the metrics server for more specific metrics scoping. When unset, just the metricName will be used to gather metrics.
    selector: ?meta_v1.MetaV1LabelSelector = null,
};

/// MetricSpec specifies how to scale based on a single metric (only `type` and one other matching field should be set at once).
pub const AutoscalingV2MetricSpec = struct {
    /// containerResource refers to a resource metric (such as those specified in requests and limits) known to Kubernetes describing a single container in each pod of the current scale target (e.g. CPU or memory). Such metrics are built in to Kubernetes, and have special scaling options on top of those available to normal per-pod metrics using the "pods" source.
    containerResource: ?AutoscalingV2ContainerResourceMetricSource = null,
    /// external refers to a global metric that is not associated with any Kubernetes object. It allows autoscaling based on information coming from components running outside of cluster (for example length of queue in cloud messaging service, or QPS from loadbalancer running outside of cluster).
    external: ?AutoscalingV2ExternalMetricSource = null,
    /// object refers to a metric describing a single kubernetes object (for example, hits-per-second on an Ingress object).
    object: ?AutoscalingV2ObjectMetricSource = null,
    /// pods refers to a metric describing each pod in the current scale target (for example, transactions-processed-per-second).  The values will be averaged together before being compared to the target value.
    pods: ?AutoscalingV2PodsMetricSource = null,
    /// resource refers to a resource metric (such as those specified in requests and limits) known to Kubernetes describing each pod in the current scale target (e.g. CPU or memory). Such metrics are built in to Kubernetes, and have special scaling options on top of those available to normal per-pod metrics using the "pods" source.
    resource: ?AutoscalingV2ResourceMetricSource = null,
    /// type is the type of metric source.  It should be one of "ContainerResource", "External", "Object", "Pods" or "Resource", each mapping to a matching field in the object.
    type: []const u8,
};

/// MetricStatus describes the last-read state of a single metric.
pub const AutoscalingV2MetricStatus = struct {
    /// container resource refers to a resource metric (such as those specified in requests and limits) known to Kubernetes describing a single container in each pod in the current scale target (e.g. CPU or memory). Such metrics are built in to Kubernetes, and have special scaling options on top of those available to normal per-pod metrics using the "pods" source.
    containerResource: ?AutoscalingV2ContainerResourceMetricStatus = null,
    /// external refers to a global metric that is not associated with any Kubernetes object. It allows autoscaling based on information coming from components running outside of cluster (for example length of queue in cloud messaging service, or QPS from loadbalancer running outside of cluster).
    external: ?AutoscalingV2ExternalMetricStatus = null,
    /// object refers to a metric describing a single kubernetes object (for example, hits-per-second on an Ingress object).
    object: ?AutoscalingV2ObjectMetricStatus = null,
    /// pods refers to a metric describing each pod in the current scale target (for example, transactions-processed-per-second).  The values will be averaged together before being compared to the target value.
    pods: ?AutoscalingV2PodsMetricStatus = null,
    /// resource refers to a resource metric (such as those specified in requests and limits) known to Kubernetes describing each pod in the current scale target (e.g. CPU or memory). Such metrics are built in to Kubernetes, and have special scaling options on top of those available to normal per-pod metrics using the "pods" source.
    resource: ?AutoscalingV2ResourceMetricStatus = null,
    /// type is the type of metric source.  It will be one of "ContainerResource", "External", "Object", "Pods" or "Resource", each corresponds to a matching field in the object.
    type: []const u8,
};

/// MetricTarget defines the target value, average value, or average utilization of a specific metric
pub const AutoscalingV2MetricTarget = struct {
    /// averageUtilization is the target value of the average of the resource metric across all relevant pods, represented as a percentage of the requested value of the resource for the pods. Currently only valid for Resource metric source type
    averageUtilization: ?i32 = null,
    /// averageValue is the target value of the average of the metric across all relevant pods (as a quantity)
    averageValue: ?api_resource.ApiResourceQuantity = null,
    /// type represents whether the metric type is Utilization, Value, or AverageValue
    type: []const u8,
    /// value is the target value of the metric (as a quantity).
    value: ?api_resource.ApiResourceQuantity = null,
};

/// MetricValueStatus holds the current value for a metric
pub const AutoscalingV2MetricValueStatus = struct {
    /// currentAverageUtilization is the current value of the average of the resource metric across all relevant pods, represented as a percentage of the requested value of the resource for the pods.
    averageUtilization: ?i32 = null,
    /// averageValue is the current value of the average of the metric across all relevant pods (as a quantity)
    averageValue: ?api_resource.ApiResourceQuantity = null,
    /// value is the current value of the metric (as a quantity).
    value: ?api_resource.ApiResourceQuantity = null,
};

/// ObjectMetricSource indicates how to scale on a metric describing a kubernetes object (for example, hits-per-second on an Ingress object).
pub const AutoscalingV2ObjectMetricSource = struct {
    /// describedObject specifies the descriptions of a object,such as kind,name apiVersion
    describedObject: AutoscalingV2CrossVersionObjectReference,
    /// metric identifies the target metric by name and selector
    metric: AutoscalingV2MetricIdentifier,
    /// target specifies the target value for the given metric
    target: AutoscalingV2MetricTarget,
};

/// ObjectMetricStatus indicates the current value of a metric describing a kubernetes object (for example, hits-per-second on an Ingress object).
pub const AutoscalingV2ObjectMetricStatus = struct {
    /// current contains the current value for the given metric
    current: AutoscalingV2MetricValueStatus,
    /// DescribedObject specifies the descriptions of a object,such as kind,name apiVersion
    describedObject: AutoscalingV2CrossVersionObjectReference,
    /// metric identifies the target metric by name and selector
    metric: AutoscalingV2MetricIdentifier,
};

/// PodsMetricSource indicates how to scale on a metric describing each pod in the current scale target (for example, transactions-processed-per-second). The values will be averaged together before being compared to the target value.
pub const AutoscalingV2PodsMetricSource = struct {
    /// metric identifies the target metric by name and selector
    metric: AutoscalingV2MetricIdentifier,
    /// target specifies the target value for the given metric
    target: AutoscalingV2MetricTarget,
};

/// PodsMetricStatus indicates the current value of a metric describing each pod in the current scale target (for example, transactions-processed-per-second).
pub const AutoscalingV2PodsMetricStatus = struct {
    /// current contains the current value for the given metric
    current: AutoscalingV2MetricValueStatus,
    /// metric identifies the target metric by name and selector
    metric: AutoscalingV2MetricIdentifier,
};

/// ResourceMetricSource indicates how to scale on a resource metric known to Kubernetes, as specified in requests and limits, describing each pod in the current scale target (e.g. CPU or memory).  The values will be averaged together before being compared to the target.  Such metrics are built in to Kubernetes, and have special scaling options on top of those available to normal per-pod metrics using the "pods" source.  Only one "target" type should be set.
pub const AutoscalingV2ResourceMetricSource = struct {
    /// name is the name of the resource in question.
    name: []const u8,
    /// target specifies the target value for the given metric
    target: AutoscalingV2MetricTarget,
};

/// ResourceMetricStatus indicates the current value of a resource metric known to Kubernetes, as specified in requests and limits, describing each pod in the current scale target (e.g. CPU or memory).  Such metrics are built in to Kubernetes, and have special scaling options on top of those available to normal per-pod metrics using the "pods" source.
pub const AutoscalingV2ResourceMetricStatus = struct {
    /// current contains the current value for the given metric
    current: AutoscalingV2MetricValueStatus,
    /// name is the name of the resource in question.
    name: []const u8,
};
