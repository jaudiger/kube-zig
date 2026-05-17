// Auto-generated from Kubernetes OpenAPI spec.
// Do not edit manually. Regenerate with: zig build generate

const std = @import("std");
const json = std.json;
const meta_v1 = @import("meta_v1.zig");

/// AggregationRule describes how to locate ClusterRoles to aggregate into the ClusterRole
pub const RbacV1AggregationRule = struct {
    /// ClusterRoleSelectors holds a list of selectors which will be used to find ClusterRoles and create the rules. If any of the selectors match, then the ClusterRole's permissions will be added
    clusterRoleSelectors: ?[]const meta_v1.MetaV1LabelSelector = null,
};

/// ClusterRole is a cluster level, logical grouping of PolicyRules that can be referenced as a unit by a RoleBinding or ClusterRoleBinding.
pub const RbacV1ClusterRole = struct {
    pub const resource_meta = .{
        .group = "rbac.authorization.k8s.io",
        .version = "v1",
        .kind = "ClusterRole",
        .resource = "clusterroles",
        .namespaced = false,
        .list_kind = RbacV1ClusterRoleList,
    };

    /// AggregationRule is an optional field that describes how to build the Rules for this ClusterRole. If AggregationRule is set, then the Rules are controller managed and direct changes to Rules will be stomped by the controller.
    aggregationRule: ?RbacV1AggregationRule = null,
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard object's metadata.
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// Rules holds all the PolicyRules for this ClusterRole
    rules: ?[]const RbacV1PolicyRule = null,
};

/// ClusterRoleBinding references a ClusterRole, but not contain it.  It can reference a ClusterRole in the global namespace, and adds who information via Subject.
pub const RbacV1ClusterRoleBinding = struct {
    pub const resource_meta = .{
        .group = "rbac.authorization.k8s.io",
        .version = "v1",
        .kind = "ClusterRoleBinding",
        .resource = "clusterrolebindings",
        .namespaced = false,
        .list_kind = RbacV1ClusterRoleBindingList,
    };

    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard object's metadata.
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// RoleRef can only reference a ClusterRole in the global namespace. If the RoleRef cannot be resolved, the Authorizer must return an error. This field is immutable.
    roleRef: RbacV1RoleRef,
    /// Subjects holds references to the objects the role applies to.
    subjects: ?[]const RbacV1Subject = null,
};

/// ClusterRoleBindingList is a collection of ClusterRoleBindings
pub const RbacV1ClusterRoleBindingList = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Items is a list of ClusterRoleBindings
    items: []const RbacV1ClusterRoleBinding,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard object's metadata.
    metadata: ?meta_v1.MetaV1ListMeta = null,
};

/// ClusterRoleList is a collection of ClusterRoles
pub const RbacV1ClusterRoleList = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Items is a list of ClusterRoles
    items: []const RbacV1ClusterRole,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard object's metadata.
    metadata: ?meta_v1.MetaV1ListMeta = null,
};

/// PolicyRule holds information that describes a policy rule, but does not contain information about who the rule applies to or which namespace the rule applies to.
pub const RbacV1PolicyRule = struct {
    /// APIGroups is the name of the APIGroup that contains the resources.  If multiple API groups are specified, any action requested against one of the enumerated resources in any API group will be allowed. "" represents the core API group and "*" represents all API groups.
    apiGroups: ?[]const []const u8 = null,
    /// NonResourceURLs is a set of partial urls that a user should have access to.  *s are allowed, but only as the full, final step in the path Since non-resource URLs are not namespaced, this field is only applicable for ClusterRoles referenced from a ClusterRoleBinding. Rules can either apply to API resources (such as "pods" or "secrets") or non-resource URL paths (such as "/api"),  but not both.
    nonResourceURLs: ?[]const []const u8 = null,
    /// ResourceNames is an optional white list of names that the rule applies to.  An empty set means that everything is allowed.
    resourceNames: ?[]const []const u8 = null,
    /// Resources is a list of resources this rule applies to. '*' represents all resources.
    resources: ?[]const []const u8 = null,
    /// Verbs is a list of Verbs that apply to ALL the ResourceKinds contained in this rule. '*' represents all verbs.
    verbs: []const []const u8,
};

/// Role is a namespaced, logical grouping of PolicyRules that can be referenced as a unit by a RoleBinding.
pub const RbacV1Role = struct {
    pub const resource_meta = .{
        .group = "rbac.authorization.k8s.io",
        .version = "v1",
        .kind = "Role",
        .resource = "roles",
        .namespaced = true,
        .list_kind = RbacV1RoleList,
    };

    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard object's metadata.
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// Rules holds all the PolicyRules for this Role
    rules: ?[]const RbacV1PolicyRule = null,
};

/// RoleBinding references a role, but does not contain it.  It can reference a Role in the same namespace or a ClusterRole in the global namespace. It adds who information via Subjects and namespace information by which namespace it exists in.  RoleBindings in a given namespace only have effect in that namespace.
pub const RbacV1RoleBinding = struct {
    pub const resource_meta = .{
        .group = "rbac.authorization.k8s.io",
        .version = "v1",
        .kind = "RoleBinding",
        .resource = "rolebindings",
        .namespaced = true,
        .list_kind = RbacV1RoleBindingList,
    };

    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard object's metadata.
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// RoleRef can reference a Role in the current namespace or a ClusterRole in the global namespace. If the RoleRef cannot be resolved, the Authorizer must return an error. This field is immutable.
    roleRef: RbacV1RoleRef,
    /// Subjects holds references to the objects the role applies to.
    subjects: ?[]const RbacV1Subject = null,
};

/// RoleBindingList is a collection of RoleBindings
pub const RbacV1RoleBindingList = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Items is a list of RoleBindings
    items: []const RbacV1RoleBinding,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard object's metadata.
    metadata: ?meta_v1.MetaV1ListMeta = null,
};

/// RoleList is a collection of Roles
pub const RbacV1RoleList = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Items is a list of Roles
    items: []const RbacV1Role,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard object's metadata.
    metadata: ?meta_v1.MetaV1ListMeta = null,
};

/// RoleRef contains information that points to the role being used
pub const RbacV1RoleRef = struct {
    /// APIGroup is the group for the resource being referenced
    apiGroup: ?[]const u8 = null,
    /// Kind is the type of resource being referenced
    kind: []const u8,
    /// Name is the name of resource being referenced
    name: []const u8,
};

/// Subject contains a reference to the object or user identities a role binding applies to.  This can either hold a direct API object reference, or a value for non-objects such as user and group names.
pub const RbacV1Subject = struct {
    /// APIGroup holds the API group of the referenced subject. Defaults to "" for ServiceAccount subjects. Defaults to "rbac.authorization.k8s.io" for User and Group subjects.
    apiGroup: ?[]const u8 = null,
    /// Kind of object being referenced. Values defined by this API group are "User", "Group", and "ServiceAccount". If the Authorizer does not recognized the kind value, the Authorizer should report an error.
    kind: []const u8,
    /// Name of the object being referenced.
    name: []const u8,
    /// Namespace of the referenced object.  If the object kind is non-namespace, such as "User" or "Group", and this value is not empty the Authorizer should report an error.
    namespace: ?[]const u8 = null,
};
