// Auto-generated from Kubernetes OpenAPI spec.
// Do not edit manually. Regenerate with: zig build generate

const std = @import("std");
const json = std.json;
const meta_v1 = @import("meta_v1.zig");

/// ApplyConfiguration defines the desired configuration values of an object.
pub const AdmissionregistrationV1beta1ApplyConfiguration = struct {
    /// expression will be evaluated by CEL to create an apply configuration. ref: https://github.com/google/cel-spec
    expression: ?[]const u8 = null,
};

/// JSONPatch defines a JSON Patch.
pub const AdmissionregistrationV1beta1JSONPatch = struct {
    /// expression will be evaluated by CEL to create a [JSON patch](https://jsonpatch.com/). ref: https://github.com/google/cel-spec
    expression: ?[]const u8 = null,
};

/// MatchCondition represents a condition which must be fulfilled for a request to be sent to a webhook.
pub const AdmissionregistrationV1beta1MatchCondition = struct {
    /// Expression represents the expression which will be evaluated by CEL. Must evaluate to bool. CEL expressions have access to the contents of the AdmissionRequest and Authorizer, organized into CEL variables:
    expression: []const u8,
    /// Name is an identifier for this match condition, used for strategic merging of MatchConditions, as well as providing an identifier for logging purposes. A good name should be descriptive of the associated expression. Name must be a qualified name consisting of alphanumeric characters, '-', '_' or '.', and must start and end with an alphanumeric character (e.g. 'MyName',  or 'my.name',  or '123-abc', regex used for validation is '([A-Za-z0-9][-A-Za-z0-9_.]*)?[A-Za-z0-9]') with an optional DNS subdomain prefix and '/' (e.g. 'example.com/MyName')
    name: []const u8,
};

/// MatchResources decides whether to run the admission control policy on an object based on whether it meets the match criteria. The exclude rules take precedence over include rules (if a resource matches both, it is excluded)
pub const AdmissionregistrationV1beta1MatchResources = struct {
    /// ExcludeResourceRules describes what operations on what resources/subresources the ValidatingAdmissionPolicy should not care about. The exclude rules take precedence over include rules (if a resource matches both, it is excluded)
    excludeResourceRules: ?[]const AdmissionregistrationV1beta1NamedRuleWithOperations = null,
    /// matchPolicy defines how the "MatchResources" list is used to match incoming requests. Allowed values are "Exact" or "Equivalent".
    matchPolicy: ?[]const u8 = null,
    /// NamespaceSelector decides whether to run the admission control policy on an object based on whether the namespace for that object matches the selector. If the object itself is a namespace, the matching is performed on object.metadata.labels. If the object is another cluster scoped resource, it never skips the policy.
    namespaceSelector: ?meta_v1.MetaV1LabelSelector = null,
    /// ObjectSelector decides whether to run the validation based on if the object has matching labels. objectSelector is evaluated against both the oldObject and newObject that would be sent to the cel validation, and is considered to match if either object matches the selector. A null object (oldObject in the case of create, or newObject in the case of delete) or an object that cannot have labels (like a DeploymentRollback or a PodProxyOptions object) is not considered to match. Use the object selector only if the webhook is opt-in, because end users may skip the admission webhook by setting the labels. Default to the empty LabelSelector, which matches everything.
    objectSelector: ?meta_v1.MetaV1LabelSelector = null,
    /// ResourceRules describes what operations on what resources/subresources the ValidatingAdmissionPolicy matches. The policy cares about an operation if it matches _any_ Rule.
    resourceRules: ?[]const AdmissionregistrationV1beta1NamedRuleWithOperations = null,
};

/// MutatingAdmissionPolicy describes the definition of an admission mutation policy that mutates the object coming into admission chain.
pub const AdmissionregistrationV1beta1MutatingAdmissionPolicy = struct {
    pub const resource_meta = .{
        .group = "admissionregistration.k8s.io",
        .version = "v1beta1",
        .kind = "MutatingAdmissionPolicy",
        .resource = "mutatingadmissionpolicies",
        .namespaced = false,
        .list_kind = AdmissionregistrationV1beta1MutatingAdmissionPolicyList,
    };

    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard object metadata; More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata.
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// Specification of the desired behavior of the MutatingAdmissionPolicy.
    spec: ?AdmissionregistrationV1beta1MutatingAdmissionPolicySpec = null,
};

/// MutatingAdmissionPolicyBinding binds the MutatingAdmissionPolicy with parametrized resources. MutatingAdmissionPolicyBinding and the optional parameter resource together define how cluster administrators configure policies for clusters.
pub const AdmissionregistrationV1beta1MutatingAdmissionPolicyBinding = struct {
    pub const resource_meta = .{
        .group = "admissionregistration.k8s.io",
        .version = "v1beta1",
        .kind = "MutatingAdmissionPolicyBinding",
        .resource = "mutatingadmissionpolicybindings",
        .namespaced = false,
        .list_kind = AdmissionregistrationV1beta1MutatingAdmissionPolicyBindingList,
    };

    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard object metadata; More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata.
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// Specification of the desired behavior of the MutatingAdmissionPolicyBinding.
    spec: ?AdmissionregistrationV1beta1MutatingAdmissionPolicyBindingSpec = null,
};

/// MutatingAdmissionPolicyBindingList is a list of MutatingAdmissionPolicyBinding.
pub const AdmissionregistrationV1beta1MutatingAdmissionPolicyBindingList = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// List of PolicyBinding.
    items: []const AdmissionregistrationV1beta1MutatingAdmissionPolicyBinding,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard list metadata. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    metadata: ?meta_v1.MetaV1ListMeta = null,
};

/// MutatingAdmissionPolicyBindingSpec is the specification of the MutatingAdmissionPolicyBinding.
pub const AdmissionregistrationV1beta1MutatingAdmissionPolicyBindingSpec = struct {
    /// matchResources limits what resources match this binding and may be mutated by it. Note that if matchResources matches a resource, the resource must also match a policy's matchConstraints and matchConditions before the resource may be mutated. When matchResources is unset, it does not constrain resource matching, and only the policy's matchConstraints and matchConditions must match for the resource to be mutated. Additionally, matchResources.resourceRules are optional and do not constraint matching when unset. Note that this is differs from MutatingAdmissionPolicy matchConstraints, where resourceRules are required. The CREATE, UPDATE and CONNECT operations are allowed.  The DELETE operation may not be matched. '*' matches CREATE, UPDATE and CONNECT.
    matchResources: ?AdmissionregistrationV1beta1MatchResources = null,
    /// paramRef specifies the parameter resource used to configure the admission control policy. It should point to a resource of the type specified in spec.ParamKind of the bound MutatingAdmissionPolicy. If the policy specifies a ParamKind and the resource referred to by ParamRef does not exist, this binding is considered mis-configured and the FailurePolicy of the MutatingAdmissionPolicy applied. If the policy does not specify a ParamKind then this field is ignored, and the rules are evaluated without a param.
    paramRef: ?AdmissionregistrationV1beta1ParamRef = null,
    /// policyName references a MutatingAdmissionPolicy name which the MutatingAdmissionPolicyBinding binds to. If the referenced resource does not exist, this binding is considered invalid and will be ignored Required.
    policyName: ?[]const u8 = null,
};

/// MutatingAdmissionPolicyList is a list of MutatingAdmissionPolicy.
pub const AdmissionregistrationV1beta1MutatingAdmissionPolicyList = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// List of ValidatingAdmissionPolicy.
    items: []const AdmissionregistrationV1beta1MutatingAdmissionPolicy,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard list metadata. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    metadata: ?meta_v1.MetaV1ListMeta = null,
};

/// MutatingAdmissionPolicySpec is the specification of the desired behavior of the admission policy.
pub const AdmissionregistrationV1beta1MutatingAdmissionPolicySpec = struct {
    /// failurePolicy defines how to handle failures for the admission policy. Failures can occur from CEL expression parse errors, type check errors, runtime errors and invalid or mis-configured policy definitions or bindings.
    failurePolicy: ?[]const u8 = null,
    /// matchConditions is a list of conditions that must be met for a request to be validated. Match conditions filter requests that have already been matched by the matchConstraints. An empty list of matchConditions matches all requests. There are a maximum of 64 match conditions allowed.
    matchConditions: ?[]const AdmissionregistrationV1beta1MatchCondition = null,
    /// matchConstraints specifies what resources this policy is designed to validate. The MutatingAdmissionPolicy cares about a request if it matches _all_ Constraints. However, in order to prevent clusters from being put into an unstable state that cannot be recovered from via the API MutatingAdmissionPolicy cannot match MutatingAdmissionPolicy and MutatingAdmissionPolicyBinding. The CREATE, UPDATE and CONNECT operations are allowed.  The DELETE operation may not be matched. '*' matches CREATE, UPDATE and CONNECT. Required.
    matchConstraints: ?AdmissionregistrationV1beta1MatchResources = null,
    /// mutations contain operations to perform on matching objects. mutations may not be empty; a minimum of one mutation is required. mutations are evaluated in order, and are reinvoked according to the reinvocationPolicy. The mutations of a policy are invoked for each binding of this policy and reinvocation of mutations occurs on a per binding basis.
    mutations: ?[]const AdmissionregistrationV1beta1Mutation = null,
    /// paramKind specifies the kind of resources used to parameterize this policy. If absent, there are no parameters for this policy and the param CEL variable will not be provided to validation expressions. If paramKind refers to a non-existent kind, this policy definition is mis-configured and the FailurePolicy is applied. If paramKind is specified but paramRef is unset in MutatingAdmissionPolicyBinding, the params variable will be null.
    paramKind: ?AdmissionregistrationV1beta1ParamKind = null,
    /// reinvocationPolicy indicates whether mutations may be called multiple times per MutatingAdmissionPolicyBinding as part of a single admission evaluation. Allowed values are "Never" and "IfNeeded".
    reinvocationPolicy: ?[]const u8 = null,
    /// variables contain definitions of variables that can be used in composition of other expressions. Each variable is defined as a named CEL expression. The variables defined here will be available under `variables` in other expressions of the policy except matchConditions because matchConditions are evaluated before the rest of the policy.
    variables: ?[]const AdmissionregistrationV1beta1Variable = null,
};

/// Mutation specifies the CEL expression which is used to apply the Mutation.
pub const AdmissionregistrationV1beta1Mutation = struct {
    /// applyConfiguration defines the desired configuration values of an object. The configuration is applied to the admission object using [structured merge diff](https://github.com/kubernetes-sigs/structured-merge-diff). A CEL expression is used to create apply configuration.
    applyConfiguration: ?AdmissionregistrationV1beta1ApplyConfiguration = null,
    /// jsonPatch defines a [JSON patch](https://jsonpatch.com/) operation to perform a mutation to the object. A CEL expression is used to create the JSON patch.
    jsonPatch: ?AdmissionregistrationV1beta1JSONPatch = null,
    /// patchType indicates the patch strategy used. Allowed values are "ApplyConfiguration" and "JSONPatch". Required.
    patchType: []const u8,
};

/// NamedRuleWithOperations is a tuple of Operations and Resources with ResourceNames.
pub const AdmissionregistrationV1beta1NamedRuleWithOperations = struct {
    /// APIGroups is the API groups the resources belong to. '*' is all groups. If '*' is present, the length of the slice must be one. Required.
    apiGroups: ?[]const []const u8 = null,
    /// APIVersions is the API versions the resources belong to. '*' is all versions. If '*' is present, the length of the slice must be one. Required.
    apiVersions: ?[]const []const u8 = null,
    /// Operations is the operations the admission hook cares about - CREATE, UPDATE, DELETE, CONNECT or * for all of those operations and any future admission operations that are added. If '*' is present, the length of the slice must be one. Required.
    operations: ?[]const []const u8 = null,
    /// ResourceNames is an optional white list of names that the rule applies to.  An empty set means that everything is allowed.
    resourceNames: ?[]const []const u8 = null,
    /// Resources is a list of resources this rule applies to.
    resources: ?[]const []const u8 = null,
    /// scope specifies the scope of this rule. Valid values are "Cluster", "Namespaced", and "*" "Cluster" means that only cluster-scoped resources will match this rule. Namespace API objects are cluster-scoped. "Namespaced" means that only namespaced resources will match this rule. "*" means that there are no scope restrictions. Subresources match the scope of their parent resource. Default is "*".
    scope: ?[]const u8 = null,
};

/// ParamKind is a tuple of Group Kind and Version.
pub const AdmissionregistrationV1beta1ParamKind = struct {
    /// APIVersion is the API group version the resources belong to. In format of "group/version". Required.
    apiVersion: ?[]const u8 = null,
    /// Kind is the API kind the resources belong to. Required.
    kind: ?[]const u8 = null,
};

/// ParamRef describes how to locate the params to be used as input to expressions of rules applied by a policy binding.
pub const AdmissionregistrationV1beta1ParamRef = struct {
    /// name is the name of the resource being referenced.
    name: ?[]const u8 = null,
    /// namespace is the namespace of the referenced resource. Allows limiting the search for params to a specific namespace. Applies to both `name` and `selector` fields.
    namespace: ?[]const u8 = null,
    /// `parameterNotFoundAction` controls the behavior of the binding when the resource exists, and name or selector is valid, but there are no parameters matched by the binding. If the value is set to `Allow`, then no matched parameters will be treated as successful validation by the binding. If set to `Deny`, then no matched parameters will be subject to the `failurePolicy` of the policy.
    parameterNotFoundAction: ?[]const u8 = null,
    /// selector can be used to match multiple param objects based on their labels. Supply selector: {} to match all resources of the ParamKind.
    selector: ?meta_v1.MetaV1LabelSelector = null,
};

/// Variable is the definition of a variable that is used for composition. A variable is defined as a named expression.
pub const AdmissionregistrationV1beta1Variable = struct {
    /// Expression is the expression that will be evaluated as the value of the variable. The CEL expression has access to the same identifiers as the CEL expressions in Validation.
    expression: []const u8,
    /// Name is the name of the variable. The name must be a valid CEL identifier and unique among all variables. The variable can be accessed in other expressions through `variables` For example, if name is "foo", the variable will be available as `variables.foo`
    name: []const u8,
};
