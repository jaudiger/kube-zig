// Auto-generated from Kubernetes OpenAPI spec.
// Do not edit manually. Regenerate with: zig build generate

const std = @import("std");
const json = std.json;
const meta_v1 = @import("meta_v1.zig");

/// IPAddress represents a single IP of a single IP Family. The object is designed to be used by APIs that operate on IP addresses. The object is used by the Service core API for allocation of IP addresses. An IP address can be represented in different formats, to guarantee the uniqueness of the IP, the name of the object is the IP address in canonical format, four decimal digits separated by dots suppressing leading zeros for IPv4 and the representation defined by RFC 5952 for IPv6. Valid: 192.168.1.5 or 2001:db8::1 or 2001:db8:aaaa:bbbb:cccc:dddd:eeee:1 Invalid: 10.01.2.3 or 2001:db8:0:0:0::1
pub const NetworkingV1beta1IPAddress = struct {
    pub const resource_meta = .{
        .group = "networking.k8s.io",
        .version = "v1beta1",
        .kind = "IPAddress",
        .resource = "ipaddresses",
        .namespaced = false,
        .list_kind = NetworkingV1beta1IPAddressList,
    };

    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard object's metadata. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// spec is the desired state of the IPAddress. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#spec-and-status
    spec: ?NetworkingV1beta1IPAddressSpec = null,
};

/// IPAddressList contains a list of IPAddress.
pub const NetworkingV1beta1IPAddressList = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// items is the list of IPAddresses.
    items: []const NetworkingV1beta1IPAddress,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard object's metadata. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata
    metadata: ?meta_v1.MetaV1ListMeta = null,
};

/// IPAddressSpec describe the attributes in an IP Address.
pub const NetworkingV1beta1IPAddressSpec = struct {
    /// ParentRef references the resource that an IPAddress is attached to. An IPAddress must reference a parent object.
    parentRef: NetworkingV1beta1ParentReference,
};

/// ParentReference describes a reference to a parent object.
pub const NetworkingV1beta1ParentReference = struct {
    /// Group is the group of the object being referenced.
    group: ?[]const u8 = null,
    /// Name is the name of the object being referenced.
    name: []const u8,
    /// Namespace is the namespace of the object being referenced.
    namespace: ?[]const u8 = null,
    /// Resource is the resource of the object being referenced.
    resource: []const u8,
};

/// ServiceCIDR defines a range of IP addresses using CIDR format (e.g. 192.168.0.0/24 or 2001:db2::/64). This range is used to allocate ClusterIPs to Service objects.
pub const NetworkingV1beta1ServiceCIDR = struct {
    pub const resource_meta = .{
        .group = "networking.k8s.io",
        .version = "v1beta1",
        .kind = "ServiceCIDR",
        .resource = "servicecidrs",
        .namespaced = false,
        .list_kind = NetworkingV1beta1ServiceCIDRList,
    };

    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard object's metadata. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// spec is the desired state of the ServiceCIDR. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#spec-and-status
    spec: ?NetworkingV1beta1ServiceCIDRSpec = null,
    /// status represents the current state of the ServiceCIDR. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#spec-and-status
    status: ?NetworkingV1beta1ServiceCIDRStatus = null,
};

/// ServiceCIDRList contains a list of ServiceCIDR objects.
pub const NetworkingV1beta1ServiceCIDRList = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// items is the list of ServiceCIDRs.
    items: []const NetworkingV1beta1ServiceCIDR,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard object's metadata. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata
    metadata: ?meta_v1.MetaV1ListMeta = null,
};

/// ServiceCIDRSpec define the CIDRs the user wants to use for allocating ClusterIPs for Services.
pub const NetworkingV1beta1ServiceCIDRSpec = struct {
    /// CIDRs defines the IP blocks in CIDR notation (e.g. "192.168.0.0/24" or "2001:db8::/64") from which to assign service cluster IPs. Max of two CIDRs is allowed, one of each IP family. This field is immutable.
    cidrs: ?[]const []const u8 = null,
};

/// ServiceCIDRStatus describes the current state of the ServiceCIDR.
pub const NetworkingV1beta1ServiceCIDRStatus = struct {
    /// conditions holds an array of metav1.Condition that describe the state of the ServiceCIDR. Current service state
    conditions: ?[]const meta_v1.MetaV1Condition = null,
};
