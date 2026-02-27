// Auto-generated from Kubernetes OpenAPI spec.
// Do not edit manually. Regenerate with: zig build generate

const std = @import("std");
const json = std.json;
const meta_v1 = @import("meta_v1.zig");

/// FieldSelectorAttributes indicates a field limited access. Webhook authors are encouraged to * ensure rawSelector and requirements are not both set * consider the requirements field if set * not try to parse or consider the rawSelector field if set. This is to avoid another CVE-2022-2880 (i.e. getting different systems to agree on how exactly to parse a query is not something we want), see https://www.oxeye.io/resources/golang-parameter-smuggling-attack for more details. For the *SubjectAccessReview endpoints of the kube-apiserver: * If rawSelector is empty and requirements are empty, the request is not limited. * If rawSelector is present and requirements are empty, the rawSelector will be parsed and limited if the parsing succeeds. * If rawSelector is empty and requirements are present, the requirements should be honored * If rawSelector is present and requirements are present, the request is invalid.
pub const AuthorizationV1FieldSelectorAttributes = struct {
    /// rawSelector is the serialization of a field selector that would be included in a query parameter. Webhook implementations are encouraged to ignore rawSelector. The kube-apiserver's *SubjectAccessReview will parse the rawSelector as long as the requirements are not present.
    rawSelector: ?[]const u8 = null,
    /// requirements is the parsed interpretation of a field selector. All requirements must be met for a resource instance to match the selector. Webhook implementations should handle requirements, but how to handle them is up to the webhook. Since requirements can only limit the request, it is safe to authorize as unlimited request if the requirements are not understood.
    requirements: ?[]const meta_v1.MetaV1FieldSelectorRequirement = null,
};

/// LabelSelectorAttributes indicates a label limited access. Webhook authors are encouraged to * ensure rawSelector and requirements are not both set * consider the requirements field if set * not try to parse or consider the rawSelector field if set. This is to avoid another CVE-2022-2880 (i.e. getting different systems to agree on how exactly to parse a query is not something we want), see https://www.oxeye.io/resources/golang-parameter-smuggling-attack for more details. For the *SubjectAccessReview endpoints of the kube-apiserver: * If rawSelector is empty and requirements are empty, the request is not limited. * If rawSelector is present and requirements are empty, the rawSelector will be parsed and limited if the parsing succeeds. * If rawSelector is empty and requirements are present, the requirements should be honored * If rawSelector is present and requirements are present, the request is invalid.
pub const AuthorizationV1LabelSelectorAttributes = struct {
    /// rawSelector is the serialization of a field selector that would be included in a query parameter. Webhook implementations are encouraged to ignore rawSelector. The kube-apiserver's *SubjectAccessReview will parse the rawSelector as long as the requirements are not present.
    rawSelector: ?[]const u8 = null,
    /// requirements is the parsed interpretation of a label selector. All requirements must be met for a resource instance to match the selector. Webhook implementations should handle requirements, but how to handle them is up to the webhook. Since requirements can only limit the request, it is safe to authorize as unlimited request if the requirements are not understood.
    requirements: ?[]const meta_v1.MetaV1LabelSelectorRequirement = null,
};

/// LocalSubjectAccessReview checks whether or not a user or group can perform an action in a given namespace. Having a namespace scoped resource makes it much easier to grant namespace scoped policy that includes permissions checking.
pub const AuthorizationV1LocalSubjectAccessReview = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard list metadata. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// Spec holds information about the request being evaluated.  spec.namespace must be equal to the namespace you made the request against.  If empty, it is defaulted.
    spec: AuthorizationV1SubjectAccessReviewSpec,
    /// Status is filled in by the server and indicates whether the request is allowed or not
    status: ?AuthorizationV1SubjectAccessReviewStatus = null,
};

/// NonResourceAttributes includes the authorization attributes available for non-resource requests to the Authorizer interface
pub const AuthorizationV1NonResourceAttributes = struct {
    /// Path is the URL path of the request
    path: ?[]const u8 = null,
    /// Verb is the standard HTTP verb
    verb: ?[]const u8 = null,
};

/// NonResourceRule holds information that describes a rule for the non-resource
pub const AuthorizationV1NonResourceRule = struct {
    /// NonResourceURLs is a set of partial urls that a user should have access to.  *s are allowed, but only as the full, final step in the path.  "*" means all.
    nonResourceURLs: ?[]const []const u8 = null,
    /// Verb is a list of kubernetes non-resource API verbs, like: get, post, put, delete, patch, head, options.  "*" means all.
    verbs: []const []const u8,
};

/// ResourceAttributes includes the authorization attributes available for resource requests to the Authorizer interface
pub const AuthorizationV1ResourceAttributes = struct {
    /// fieldSelector describes the limitation on access based on field.  It can only limit access, not broaden it.
    fieldSelector: ?AuthorizationV1FieldSelectorAttributes = null,
    /// Group is the API Group of the Resource.  "*" means all.
    group: ?[]const u8 = null,
    /// labelSelector describes the limitation on access based on labels.  It can only limit access, not broaden it.
    labelSelector: ?AuthorizationV1LabelSelectorAttributes = null,
    /// Name is the name of the resource being requested for a "get" or deleted for a "delete". "" (empty) means all.
    name: ?[]const u8 = null,
    /// Namespace is the namespace of the action being requested.  Currently, there is no distinction between no namespace and all namespaces "" (empty) is defaulted for LocalSubjectAccessReviews "" (empty) is empty for cluster-scoped resources "" (empty) means "all" for namespace scoped resources from a SubjectAccessReview or SelfSubjectAccessReview
    namespace: ?[]const u8 = null,
    /// Resource is one of the existing resource types.  "*" means all.
    resource: ?[]const u8 = null,
    /// Subresource is one of the existing resource types.  "" means none.
    subresource: ?[]const u8 = null,
    /// Verb is a kubernetes resource API verb, like: get, list, watch, create, update, delete, proxy.  "*" means all.
    verb: ?[]const u8 = null,
    /// Version is the API Version of the Resource.  "*" means all.
    version: ?[]const u8 = null,
};

/// ResourceRule is the list of actions the subject is allowed to perform on resources. The list ordering isn't significant, may contain duplicates, and possibly be incomplete.
pub const AuthorizationV1ResourceRule = struct {
    /// APIGroups is the name of the APIGroup that contains the resources.  If multiple API groups are specified, any action requested against one of the enumerated resources in any API group will be allowed.  "*" means all.
    apiGroups: ?[]const []const u8 = null,
    /// ResourceNames is an optional white list of names that the rule applies to.  An empty set means that everything is allowed.  "*" means all.
    resourceNames: ?[]const []const u8 = null,
    /// Resources is a list of resources this rule applies to.  "*" means all in the specified apiGroups.
    resources: ?[]const []const u8 = null,
    /// Verb is a list of kubernetes resource API verbs, like: get, list, watch, create, update, delete, proxy.  "*" means all.
    verbs: []const []const u8,
};

/// SelfSubjectAccessReview checks whether or the current user can perform an action.  Not filling in a spec.namespace means "in all namespaces".  Self is a special case, because users should always be able to check whether they can perform an action
pub const AuthorizationV1SelfSubjectAccessReview = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard list metadata. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// Spec holds information about the request being evaluated.  user and groups must be empty
    spec: AuthorizationV1SelfSubjectAccessReviewSpec,
    /// Status is filled in by the server and indicates whether the request is allowed or not
    status: ?AuthorizationV1SubjectAccessReviewStatus = null,
};

/// SelfSubjectAccessReviewSpec is a description of the access request.  Exactly one of ResourceAuthorizationAttributes and NonResourceAuthorizationAttributes must be set
pub const AuthorizationV1SelfSubjectAccessReviewSpec = struct {
    /// NonResourceAttributes describes information for a non-resource access request
    nonResourceAttributes: ?AuthorizationV1NonResourceAttributes = null,
    /// ResourceAuthorizationAttributes describes information for a resource access request
    resourceAttributes: ?AuthorizationV1ResourceAttributes = null,
};

/// SelfSubjectRulesReview enumerates the set of actions the current user can perform within a namespace. The returned list of actions may be incomplete depending on the server's authorization mode, and any errors experienced during the evaluation. SelfSubjectRulesReview should be used by UIs to show/hide actions, or to quickly let an end user reason about their permissions. It should NOT Be used by external systems to drive authorization decisions as this raises confused deputy, cache lifetime/revocation, and correctness concerns. SubjectAccessReview, and LocalAccessReview are the correct way to defer authorization decisions to the API server.
pub const AuthorizationV1SelfSubjectRulesReview = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard list metadata. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// Spec holds information about the request being evaluated.
    spec: AuthorizationV1SelfSubjectRulesReviewSpec,
    /// Status is filled in by the server and indicates the set of actions a user can perform.
    status: ?AuthorizationV1SubjectRulesReviewStatus = null,
};

/// SelfSubjectRulesReviewSpec defines the specification for SelfSubjectRulesReview.
pub const AuthorizationV1SelfSubjectRulesReviewSpec = struct {
    /// Namespace to evaluate rules for. Required.
    namespace: ?[]const u8 = null,
};

/// SubjectAccessReview checks whether or not a user or group can perform an action.
pub const AuthorizationV1SubjectAccessReview = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard list metadata. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// Spec holds information about the request being evaluated
    spec: AuthorizationV1SubjectAccessReviewSpec,
    /// Status is filled in by the server and indicates whether the request is allowed or not
    status: ?AuthorizationV1SubjectAccessReviewStatus = null,
};

/// SubjectAccessReviewSpec is a description of the access request.  Exactly one of ResourceAuthorizationAttributes and NonResourceAuthorizationAttributes must be set
pub const AuthorizationV1SubjectAccessReviewSpec = struct {
    /// Extra corresponds to the user.Info.GetExtra() method from the authenticator.  Since that is input to the authorizer it needs a reflection here.
    extra: ?json.ArrayHashMap([]const []const u8) = null,
    /// Groups is the groups you're testing for.
    groups: ?[]const []const u8 = null,
    /// NonResourceAttributes describes information for a non-resource access request
    nonResourceAttributes: ?AuthorizationV1NonResourceAttributes = null,
    /// ResourceAuthorizationAttributes describes information for a resource access request
    resourceAttributes: ?AuthorizationV1ResourceAttributes = null,
    /// UID information about the requesting user.
    uid: ?[]const u8 = null,
    /// User is the user you're testing for. If you specify "User" but not "Groups", then is it interpreted as "What if User were not a member of any groups
    user: ?[]const u8 = null,
};

/// SubjectAccessReviewStatus
pub const AuthorizationV1SubjectAccessReviewStatus = struct {
    /// Allowed is required. True if the action would be allowed, false otherwise.
    allowed: bool,
    /// Denied is optional. True if the action would be denied, otherwise false. If both allowed is false and denied is false, then the authorizer has no opinion on whether to authorize the action. Denied may not be true if Allowed is true.
    denied: ?bool = null,
    /// EvaluationError is an indication that some error occurred during the authorization check. It is entirely possible to get an error and be able to continue determine authorization status in spite of it. For instance, RBAC can be missing a role, but enough roles are still present and bound to reason about the request.
    evaluationError: ?[]const u8 = null,
    /// Reason is optional.  It indicates why a request was allowed or denied.
    reason: ?[]const u8 = null,
};

/// SubjectRulesReviewStatus contains the result of a rules check. This check can be incomplete depending on the set of authorizers the server is configured with and any errors experienced during evaluation. Because authorization rules are additive, if a rule appears in a list it's safe to assume the subject has that permission, even if that list is incomplete.
pub const AuthorizationV1SubjectRulesReviewStatus = struct {
    /// EvaluationError can appear in combination with Rules. It indicates an error occurred during rule evaluation, such as an authorizer that doesn't support rule evaluation, and that ResourceRules and/or NonResourceRules may be incomplete.
    evaluationError: ?[]const u8 = null,
    /// Incomplete is true when the rules returned by this call are incomplete. This is most commonly encountered when an authorizer, such as an external authorizer, doesn't support rules evaluation.
    incomplete: bool,
    /// NonResourceRules is the list of actions the subject is allowed to perform on non-resources. The list ordering isn't significant, may contain duplicates, and possibly be incomplete.
    nonResourceRules: []const AuthorizationV1NonResourceRule,
    /// ResourceRules is the list of actions the subject is allowed to perform on resources. The list ordering isn't significant, may contain duplicates, and possibly be incomplete.
    resourceRules: []const AuthorizationV1ResourceRule,
};
