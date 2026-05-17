// Auto-generated from Kubernetes OpenAPI spec.
// Do not edit manually. Regenerate with: zig build generate

const std = @import("std");
const json = std.json;
const meta_v1 = @import("meta_v1.zig");

/// LeaseCandidate defines a candidate for a Lease object. Candidates are created such that coordinated leader election will pick the best leader from the list of candidates.
pub const CoordinationV1alpha2LeaseCandidate = struct {
    pub const resource_meta = .{
        .group = "coordination.k8s.io",
        .version = "v1alpha2",
        .kind = "LeaseCandidate",
        .resource = "leasecandidates",
        .namespaced = true,
        .list_kind = CoordinationV1alpha2LeaseCandidateList,
    };

    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// spec contains the specification of the Lease. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#spec-and-status
    spec: CoordinationV1alpha2LeaseCandidateSpec,
};

/// LeaseCandidateList is a list of Lease objects.
pub const CoordinationV1alpha2LeaseCandidateList = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// items is a list of schema objects.
    items: []const CoordinationV1alpha2LeaseCandidate,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard list metadata. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata
    metadata: ?meta_v1.MetaV1ListMeta = null,
};

/// LeaseCandidateSpec is a specification of a Lease.
pub const CoordinationV1alpha2LeaseCandidateSpec = struct {
    /// BinaryVersion is the binary version. It must be in a semver format without leading `v`. This field is required.
    binaryVersion: []const u8,
    /// EmulationVersion is the emulation version. It must be in a semver format without leading `v`. EmulationVersion must be less than or equal to BinaryVersion. This field is required when strategy is "OldestEmulationVersion"
    emulationVersion: ?[]const u8 = null,
    /// LeaseName is the name of the lease for which this candidate is contending. This field is immutable.
    leaseName: []const u8,
    /// PingTime is the last time that the server has requested the LeaseCandidate to renew. It is only done during leader election to check if any LeaseCandidates have become ineligible. When PingTime is updated, the LeaseCandidate will respond by updating RenewTime.
    pingTime: ?meta_v1.MetaV1MicroTime = null,
    /// RenewTime is the time that the LeaseCandidate was last updated. Any time a Lease needs to do leader election, the PingTime field is updated to signal to the LeaseCandidate that they should update the RenewTime. Old LeaseCandidate objects are also garbage collected if it has been hours since the last renew. The PingTime field is updated regularly to prevent garbage collection for still active LeaseCandidates.
    renewTime: ?meta_v1.MetaV1MicroTime = null,
    /// Strategy is the strategy that coordinated leader election will use for picking the leader. If multiple candidates for the same Lease return different strategies, the strategy provided by the candidate with the latest BinaryVersion will be used. If there is still conflict, this is a user error and coordinated leader election will not operate the Lease until resolved.
    strategy: []const u8,
};
