// Auto-generated from Kubernetes OpenAPI spec.
// Do not edit manually. Regenerate with: zig build generate

const std = @import("std");
const json = std.json;
const meta_v1 = @import("meta_v1.zig");

/// An API server instance reports the version it can decode and the version it encodes objects to when persisting objects in the backend.
pub const ApiserverinternalV1alpha1ServerStorageVersion = struct {
    /// The ID of the reporting API server.
    apiServerID: ?[]const u8 = null,
    /// The API server can decode objects encoded in these versions. The encodingVersion must be included in the decodableVersions.
    decodableVersions: ?[]const []const u8 = null,
    /// The API server encodes the object to this version when persisting it in the backend (e.g., etcd).
    encodingVersion: ?[]const u8 = null,
    /// The API server can serve these versions. DecodableVersions must include all ServedVersions.
    servedVersions: ?[]const []const u8 = null,
};

/// Storage version of a specific resource.
pub const ApiserverinternalV1alpha1StorageVersion = struct {
    pub const resource_meta = .{
        .group = "internal.apiserver.k8s.io",
        .version = "v1alpha1",
        .kind = "StorageVersion",
        .resource = "storageversions",
        .namespaced = false,
        .list_kind = ApiserverinternalV1alpha1StorageVersionList,
    };

    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// The name is <group>.<resource>.
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// Spec is an empty spec. It is here to comply with Kubernetes API style.
    spec: ApiserverinternalV1alpha1StorageVersionSpec,
    /// API server instances report the version they can decode and the version they encode objects to when persisting objects in the backend.
    status: ApiserverinternalV1alpha1StorageVersionStatus,
};

/// Describes the state of the storageVersion at a certain point.
pub const ApiserverinternalV1alpha1StorageVersionCondition = struct {
    /// Last time the condition transitioned from one status to another.
    lastTransitionTime: ?meta_v1.MetaV1Time = null,
    /// A human readable message indicating details about the transition.
    message: []const u8,
    /// If set, this represents the .metadata.generation that the condition was set based upon.
    observedGeneration: ?i64 = null,
    /// The reason for the condition's last transition.
    reason: []const u8,
    /// Status of the condition, one of True, False, Unknown.
    status: []const u8,
    /// Type of the condition.
    type: []const u8,
};

/// A list of StorageVersions.
pub const ApiserverinternalV1alpha1StorageVersionList = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Items holds a list of StorageVersion
    items: []const ApiserverinternalV1alpha1StorageVersion,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard list metadata. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata
    metadata: ?meta_v1.MetaV1ListMeta = null,
};

/// StorageVersionSpec is an empty spec.
pub const ApiserverinternalV1alpha1StorageVersionSpec = std.json.Value;

/// API server instances report the versions they can decode and the version they encode objects to when persisting objects in the backend.
pub const ApiserverinternalV1alpha1StorageVersionStatus = struct {
    /// If all API server instances agree on the same encoding storage version, then this field is set to that version. Otherwise this field is left empty. API servers should finish updating its storageVersionStatus entry before serving write operations, so that this field will be in sync with the reality.
    commonEncodingVersion: ?[]const u8 = null,
    /// The latest available observations of the storageVersion's state.
    conditions: ?[]const ApiserverinternalV1alpha1StorageVersionCondition = null,
    /// The reported versions per API server instance.
    storageVersions: ?[]const ApiserverinternalV1alpha1ServerStorageVersion = null,
};
