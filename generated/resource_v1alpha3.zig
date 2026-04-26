// Auto-generated from Kubernetes OpenAPI spec.
// Do not edit manually. Regenerate with: zig build generate

const std = @import("std");
const json = std.json;
const meta_v1 = @import("meta_v1.zig");

/// The device this taint is attached to has the "effect" on any claim which does not tolerate the taint and, through the claim, to pods using the claim.
pub const ResourceV1alpha3DeviceTaint = struct {
    /// The effect of the taint on claims that do not tolerate the taint and through such claims on the pods using them.
    effect: []const u8,
    /// The taint key to be applied to a device. Must be a label name.
    key: []const u8,
    /// TimeAdded represents the time at which the taint was added or (only in a DeviceTaintRule) the effect was modified. Added automatically during create or update if not set.
    timeAdded: ?meta_v1.MetaV1Time = null,
    /// The taint value corresponding to the taint key. Must be a label value.
    value: ?[]const u8 = null,
};

/// DeviceTaintRule adds one taint to all devices which match the selector. This has the same effect as if the taint was specified directly in the ResourceSlice by the DRA driver.
pub const ResourceV1alpha3DeviceTaintRule = struct {
    pub const resource_meta = .{
        .group = "resource.k8s.io",
        .version = "v1alpha3",
        .kind = "DeviceTaintRule",
        .resource = "devicetaintrules",
        .namespaced = false,
        .list_kind = ResourceV1alpha3DeviceTaintRuleList,
    };

    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard object metadata
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// Spec specifies the selector and one taint.
    spec: ResourceV1alpha3DeviceTaintRuleSpec,
    /// Status provides information about what was requested in the spec.
    status: ?ResourceV1alpha3DeviceTaintRuleStatus = null,
};

/// DeviceTaintRuleList is a collection of DeviceTaintRules.
pub const ResourceV1alpha3DeviceTaintRuleList = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Items is the list of DeviceTaintRules.
    items: []const ResourceV1alpha3DeviceTaintRule,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard list metadata
    metadata: ?meta_v1.MetaV1ListMeta = null,
};

/// DeviceTaintRuleSpec specifies the selector and one taint.
pub const ResourceV1alpha3DeviceTaintRuleSpec = struct {
    /// DeviceSelector defines which device(s) the taint is applied to. All selector criteria must be satisfied for a device to match. The empty selector matches all devices. Without a selector, no devices are matches.
    deviceSelector: ?ResourceV1alpha3DeviceTaintSelector = null,
    /// The taint that gets applied to matching devices.
    taint: ResourceV1alpha3DeviceTaint,
};

/// DeviceTaintRuleStatus provides information about an on-going pod eviction.
pub const ResourceV1alpha3DeviceTaintRuleStatus = struct {
    /// Conditions provide information about the state of the DeviceTaintRule and the cluster at some point in time, in a machine-readable and human-readable format.
    conditions: ?[]const meta_v1.MetaV1Condition = null,
};

/// DeviceTaintSelector defines which device(s) a DeviceTaintRule applies to. The empty selector matches all devices. Without a selector, no devices are matched.
pub const ResourceV1alpha3DeviceTaintSelector = struct {
    /// If device is set, only devices with that name are selected. This field corresponds to slice.spec.devices[].name.
    device: ?[]const u8 = null,
    /// If driver is set, only devices from that driver are selected. This fields corresponds to slice.spec.driver.
    driver: ?[]const u8 = null,
    /// If pool is set, only devices in that pool are selected.
    pool: ?[]const u8 = null,
};

/// PoolStatus contains status information for a single resource pool.
pub const ResourceV1alpha3PoolStatus = struct {
    /// AllocatedDevices is the number of devices currently allocated to claims. A value of 0 means no devices are allocated. May be unset when validationError is set.
    allocatedDevices: ?i32 = null,
    /// AvailableDevices is the number of devices available for allocation. This equals TotalDevices - AllocatedDevices - UnavailableDevices. A value of 0 means no devices are currently available. May be unset when validationError is set.
    availableDevices: ?i32 = null,
    /// Driver is the DRA driver name for this pool. Must be a DNS subdomain (e.g., "gpu.example.com").
    driver: []const u8,
    /// Generation is the pool generation observed across all ResourceSlices in this pool. Only the latest generation is reported. During a generation rollout, if not all slices at the latest generation have been published, the pool is included with a validationError and device counts unset.
    generation: i64,
    /// NodeName is the node this pool is associated with. When omitted, the pool is not associated with a specific node. Must be a valid DNS subdomain name (RFC1123).
    nodeName: ?[]const u8 = null,
    /// PoolName is the name of the pool. Must be a valid resource pool name (DNS subdomains separated by "/").
    poolName: []const u8,
    /// ResourceSliceCount is the number of ResourceSlices that make up this pool. May be unset when validationError is set.
    resourceSliceCount: ?i32 = null,
    /// TotalDevices is the total number of devices in the pool across all slices. A value of 0 means the pool has no devices. May be unset when validationError is set.
    totalDevices: ?i32 = null,
    /// UnavailableDevices is the number of devices that are not available due to taints or other conditions, but are not allocated. A value of 0 means all unallocated devices are available. May be unset when validationError is set.
    unavailableDevices: ?i32 = null,
    /// ValidationError is set when the pool's data could not be fully validated (e.g., incomplete slice publication). When set, device count fields and ResourceSliceCount may be unset.
    validationError: ?[]const u8 = null,
};

/// ResourcePoolStatusRequest triggers a one-time calculation of resource pool status based on the provided filters. Once status is set, the request is considered complete and will not be reprocessed. Users should delete and recreate requests to get updated information.
pub const ResourceV1alpha3ResourcePoolStatusRequest = struct {
    pub const resource_meta = .{
        .group = "resource.k8s.io",
        .version = "v1alpha3",
        .kind = "ResourcePoolStatusRequest",
        .resource = "resourcepoolstatusrequests",
        .namespaced = false,
        .list_kind = ResourceV1alpha3ResourcePoolStatusRequestList,
    };

    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard object metadata
    metadata: meta_v1.MetaV1ObjectMeta,
    /// Spec defines the filters for which pools to include in the status. The spec is immutable once created.
    spec: ResourceV1alpha3ResourcePoolStatusRequestSpec,
    /// Status is populated by the controller with the calculated pool status. When status is non-nil, the request is considered complete and the entire object becomes immutable.
    status: ?ResourceV1alpha3ResourcePoolStatusRequestStatus = null,
};

/// ResourcePoolStatusRequestList is a collection of ResourcePoolStatusRequests.
pub const ResourceV1alpha3ResourcePoolStatusRequestList = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Items is the list of ResourcePoolStatusRequests.
    items: []const ResourceV1alpha3ResourcePoolStatusRequest,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard list metadata
    metadata: ?meta_v1.MetaV1ListMeta = null,
};

/// ResourcePoolStatusRequestSpec defines the filters for the pool status request.
pub const ResourceV1alpha3ResourcePoolStatusRequestSpec = struct {
    /// Driver specifies the DRA driver name to filter pools. Only pools from ResourceSlices with this driver will be included. Must be a DNS subdomain (e.g., "gpu.example.com").
    driver: []const u8,
    /// Limit optionally specifies the maximum number of pools to return in the status. If more pools match the filter criteria, the response will be truncated (i.e., len(status.pools) < status.poolCount).
    limit: ?i32 = null,
    /// PoolName optionally filters to a specific pool name. If not specified, all pools from the specified driver are included. When specified, must be a non-empty valid resource pool name (DNS subdomains separated by "/").
    poolName: ?[]const u8 = null,
};

/// ResourcePoolStatusRequestStatus contains the calculated pool status information.
pub const ResourceV1alpha3ResourcePoolStatusRequestStatus = struct {
    /// Conditions provide information about the state of the request. A condition with type=Complete or type=Failed will always be set when the status is populated.
    conditions: ?[]const meta_v1.MetaV1Condition = null,
    /// PoolCount is the total number of pools that matched the filter criteria, regardless of truncation. This helps users understand how many pools exist even when the response is truncated. A value of 0 means no pools matched the filter criteria.
    poolCount: i32,
    /// Pools contains the first `spec.limit` matching pools, sorted by driver then pool name. If `len(pools) < poolCount`, the list was truncated. When omitted, no pools matched the request filters.
    pools: ?[]const ResourceV1alpha3PoolStatus = null,
};
