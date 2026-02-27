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
    /// TimeAdded represents the time at which the taint was added. Added automatically during create or update if not set.
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
