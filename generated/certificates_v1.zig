// Auto-generated from Kubernetes OpenAPI spec.
// Do not edit manually. Regenerate with: zig build generate

const std = @import("std");
const json = std.json;
const meta_v1 = @import("meta_v1.zig");

pub const ByteString = struct {
    base64: []const u8,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: json.ParseOptions) !@This() {
        switch (try source.nextAlloc(allocator, options.allocate orelse .alloc_if_needed)) {
            inline .string, .allocated_string => |s| return .{ .base64 = s },
            else => return error.UnexpectedToken,
        }
    }

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.write(self.base64);
    }

    pub fn decode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        const size = std.base64.standard.Decoder.calcSizeForSlice(self.base64) catch return error.InvalidBase64;
        const buf = try allocator.alloc(u8, size);
        errdefer allocator.free(buf);
        std.base64.standard.Decoder.decode(buf, self.base64) catch return error.InvalidBase64;
        return buf;
    }
};

/// CertificateSigningRequest objects provide a mechanism to obtain x509 certificates by submitting a certificate signing request, and having it asynchronously approved and issued.
pub const CertificatesV1CertificateSigningRequest = struct {
    pub const resource_meta = .{
        .group = "certificates.k8s.io",
        .version = "v1",
        .kind = "CertificateSigningRequest",
        .resource = "certificatesigningrequests",
        .namespaced = false,
        .list_kind = CertificatesV1CertificateSigningRequestList,
    };

    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// spec contains the certificate request, and is immutable after creation. Only the request, signerName, expirationSeconds, and usages fields can be set on creation. Other fields are derived by Kubernetes and cannot be modified by users.
    spec: CertificatesV1CertificateSigningRequestSpec,
    /// status contains information about whether the request is approved or denied, and the certificate issued by the signer, or the failure condition indicating signer failure.
    status: ?CertificatesV1CertificateSigningRequestStatus = null,
};

/// CertificateSigningRequestCondition describes a condition of a CertificateSigningRequest object
pub const CertificatesV1CertificateSigningRequestCondition = struct {
    /// lastTransitionTime is the time the condition last transitioned from one status to another. If unset, when a new condition type is added or an existing condition's status is changed, the server defaults this to the current time.
    lastTransitionTime: ?meta_v1.MetaV1Time = null,
    /// lastUpdateTime is the time of the last update to this condition
    lastUpdateTime: ?meta_v1.MetaV1Time = null,
    /// message contains a human readable message with details about the request state
    message: ?[]const u8 = null,
    /// reason indicates a brief reason for the request state
    reason: ?[]const u8 = null,
    /// status of the condition, one of True, False, Unknown. Approved, Denied, and Failed conditions may not be "False" or "Unknown".
    status: []const u8,
    /// type of the condition. Known conditions are "Approved", "Denied", and "Failed".
    type: []const u8,
};

/// CertificateSigningRequestList is a collection of CertificateSigningRequest objects
pub const CertificatesV1CertificateSigningRequestList = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// items is a collection of CertificateSigningRequest objects
    items: []const CertificatesV1CertificateSigningRequest,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    metadata: ?meta_v1.MetaV1ListMeta = null,
};

/// CertificateSigningRequestSpec contains the certificate request.
pub const CertificatesV1CertificateSigningRequestSpec = struct {
    /// expirationSeconds is the requested duration of validity of the issued certificate. The certificate signer may issue a certificate with a different validity duration so a client must check the delta between the notBefore and and notAfter fields in the issued certificate to determine the actual duration.
    expirationSeconds: ?i32 = null,
    /// extra contains extra attributes of the user that created the CertificateSigningRequest. Populated by the API server on creation and immutable.
    extra: ?json.ArrayHashMap([]const []const u8) = null,
    /// groups contains group membership of the user that created the CertificateSigningRequest. Populated by the API server on creation and immutable.
    groups: ?[]const []const u8 = null,
    /// request contains an x509 certificate signing request encoded in a "CERTIFICATE REQUEST" PEM block. When serialized as JSON or YAML, the data is additionally base64-encoded.
    request: ByteString,
    /// signerName indicates the requested signer, and is a qualified name.
    signerName: []const u8,
    /// uid contains the uid of the user that created the CertificateSigningRequest. Populated by the API server on creation and immutable.
    uid: ?[]const u8 = null,
    /// usages specifies a set of key usages requested in the issued certificate.
    usages: ?[]const []const u8 = null,
    /// username contains the name of the user that created the CertificateSigningRequest. Populated by the API server on creation and immutable.
    username: ?[]const u8 = null,
};

/// CertificateSigningRequestStatus contains conditions used to indicate approved/denied/failed status of the request, and the issued certificate.
pub const CertificatesV1CertificateSigningRequestStatus = struct {
    /// certificate is populated with an issued certificate by the signer after an Approved condition is present. This field is set via the /status subresource. Once populated, this field is immutable.
    certificate: ?ByteString = null,
    /// conditions applied to the request. Known conditions are "Approved", "Denied", and "Failed".
    conditions: ?[]const CertificatesV1CertificateSigningRequestCondition = null,
};

/// ClusterTrustBundle is a cluster-scoped container for X.509 trust anchors (root certificates).
pub const CertificatesV1ClusterTrustBundle = struct {
    pub const resource_meta = .{
        .group = "certificates.k8s.io",
        .version = "v1",
        .kind = "ClusterTrustBundle",
        .resource = "clustertrustbundles",
        .namespaced = false,
        .list_kind = CertificatesV1ClusterTrustBundleList,
    };

    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// metadata contains the object metadata.
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// spec contains the signer (if any) and trust anchors.
    spec: CertificatesV1ClusterTrustBundleSpec,
};

/// ClusterTrustBundleList is a collection of ClusterTrustBundle objects
pub const CertificatesV1ClusterTrustBundleList = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// items is a collection of ClusterTrustBundle objects
    items: []const CertificatesV1ClusterTrustBundle,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// metadata contains the list metadata.
    metadata: ?meta_v1.MetaV1ListMeta = null,
};

/// ClusterTrustBundleSpec contains the signer and trust anchors.
pub const CertificatesV1ClusterTrustBundleSpec = struct {
    /// signerName indicates the associated signer, if any.
    signerName: ?[]const u8 = null,
    /// trustBundle contains the individual X.509 trust anchors for this bundle, as PEM bundle of PEM-wrapped, DER-formatted X.509 certificates.
    trustBundle: []const u8,
};

/// PodCertificateRequest encodes a pod requesting a certificate from a given signer.
pub const CertificatesV1PodCertificateRequest = struct {
    pub const resource_meta = .{
        .group = "certificates.k8s.io",
        .version = "v1",
        .kind = "PodCertificateRequest",
        .resource = "podcertificaterequests",
        .namespaced = true,
        .list_kind = CertificatesV1PodCertificateRequestList,
    };

    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// metadata contains the object metadata.
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// spec contains the details about the certificate being requested.
    spec: CertificatesV1PodCertificateRequestSpec,
    /// status contains the issued certificate, and a standard set of conditions.
    status: ?CertificatesV1PodCertificateRequestStatus = null,
};

/// PodCertificateRequestList is a collection of PodCertificateRequest objects
pub const CertificatesV1PodCertificateRequestList = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// items is a collection of PodCertificateRequest objects
    items: []const CertificatesV1PodCertificateRequest,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// metadata contains the list metadata.
    metadata: ?meta_v1.MetaV1ListMeta = null,
};

/// PodCertificateRequestSpec describes the certificate request.  All fields are immutable after creation.
pub const CertificatesV1PodCertificateRequestSpec = struct {
    /// maxExpirationSeconds is the maximum lifetime permitted for the certificate.
    maxExpirationSeconds: ?i32 = null,
    /// nodeName is the name of the node the pod is assigned to.
    nodeName: []const u8,
    /// nodeUID is the UID of the node the pod is assigned to.
    nodeUID: []const u8,
    /// podName is the name of the pod into which the certificate will be mounted.
    podName: []const u8,
    /// podUID is the UID of the pod into which the certificate will be mounted.
    podUID: []const u8,
    /// serviceAccountName is the name of the service account the pod is running as.
    serviceAccountName: []const u8,
    /// serviceAccountUID is the UID of the service account the pod is running as.
    serviceAccountUID: []const u8,
    /// signerName indicates the requested signer.
    signerName: []const u8,
    /// A PKCS#10 certificate signing request (DER-serialized) generated by Kubelet using the subject private key.
    stubPKCS10Request: ByteString,
    /// unverifiedUserAnnotations allow pod authors to pass additional information to the signer implementation.  Kubernetes does not restrict or validate this metadata in any way.
    unverifiedUserAnnotations: ?json.ArrayHashMap([]const u8) = null,
};

/// PodCertificateRequestStatus describes the status of the request, and holds the certificate data if the request is issued.
pub const CertificatesV1PodCertificateRequestStatus = struct {
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
