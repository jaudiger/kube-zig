// Auto-generated from Kubernetes OpenAPI spec.
// Do not edit manually. Regenerate with: zig build generate

const std = @import("std");
const json = std.json;
const meta_v1 = @import("meta_v1.zig");

/// APIService represents a server for a particular GroupVersion. Name must be "version.group".
pub const ApiregistrationV1APIService = struct {
    pub const resource_meta = .{
        .group = "apiregistration.k8s.io",
        .version = "v1",
        .kind = "APIService",
        .resource = "apiservices",
        .namespaced = false,
        .list_kind = ApiregistrationV1APIServiceList,
    };

    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard object's metadata. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// Spec contains information for locating and communicating with a server
    spec: ?ApiregistrationV1APIServiceSpec = null,
    /// Status contains derived information about an API server
    status: ?ApiregistrationV1APIServiceStatus = null,
};

/// APIServiceCondition describes the state of an APIService at a particular point
pub const ApiregistrationV1APIServiceCondition = struct {
    /// Last time the condition transitioned from one status to another.
    lastTransitionTime: ?meta_v1.MetaV1Time = null,
    /// Human-readable message indicating details about last transition.
    message: ?[]const u8 = null,
    /// Unique, one-word, CamelCase reason for the condition's last transition.
    reason: ?[]const u8 = null,
    /// Status is the status of the condition. Can be True, False, Unknown.
    status: []const u8,
    /// Type is the type of the condition.
    type: []const u8,
};

/// APIServiceList is a list of APIService objects.
pub const ApiregistrationV1APIServiceList = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Items is the list of APIService
    items: []const ApiregistrationV1APIService,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard list metadata More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata
    metadata: ?meta_v1.MetaV1ListMeta = null,
};

/// APIServiceSpec contains information for locating and communicating with a server. Only https is supported, though you are able to disable certificate verification.
pub const ApiregistrationV1APIServiceSpec = struct {
    /// CABundle is a PEM encoded CA bundle which will be used to validate an API server's serving certificate. If unspecified, system trust roots on the apiserver are used.
    caBundle: ?[]const u8 = null,
    /// Group is the API group name this server hosts
    group: ?[]const u8 = null,
    /// GroupPriorityMinimum is the priority this group should have at least. Higher priority means that the group is preferred by clients over lower priority ones. Note that other versions of this group might specify even higher GroupPriorityMinimum values such that the whole group gets a higher priority. The primary sort is based on GroupPriorityMinimum, ordered highest number to lowest (20 before 10). The secondary sort is based on the alphabetical comparison of the name of the object.  (v1.bar before v1.foo) We'd recommend something like: *.k8s.io (except extensions) at 18000 and PaaSes (OpenShift, Deis) are recommended to be in the 2000s
    groupPriorityMinimum: i32,
    /// InsecureSkipTLSVerify disables TLS certificate verification when communicating with this server. This is strongly discouraged.  You should use the CABundle instead.
    insecureSkipTLSVerify: ?bool = null,
    /// Service is a reference to the service for this API server.  It must communicate on port 443. If the Service is nil, that means the handling for the API groupversion is handled locally on this server. The call will simply delegate to the normal handler chain to be fulfilled.
    service: ?ApiregistrationV1ServiceReference = null,
    /// Version is the API version this server hosts.  For example, "v1"
    version: ?[]const u8 = null,
    /// VersionPriority controls the ordering of this API version inside of its group.  Must be greater than zero. The primary sort is based on VersionPriority, ordered highest to lowest (20 before 10). Since it's inside of a group, the number can be small, probably in the 10s. In case of equal version priorities, the version string will be used to compute the order inside a group. If the version string is "kube-like", it will sort above non "kube-like" version strings, which are ordered lexicographically. "Kube-like" versions start with a "v", then are followed by a number (the major version), then optionally the string "alpha" or "beta" and another number (the minor version). These are sorted first by GA > beta > alpha (where GA is a version with no suffix such as beta or alpha), and then by comparing major version, then minor version. An example sorted list of versions: v10, v2, v1, v11beta2, v10beta3, v3beta1, v12alpha1, v11alpha2, foo1, foo10.
    versionPriority: i32,
};

/// APIServiceStatus contains derived information about an API server
pub const ApiregistrationV1APIServiceStatus = struct {
    /// Current service state of apiService.
    conditions: ?[]const ApiregistrationV1APIServiceCondition = null,
};

/// ServiceReference holds a reference to Service.legacy.k8s.io
pub const ApiregistrationV1ServiceReference = struct {
    /// Name is the name of the service
    name: ?[]const u8 = null,
    /// Namespace is the namespace of the service
    namespace: ?[]const u8 = null,
    /// If specified, the port on the service that hosting webhook. Default to 443 for backward compatibility. `port` should be a valid port number (1-65535, inclusive).
    port: ?i32 = null,
};
