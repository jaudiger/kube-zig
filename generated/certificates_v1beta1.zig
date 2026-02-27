// Auto-generated from Kubernetes OpenAPI spec.
// Do not edit manually. Regenerate with: zig build generate

const std = @import("std");
const json = std.json;
const meta_v1 = @import("meta_v1.zig");

/// ClusterTrustBundle is a cluster-scoped container for X.509 trust anchors (root certificates).
pub const CertificatesV1beta1ClusterTrustBundle = struct {
    pub const resource_meta = .{
        .group = "certificates.k8s.io",
        .version = "v1beta1",
        .kind = "ClusterTrustBundle",
        .resource = "clustertrustbundles",
        .namespaced = false,
        .list_kind = CertificatesV1beta1ClusterTrustBundleList,
    };

    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// metadata contains the object metadata.
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// spec contains the signer (if any) and trust anchors.
    spec: CertificatesV1beta1ClusterTrustBundleSpec,
};

/// ClusterTrustBundleList is a collection of ClusterTrustBundle objects
pub const CertificatesV1beta1ClusterTrustBundleList = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// items is a collection of ClusterTrustBundle objects
    items: []const CertificatesV1beta1ClusterTrustBundle,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// metadata contains the list metadata.
    metadata: ?meta_v1.MetaV1ListMeta = null,
};

/// ClusterTrustBundleSpec contains the signer and trust anchors.
pub const CertificatesV1beta1ClusterTrustBundleSpec = struct {
    /// signerName indicates the associated signer, if any.
    signerName: ?[]const u8 = null,
    /// trustBundle contains the individual X.509 trust anchors for this bundle, as PEM bundle of PEM-wrapped, DER-formatted X.509 certificates.
    trustBundle: []const u8,
};

/// PodCertificateRequest encodes a pod requesting a certificate from a given signer.
pub const CertificatesV1beta1PodCertificateRequest = struct {
    pub const resource_meta = .{
        .group = "certificates.k8s.io",
        .version = "v1beta1",
        .kind = "PodCertificateRequest",
        .resource = "podcertificaterequests",
        .namespaced = true,
        .list_kind = CertificatesV1beta1PodCertificateRequestList,
    };

    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// metadata contains the object metadata.
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// spec contains the details about the certificate being requested.
    spec: CertificatesV1beta1PodCertificateRequestSpec,
    /// status contains the issued certificate, and a standard set of conditions.
    status: ?CertificatesV1beta1PodCertificateRequestStatus = null,
};

/// PodCertificateRequestList is a collection of PodCertificateRequest objects
pub const CertificatesV1beta1PodCertificateRequestList = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// items is a collection of PodCertificateRequest objects
    items: []const CertificatesV1beta1PodCertificateRequest,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// metadata contains the list metadata.
    metadata: ?meta_v1.MetaV1ListMeta = null,
};

/// PodCertificateRequestSpec describes the certificate request.  All fields are immutable after creation.
pub const CertificatesV1beta1PodCertificateRequestSpec = struct {
    /// maxExpirationSeconds is the maximum lifetime permitted for the certificate.
    maxExpirationSeconds: ?i32 = null,
    /// nodeName is the name of the node the pod is assigned to.
    nodeName: []const u8,
    /// nodeUID is the UID of the node the pod is assigned to.
    nodeUID: []const u8,
    /// pkixPublicKey is the PKIX-serialized public key the signer will issue the certificate to.
    pkixPublicKey: []const u8,
    /// podName is the name of the pod into which the certificate will be mounted.
    podName: []const u8,
    /// podUID is the UID of the pod into which the certificate will be mounted.
    podUID: []const u8,
    /// proofOfPossession proves that the requesting kubelet holds the private key corresponding to pkixPublicKey.
    proofOfPossession: []const u8,
    /// serviceAccountName is the name of the service account the pod is running as.
    serviceAccountName: []const u8,
    /// serviceAccountUID is the UID of the service account the pod is running as.
    serviceAccountUID: []const u8,
    /// signerName indicates the requested signer.
    signerName: []const u8,
    /// unverifiedUserAnnotations allow pod authors to pass additional information to the signer implementation.  Kubernetes does not restrict or validate this metadata in any way.
    unverifiedUserAnnotations: ?json.ArrayHashMap([]const u8) = null,
};

/// PodCertificateRequestStatus describes the status of the request, and holds the certificate data if the request is issued.
pub const CertificatesV1beta1PodCertificateRequestStatus = struct {
    /// beginRefreshAt is the time at which the kubelet should begin trying to refresh the certificate.  This field is set via the /status subresource, and must be set at the same time as certificateChain.  Once populated, this field is immutable.
    beginRefreshAt: ?meta_v1.MetaV1Time = null,
    /// certificateChain is populated with an issued certificate by the signer. This field is set via the /status subresource. Once populated, this field is immutable.
    certificateChain: ?[]const u8 = null,
    /// conditions applied to the request.
    conditions: ?[]const meta_v1.MetaV1Condition = null,
    /// notAfter is the time at which the certificate expires.  The value must be the same as the notAfter value in the leaf certificate in certificateChain.  This field is set via the /status subresource.  Once populated, it is immutable.  The signer must set this field at the same time it sets certificateChain.
    notAfter: ?meta_v1.MetaV1Time = null,
    /// notBefore is the time at which the certificate becomes valid.  The value must be the same as the notBefore value in the leaf certificate in certificateChain.  This field is set via the /status subresource.  Once populated, it is immutable. The signer must set this field at the same time it sets certificateChain.
    notBefore: ?meta_v1.MetaV1Time = null,
};
