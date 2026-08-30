// Auto-generated from Kubernetes OpenAPI spec.
// Do not edit manually. Regenerate with: zig build generate

const std = @import("std");
const json = std.json;
const meta_v1 = @import("meta_v1.zig");

/// Eviction initiates an eviction process, which should ideally result in a graceful eviction of a .spec.target (e.g. termination of a pod).
pub const LifecycleV1alpha1Eviction = struct {
    pub const resource_meta = .{
        .group = "lifecycle.k8s.io",
        .version = "v1alpha1",
        .kind = "Eviction",
        .resource = "evictions",
        .namespaced = true,
        .list_kind = LifecycleV1alpha1EvictionList,
    };

    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// metadata is the standard object metadata; More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata. .metadata.name set by the evictionrequest-controller is purely informative and subject to change. .spec.target field should be used to identify the target precisesly.
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// spec defines the eviction specification. https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#spec-and-status
    spec: LifecycleV1alpha1EvictionSpec,
    /// status represents the most recently observed status of the eviction. Populated by responders and evictionrequest-controller. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#spec-and-status
    status: ?LifecycleV1alpha1EvictionStatus = null,
};

/// EvictionList contains a list of Eviction resources.
pub const LifecycleV1alpha1EvictionList = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// items is the list of Evictions.
    items: []const LifecycleV1alpha1Eviction,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// metadata is the standard list metadata. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata
    metadata: ?meta_v1.MetaV1ListMeta = null,
};

/// EvictionPodReference contains enough information to locate the referenced pod inside the same namespace.
pub const LifecycleV1alpha1EvictionPodReference = struct {
    /// name of the target. This field is required.
    name: []const u8,
    /// uid of the target. It can be found in .metadata.uid of the target and is a lowercase UUID in 8-4-4-4-12 format. This field is required.
    uid: []const u8,
};

/// EvictionRequest defines a request that should ideally result in a graceful eviction of a .spec.target (e.g. termination of a pod).
pub const LifecycleV1alpha1EvictionRequest = struct {
    pub const resource_meta = .{
        .group = "lifecycle.k8s.io",
        .version = "v1alpha1",
        .kind = "EvictionRequest",
        .resource = "evictionrequests",
        .namespaced = true,
        .list_kind = LifecycleV1alpha1EvictionRequestList,
    };

    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// metadata is the standard object metadata; More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata.
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// spec defines the eviction request specification. https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#spec-and-status
    spec: LifecycleV1alpha1EvictionRequestSpec,
    /// status represents the most recently observed status of the eviction request. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#spec-and-status
    status: ?LifecycleV1alpha1EvictionRequestStatus = null,
};

/// EvictionRequestList contains a list of EvictionRequests resources.
pub const LifecycleV1alpha1EvictionRequestList = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// items is the list of EvictionRequests.
    items: []const LifecycleV1alpha1EvictionRequest,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// metadata is the standard list metadata. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata
    metadata: ?meta_v1.MetaV1ListMeta = null,
};

/// EvictionRequestPodReference contains enough information to locate the referenced pod inside the same namespace.
pub const LifecycleV1alpha1EvictionRequestPodReference = struct {
    /// name of the target. This field is required.
    name: []const u8,
    /// uid of the target. It can be found in .metadata.uid of the target and is a lowercase UUID in 8-4-4-4-12 format. This field is required.
    uid: []const u8,
};

/// EvictionRequestSpec is a specification of an EvictionRequest.
pub const LifecycleV1alpha1EvictionRequestSpec = struct {
    /// intent specifies the action that should be taken for the specified target.
    intent: []const u8,
    /// requester allows you to identify the entity, that requested the eviction of the target.
    requester: []const u8,
    /// target contains a reference to an object (e.g. a pod) that should be evicted. This field is required and immutable.
    target: LifecycleV1alpha1EvictionRequestTarget,
};

/// EvictionRequestStatus represents the last observed status of the eviction request.
pub const LifecycleV1alpha1EvictionRequestStatus = struct {
    /// conditions contain information about the eviction request.
    conditions: ?[]const meta_v1.MetaV1Condition = null,
    /// observedGeneration is EvictionRequest's .metadata.generation observed by the evictionrequest-controller. The observed generation value cannot be negative and can only be incremented. The minimum value is 1. This field is managed by evictionrequest-controller.
    observedGeneration: ?i64 = null,
};

/// EvictionRequestTarget contains a reference to an object that should be evicted.
pub const LifecycleV1alpha1EvictionRequestTarget = struct {
    /// pod references a pod that is subject to eviction/termination. Pods that are part of a PodGroup (.spec.schedulingGroup is set) are not supported.
    pod: ?LifecycleV1alpha1EvictionRequestPodReference = null,
};

/// EvictionSpec is a specification of an Eviction.
pub const LifecycleV1alpha1EvictionSpec = struct {
    /// target contains a reference to an object (e.g. a pod) that should be evicted. This field is required and immutable.
    target: LifecycleV1alpha1EvictionTarget,
};

/// EvictionStatus represents the last observed status of the eviction request.
pub const LifecycleV1alpha1EvictionStatus = struct {
    /// conditions contain information about the eviction request.
    conditions: ?[]const meta_v1.MetaV1Condition = null,
    /// observedGeneration is Eviction's .metadata.generation observed by the evictionrequest-controller. The observed generation value cannot be negative and can only be incremented. The minimum value is 1. This field is managed by evictionrequest-controller.
    observedGeneration: ?i64 = null,
    /// requesters allow you to identify the entities, that requested the eviction of the target. If all the requesters withdraw their eviction intent, the eviction will be canceled.
    requesters: ?[]const LifecycleV1alpha1Requester = null,
    /// responders represents the eviction process status of each declared responder.
    responders: ?[]const LifecycleV1alpha1ResponderStatus = null,
    /// targetResponders reference responders that should eventually respond to this eviction to help with the graceful eviction of a target. These responders are selected sequentially, according to their specified priority by setting the Active state to the TargetResponder .state field. The maximum number of active responders allowed is 1. Eventually each responder can end up in an Interrupted, Canceled or, Completed state. Responders should observe these states in order to navigate their lifecycle.
    targetResponders: ?[]const LifecycleV1alpha1TargetResponder = null,
};

/// EvictionTarget contains a reference to an object that should be evicted.
pub const LifecycleV1alpha1EvictionTarget = struct {
    /// pod references a pod that is subject to eviction/termination. Pods that are part of a PodGroup (.spec.schedulingGroup is set) are not supported.
    pod: ?LifecycleV1alpha1EvictionPodReference = null,
};

/// Requester allows you to identify the entity, that requested the eviction of the target.
pub const LifecycleV1alpha1Requester = struct {
    /// intent specifies the action that should be taken for the specified target.
    intent: []const u8,
    /// name allows you to identify the entity, that requested the eviction of the target.
    name: []const u8,
};

/// ResponderStatus represents the last observed status of the eviction process of the responder. It should be only updated by the designated responder whose name is .name field.
pub const LifecycleV1alpha1ResponderStatus = struct {
    /// completionTime tracks the time at which the Responder stopped processing the eviction request. Completion means that the responders has either fully or partially completed the eviction process, which may have resulted in target eviction (e.g. pod termination). It should reflect the present time when set. This field becomes immutable once set.
    completionTime: ?meta_v1.MetaV1Time = null,
    /// expectedCompletionTime is the time at which the eviction process step is expected to end for the responder. The time cannot be set to the past. May be omitted if no estimate can be made.
    expectedCompletionTime: ?meta_v1.MetaV1Time = null,
    /// heartbeatTime is the last time at which the eviction process was reported to be in progress by the responder. It should reflect the present time when set. Responders should avoid heartbeats more frequent than 20 seconds to avoid overloading the control-plane.
    heartbeatTime: ?meta_v1.MetaV1Time = null,
    /// message provides human-readable details about the state of the responder and the eviction process. Maximum length is 4000 characters.
    message: ?[]const u8 = null,
    /// name allows you to identify the responder reacting to the Eviction.
    name: []const u8,
    /// startTime tracks the time at which this responder was designated as active and should start processing the eviction request. It should reflect the present time when set. This field is initialized by Kubernetes when this responder becomes active. This field becomes immutable once set.
    startTime: ?meta_v1.MetaV1Time = null,
};

/// TargetResponder allows you to specify the responder reacting to the Eviction. Responders should observe and communicate through the Eviction API (see .state) to help with the graceful eviction of a target (e.g. termination of a pod).
pub const LifecycleV1alpha1TargetResponder = struct {
    /// name allows you to identify the responder reacting to the Eviction.
    name: []const u8,
    /// priority for this responder. Higher priorities are selected first by the evictionrequest-controller. If there are responders with the same priority, the responder whose domain name comes first in the alphabetical higher domain order, will be picked. This means that the top domain labels are compared alphabetically first, followed by the lower domain labels. The key is compared last.
    priority: i32,
    /// state specifies a state that is assigned by the evictionrequest-controller. Responders should observe this state in order to navigate their lifecycle. - Inactive means that the responder should not yet process this eviction request. - Active means that the responder is either running or expected to start soon.
    state: []const u8,
};
