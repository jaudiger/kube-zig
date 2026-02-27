// Auto-generated from Kubernetes OpenAPI spec.
// Do not edit manually. Regenerate with: zig build generate

const std = @import("std");
const json = std.json;
const meta_v1 = @import("meta_v1.zig");

/// ClusterTrustBundle is a cluster-scoped container for X.509 trust anchors (root certificates).
pub const CertificatesV1alpha1ClusterTrustBundle = struct {
    pub const resource_meta = .{
        .group = "certificates.k8s.io",
        .version = "v1alpha1",
        .kind = "ClusterTrustBundle",
        .resource = "clustertrustbundles",
        .namespaced = false,
        .list_kind = CertificatesV1alpha1ClusterTrustBundleList,
    };

    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// metadata contains the object metadata.
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// spec contains the signer (if any) and trust anchors.
    spec: CertificatesV1alpha1ClusterTrustBundleSpec,
};

/// ClusterTrustBundleList is a collection of ClusterTrustBundle objects
pub const CertificatesV1alpha1ClusterTrustBundleList = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// items is a collection of ClusterTrustBundle objects
    items: []const CertificatesV1alpha1ClusterTrustBundle,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// metadata contains the list metadata.
    metadata: ?meta_v1.MetaV1ListMeta = null,
};

/// ClusterTrustBundleSpec contains the signer and trust anchors.
pub const CertificatesV1alpha1ClusterTrustBundleSpec = struct {
    /// signerName indicates the associated signer, if any.
    signerName: ?[]const u8 = null,
    /// trustBundle contains the individual X.509 trust anchors for this bundle, as PEM bundle of PEM-wrapped, DER-formatted X.509 certificates.
    trustBundle: []const u8,
};
