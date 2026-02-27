// Auto-generated from Kubernetes OpenAPI spec.
// Do not edit manually. Regenerate with: zig build generate

const std = @import("std");
const json = std.json;
const meta_v1 = @import("meta_v1.zig");

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
    request: []const u8,
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
    certificate: ?[]const u8 = null,
    /// conditions applied to the request. Known conditions are "Approved", "Denied", and "Failed".
    conditions: ?[]const CertificatesV1CertificateSigningRequestCondition = null,
};
