// Auto-generated from Kubernetes OpenAPI spec.
// Do not edit manually. Regenerate with: zig build generate

const std = @import("std");
const json = std.json;
const meta_v1 = @import("meta_v1.zig");

/// ApplyConfiguration defines the desired configuration values of an object.
pub const AdmissionregistrationV1ApplyConfiguration = struct {
    /// expression will be evaluated by CEL to create an apply configuration. ref: https://github.com/google/cel-spec
    expression: ?[]const u8 = null,
};

/// AuditAnnotation describes how to produce an audit annotation for an API request.
pub const AdmissionregistrationV1AuditAnnotation = struct {
    /// key specifies the audit annotation key. The audit annotation keys of a ValidatingAdmissionPolicy must be unique. The key must be a qualified name ([A-Za-z0-9][-A-Za-z0-9_.]*) no more than 63 bytes in length.
    key: []const u8,
    /// valueExpression represents the expression which is evaluated by CEL to produce an audit annotation value. The expression must evaluate to either a string or null value. If the expression evaluates to a string, the audit annotation is included with the string value. If the expression evaluates to null or empty string the audit annotation will be omitted. The valueExpression may be no longer than 5kb in length. If the result of the valueExpression is more than 10kb in length, it will be truncated to 10kb.
    valueExpression: []const u8,
};

/// ExpressionWarning is a warning information that targets a specific expression.
pub const AdmissionregistrationV1ExpressionWarning = struct {
    /// fieldRef is the path to the field that refers to the expression. For example, the reference to the expression of the first item of validations is "spec.validations[0].expression"
    fieldRef: []const u8,
    /// warning contains the content of type checking information in a human-readable form. Each line of the warning contains the type that the expression is checked against, followed by the type check error from the compiler.
    warning: []const u8,
};

/// JSONPatch defines a JSON Patch.
pub const AdmissionregistrationV1JSONPatch = struct {
    /// expression will be evaluated by CEL to create a [JSON patch](https://jsonpatch.com/). ref: https://github.com/google/cel-spec
    expression: ?[]const u8 = null,
};

/// MatchCondition represents a condition which must by fulfilled for a request to be sent to a webhook.
pub const AdmissionregistrationV1MatchCondition = struct {
    /// expression represents the expression which will be evaluated by CEL. Must evaluate to bool. CEL expressions have access to the contents of the AdmissionRequest and Authorizer, organized into CEL variables:
    expression: []const u8,
    /// name is an identifier for this match condition, used for strategic merging of MatchConditions, as well as providing an identifier for logging purposes. A good name should be descriptive of the associated expression. Name must be a qualified name consisting of alphanumeric characters, '-', '_' or '.', and must start and end with an alphanumeric character (e.g. 'MyName',  or 'my.name',  or '123-abc', regex used for validation is '([A-Za-z0-9][-A-Za-z0-9_.]*)?[A-Za-z0-9]') with an optional DNS subdomain prefix and '/' (e.g. 'example.com/MyName')
    name: []const u8,
};

/// MatchResources decides whether to run the admission control policy on an object based on whether it meets the match criteria. The exclude rules take precedence over include rules (if a resource matches both, it is excluded)
pub const AdmissionregistrationV1MatchResources = struct {
    /// excludeResourceRules describes what operations on what resources/subresources the ValidatingAdmissionPolicy should not care about. The exclude rules take precedence over include rules (if a resource matches both, it is excluded)
    excludeResourceRules: ?[]const AdmissionregistrationV1NamedRuleWithOperations = null,
    /// matchPolicy defines how the "MatchResources" list is used to match incoming requests. Allowed values are "Exact" or "Equivalent".
    matchPolicy: ?[]const u8 = null,
    /// namespaceSelector decides whether to run the admission control policy on an object based on whether the namespace for that object matches the selector. If the object itself is a namespace, the matching is performed on object.metadata.labels. If the object is another cluster scoped resource, it never skips the policy.
    namespaceSelector: ?meta_v1.MetaV1LabelSelector = null,
    /// objectSelector decides whether to run the validation based on if the object has matching labels. objectSelector is evaluated against both the oldObject and newObject that would be sent to the cel validation, and is considered to match if either object matches the selector. A null object (oldObject in the case of create, or newObject in the case of delete) or an object that cannot have labels (like a DeploymentRollback or a PodProxyOptions object) is not considered to match. Use the object selector only if the webhook is opt-in, because end users may skip the admission webhook by setting the labels. Default to the empty LabelSelector, which matches everything.
    objectSelector: ?meta_v1.MetaV1LabelSelector = null,
    /// resourceRules describes what operations on what resources/subresources the ValidatingAdmissionPolicy matches. The policy cares about an operation if it matches _any_ Rule.
    resourceRules: ?[]const AdmissionregistrationV1NamedRuleWithOperations = null,
};

/// MutatingAdmissionPolicy describes the definition of an admission mutation policy that mutates the object coming into admission chain.
pub const AdmissionregistrationV1MutatingAdmissionPolicy = struct {
    pub const resource_meta = .{
        .group = "admissionregistration.k8s.io",
        .version = "v1",
        .kind = "MutatingAdmissionPolicy",
        .resource = "mutatingadmissionpolicies",
        .namespaced = false,
        .list_kind = AdmissionregistrationV1MutatingAdmissionPolicyList,
    };

    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// metadata is the standard object metadata; More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata.
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// spec defines the desired behavior of the MutatingAdmissionPolicy.
    spec: ?AdmissionregistrationV1MutatingAdmissionPolicySpec = null,
};

/// MutatingAdmissionPolicyBinding binds the MutatingAdmissionPolicy with parametrized resources. MutatingAdmissionPolicyBinding and the optional parameter resource together define how cluster administrators configure policies for clusters.
pub const AdmissionregistrationV1MutatingAdmissionPolicyBinding = struct {
    pub const resource_meta = .{
        .group = "admissionregistration.k8s.io",
        .version = "v1",
        .kind = "MutatingAdmissionPolicyBinding",
        .resource = "mutatingadmissionpolicybindings",
        .namespaced = false,
        .list_kind = AdmissionregistrationV1MutatingAdmissionPolicyBindingList,
    };

    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// metadata is the standard object metadata; More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata.
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// spec defines the desired behavior of the MutatingAdmissionPolicyBinding.
    spec: ?AdmissionregistrationV1MutatingAdmissionPolicyBindingSpec = null,
};

/// MutatingAdmissionPolicyBindingList is a list of MutatingAdmissionPolicyBinding.
pub const AdmissionregistrationV1MutatingAdmissionPolicyBindingList = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// List of PolicyBinding.
    items: []const AdmissionregistrationV1MutatingAdmissionPolicyBinding,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// metadata is the standard list metadata. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    metadata: ?meta_v1.MetaV1ListMeta = null,
};

/// MutatingAdmissionPolicyBindingSpec defines the specification of the MutatingAdmissionPolicyBinding.
pub const AdmissionregistrationV1MutatingAdmissionPolicyBindingSpec = struct {
    /// matchResources limits what resources match this binding and may be mutated by it. Note that if matchResources matches a resource, the resource must also match a policy's matchConstraints and matchConditions before the resource may be mutated. When matchResources is unset, it does not constrain resource matching, and only the policy's matchConstraints and matchConditions must match for the resource to be mutated. Additionally, matchResources.resourceRules are optional and do not constraint matching when unset. Note that this is differs from MutatingAdmissionPolicy matchConstraints, where resourceRules are required. The CREATE, UPDATE and CONNECT operations are allowed.  The DELETE operation may not be matched. '*' matches CREATE, UPDATE and CONNECT.
    matchResources: ?AdmissionregistrationV1MatchResources = null,
    /// paramRef specifies the parameter resource used to configure the admission control policy. It should point to a resource of the type specified in spec.ParamKind of the bound MutatingAdmissionPolicy. If the policy specifies a ParamKind and the resource referred to by ParamRef does not exist, this binding is considered mis-configured and the FailurePolicy of the MutatingAdmissionPolicy applied. If the policy does not specify a ParamKind then this field is ignored, and the rules are evaluated without a param.
    paramRef: ?AdmissionregistrationV1ParamRef = null,
    /// policyName references a MutatingAdmissionPolicy name which the MutatingAdmissionPolicyBinding binds to. If the referenced resource does not exist, this binding is considered invalid and will be ignored Required.
    policyName: ?[]const u8 = null,
};

/// MutatingAdmissionPolicyList is a list of MutatingAdmissionPolicy.
pub const AdmissionregistrationV1MutatingAdmissionPolicyList = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// List of ValidatingAdmissionPolicy.
    items: []const AdmissionregistrationV1MutatingAdmissionPolicy,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// metadata is the standard list metadata. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    metadata: ?meta_v1.MetaV1ListMeta = null,
};

/// MutatingAdmissionPolicySpec defines the desired behavior of the admission policy.
pub const AdmissionregistrationV1MutatingAdmissionPolicySpec = struct {
    /// failurePolicy defines how to handle failures for the admission policy. Failures can occur from CEL expression parse errors, type check errors, runtime errors and invalid or mis-configured policy definitions or bindings.
    failurePolicy: ?[]const u8 = null,
    /// matchConditions is a list of conditions that must be met for a request to be validated. Match conditions filter requests that have already been matched by the matchConstraints. An empty list of matchConditions matches all requests. There are a maximum of 64 match conditions allowed.
    matchConditions: ?[]const AdmissionregistrationV1MatchCondition = null,
    /// matchConstraints specifies what resources this policy is designed to validate. The MutatingAdmissionPolicy cares about a request if it matches _all_ Constraints. However, in order to prevent clusters from being put into an unstable state that cannot be recovered from via the API MutatingAdmissionPolicy cannot match MutatingAdmissionPolicy and MutatingAdmissionPolicyBinding. The CREATE, UPDATE and CONNECT operations are allowed.  The DELETE operation may not be matched. '*' matches CREATE, UPDATE and CONNECT. Required.
    matchConstraints: ?AdmissionregistrationV1MatchResources = null,
    /// mutations contain operations to perform on matching objects. mutations may not be empty; a minimum of one mutation is required. mutations are evaluated in order, and are reinvoked according to the reinvocationPolicy. The mutations of a policy are invoked for each binding of this policy and reinvocation of mutations occurs on a per binding basis.
    mutations: ?[]const AdmissionregistrationV1Mutation = null,
    /// paramKind specifies the kind of resources used to parameterize this policy. If absent, there are no parameters for this policy and the param CEL variable will not be provided to validation expressions. If paramKind refers to a non-existent kind, this policy definition is mis-configured and the FailurePolicy is applied. If paramKind is specified but paramRef is unset in MutatingAdmissionPolicyBinding, the params variable will be null.
    paramKind: ?AdmissionregistrationV1ParamKind = null,
    /// reinvocationPolicy indicates whether mutations may be called multiple times per MutatingAdmissionPolicyBinding as part of a single admission evaluation. Allowed values are "Never" and "IfNeeded".
    reinvocationPolicy: ?[]const u8 = null,
    /// variables contain definitions of variables that can be used in composition of other expressions. Each variable is defined as a named CEL expression. The variables defined here will be available under `variables` in other expressions of the policy except matchConditions because matchConditions are evaluated before the rest of the policy.
    variables: ?[]const AdmissionregistrationV1Variable = null,
};

/// MutatingWebhook describes an admission webhook and the resources and operations it applies to.
pub const AdmissionregistrationV1MutatingWebhook = struct {
    /// admissionReviewVersions is an ordered list of preferred `AdmissionReview` versions the Webhook expects. API server will try to use first version in the list which it supports. If none of the versions specified in this list supported by API server, validation will fail for this object. If a persisted webhook configuration specifies allowed versions and does not include any versions known to the API Server, calls to the webhook will fail and be subject to the failure policy.
    admissionReviewVersions: []const []const u8,
    /// clientConfig defines how to communicate with the hook. Required
    clientConfig: AdmissionregistrationV1WebhookClientConfig,
    /// failurePolicy defines how unrecognized errors from the admission endpoint are handled - allowed values are Ignore or Fail. Defaults to Fail.
    failurePolicy: ?[]const u8 = null,
    /// matchConditions is a list of conditions that must be met for a request to be sent to this webhook. Match conditions filter requests that have already been matched by the rules, namespaceSelector, and objectSelector. An empty list of matchConditions matches all requests. There are a maximum of 64 match conditions allowed.
    matchConditions: ?[]const AdmissionregistrationV1MatchCondition = null,
    /// matchPolicy defines how the "rules" list is used to match incoming requests. Allowed values are "Exact" or "Equivalent".
    matchPolicy: ?[]const u8 = null,
    /// name is the name of the admission webhook. Name should be fully qualified, e.g., imagepolicy.kubernetes.io, where "imagepolicy" is the name of the webhook, and kubernetes.io is the name of the organization. Required.
    name: []const u8,
    /// namespaceSelector decides whether to run the webhook on an object based on whether the namespace for that object matches the selector. If the object itself is a namespace, the matching is performed on object.metadata.labels. If the object is another cluster scoped resource, it never skips the webhook.
    namespaceSelector: ?meta_v1.MetaV1LabelSelector = null,
    /// objectSelector decides whether to run the webhook based on if the object has matching labels. objectSelector is evaluated against both the oldObject and newObject that would be sent to the webhook, and is considered to match if either object matches the selector. A null object (oldObject in the case of create, or newObject in the case of delete) or an object that cannot have labels (like a DeploymentRollback or a PodProxyOptions object) is not considered to match. Use the object selector only if the webhook is opt-in, because end users may skip the admission webhook by setting the labels. Default to the empty LabelSelector, which matches everything.
    objectSelector: ?meta_v1.MetaV1LabelSelector = null,
    /// reinvocationPolicy indicates whether this webhook should be called multiple times as part of a single admission evaluation. Allowed values are "Never" and "IfNeeded".
    reinvocationPolicy: ?[]const u8 = null,
    /// rules describes what operations on what resources/subresources the webhook cares about. The webhook cares about an operation if it matches _any_ Rule. However, in order to prevent ValidatingAdmissionWebhooks and MutatingAdmissionWebhooks from putting the cluster in a state which cannot be recovered from without completely disabling the plugin, ValidatingAdmissionWebhooks and MutatingAdmissionWebhooks are never called on admission requests for ValidatingWebhookConfiguration and MutatingWebhookConfiguration objects.
    rules: ?[]const AdmissionregistrationV1RuleWithOperations = null,
    /// sideEffects states whether this webhook has side effects. Acceptable values are: None, NoneOnDryRun (webhooks created via v1beta1 may also specify Some or Unknown). Webhooks with side effects MUST implement a reconciliation system, since a request may be rejected by a future step in the admission chain and the side effects therefore need to be undone. Requests with the dryRun attribute will be auto-rejected if they match a webhook with sideEffects == Unknown or Some.
    sideEffects: []const u8,
    /// timeoutSeconds specifies the timeout for this webhook. After the timeout passes, the webhook call will be ignored or the API call will fail based on the failure policy. The timeout value must be between 1 and 30 seconds. Default to 10 seconds.
    timeoutSeconds: ?i32 = null,
};

/// MutatingWebhookConfiguration describes the configuration of and admission webhook that accept or reject and may change the object.
pub const AdmissionregistrationV1MutatingWebhookConfiguration = struct {
    pub const resource_meta = .{
        .group = "admissionregistration.k8s.io",
        .version = "v1",
        .kind = "MutatingWebhookConfiguration",
        .resource = "mutatingwebhookconfigurations",
        .namespaced = false,
        .list_kind = AdmissionregistrationV1MutatingWebhookConfigurationList,
    };

    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// metadata is the standard object metadata; More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata.
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// webhooks is a list of webhooks and the affected resources and operations.
    webhooks: ?[]const AdmissionregistrationV1MutatingWebhook = null,
};

/// MutatingWebhookConfigurationList is a list of MutatingWebhookConfiguration.
pub const AdmissionregistrationV1MutatingWebhookConfigurationList = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// List of MutatingWebhookConfiguration.
    items: []const AdmissionregistrationV1MutatingWebhookConfiguration,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// metadata is the standard list metadata. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    metadata: ?meta_v1.MetaV1ListMeta = null,
};

/// Mutation specifies the CEL expression which is used to apply the Mutation.
pub const AdmissionregistrationV1Mutation = struct {
    /// applyConfiguration defines the desired configuration values of an object. The configuration is applied to the admission object using [structured merge diff](https://github.com/kubernetes-sigs/structured-merge-diff). A CEL expression is used to create apply configuration.
    applyConfiguration: ?AdmissionregistrationV1ApplyConfiguration = null,
    /// jsonPatch defines a [JSON patch](https://jsonpatch.com/) operation to perform a mutation to the object. A CEL expression is used to create the JSON patch.
    jsonPatch: ?AdmissionregistrationV1JSONPatch = null,
    /// patchType indicates the patch strategy used. Allowed values are "ApplyConfiguration" and "JSONPatch". Required.
    patchType: []const u8,
};

/// NamedRuleWithOperations is a tuple of Operations and Resources with ResourceNames.
pub const AdmissionregistrationV1NamedRuleWithOperations = struct {
    /// apiGroups is the API groups the resources belong to. '*' is all groups. If '*' is present, the length of the slice must be one. Required.
    apiGroups: ?[]const []const u8 = null,
    /// apiVersions is the API versions the resources belong to. '*' is all versions. If '*' is present, the length of the slice must be one. Required.
    apiVersions: ?[]const []const u8 = null,
    /// operations is the operations the admission hook cares about - CREATE, UPDATE, DELETE, CONNECT or * for all of those operations and any future admission operations that are added. If '*' is present, the length of the slice must be one. Required.
    operations: ?[]const []const u8 = null,
    /// resourceNames is an optional white list of names that the rule applies to.  An empty set means that everything is allowed.
    resourceNames: ?[]const []const u8 = null,
    /// resources is a list of resources this rule applies to.
    resources: ?[]const []const u8 = null,
    /// scope specifies the scope of this rule. Valid values are "Cluster", "Namespaced", and "*" "Cluster" means that only cluster-scoped resources will match this rule. Namespace API objects are cluster-scoped. "Namespaced" means that only namespaced resources will match this rule. "*" means that there are no scope restrictions. Subresources match the scope of their parent resource. Default is "*".
    scope: ?[]const u8 = null,
};

/// ParamKind is a tuple of Group Kind and Version.
pub const AdmissionregistrationV1ParamKind = struct {
    /// apiVersion is the API group version the resources belong to. In format of "group/version". Required.
    apiVersion: ?[]const u8 = null,
    /// kind is the API kind the resources belong to. Required.
    kind: ?[]const u8 = null,
};

/// ParamRef describes how to locate the params to be used as input to expressions of rules applied by a policy binding.
pub const AdmissionregistrationV1ParamRef = struct {
    /// name is the name of the resource being referenced.
    name: ?[]const u8 = null,
    /// namespace is the namespace of the referenced resource. Allows limiting the search for params to a specific namespace. Applies to both `name` and `selector` fields.
    namespace: ?[]const u8 = null,
    /// parameterNotFoundAction controls the behavior of the binding when the resource exists, and name or selector is valid, but there are no parameters matched by the binding. If the value is set to `Allow`, then no matched parameters will be treated as successful validation by the binding. If set to `Deny`, then no matched parameters will be subject to the `failurePolicy` of the policy.
    parameterNotFoundAction: ?[]const u8 = null,
    /// selector can be used to match multiple param objects based on their labels. Supply selector: {} to match all resources of the ParamKind.
    selector: ?meta_v1.MetaV1LabelSelector = null,
};

/// RuleWithOperations is a tuple of Operations and Resources. It is recommended to make sure that all the tuple expansions are valid.
pub const AdmissionregistrationV1RuleWithOperations = struct {
    /// apiGroups is the API groups the resources belong to. '*' is all groups. If '*' is present, the length of the slice must be one. Required.
    apiGroups: ?[]const []const u8 = null,
    /// apiVersions is the API versions the resources belong to. '*' is all versions. If '*' is present, the length of the slice must be one. Required.
    apiVersions: ?[]const []const u8 = null,
    /// operations is the operations the admission hook cares about - CREATE, UPDATE, DELETE, CONNECT or * for all of those operations and any future admission operations that are added. If '*' is present, the length of the slice must be one. Required.
    operations: ?[]const []const u8 = null,
    /// resources is a list of resources this rule applies to.
    resources: ?[]const []const u8 = null,
    /// scope specifies the scope of this rule. Valid values are "Cluster", "Namespaced", and "*" "Cluster" means that only cluster-scoped resources will match this rule. Namespace API objects are cluster-scoped. "Namespaced" means that only namespaced resources will match this rule. "*" means that there are no scope restrictions. Subresources match the scope of their parent resource. Default is "*".
    scope: ?[]const u8 = null,
};

/// ServiceReference holds a reference to Service.legacy.k8s.io
pub const AdmissionregistrationV1ServiceReference = struct {
    /// name is the name of the service. Required
    name: []const u8,
    /// namespace is the namespace of the service. Required
    namespace: []const u8,
    /// path is an optional URL path which will be sent in any request to this service.
    path: ?[]const u8 = null,
    /// port is the port on the service that hosts the webhook. Default to 443 for backward compatibility. `port` should be a valid port number (1-65535, inclusive).
    port: ?i32 = null,
};

/// TypeChecking contains results of type checking the expressions in the ValidatingAdmissionPolicy
pub const AdmissionregistrationV1TypeChecking = struct {
    /// expressionWarnings contains the type checking warnings for each expression.
    expressionWarnings: ?[]const AdmissionregistrationV1ExpressionWarning = null,
};

/// ValidatingAdmissionPolicy describes the definition of an admission validation policy that accepts or rejects an object without changing it.
pub const AdmissionregistrationV1ValidatingAdmissionPolicy = struct {
    pub const resource_meta = .{
        .group = "admissionregistration.k8s.io",
        .version = "v1",
        .kind = "ValidatingAdmissionPolicy",
        .resource = "validatingadmissionpolicies",
        .namespaced = false,
        .list_kind = AdmissionregistrationV1ValidatingAdmissionPolicyList,
    };

    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// metadata is the standard object metadata; More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata.
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// spec defines the desired behavior of the ValidatingAdmissionPolicy.
    spec: ?AdmissionregistrationV1ValidatingAdmissionPolicySpec = null,
    /// status represents the current status of the ValidatingAdmissionPolicy, including warnings that are useful to determine if the policy behaves in the expected way. Populated by the system. Read-only.
    status: ?AdmissionregistrationV1ValidatingAdmissionPolicyStatus = null,
};

/// ValidatingAdmissionPolicyBinding binds the ValidatingAdmissionPolicy with paramerized resources. ValidatingAdmissionPolicyBinding and parameter CRDs together define how cluster administrators configure policies for clusters.
pub const AdmissionregistrationV1ValidatingAdmissionPolicyBinding = struct {
    pub const resource_meta = .{
        .group = "admissionregistration.k8s.io",
        .version = "v1",
        .kind = "ValidatingAdmissionPolicyBinding",
        .resource = "validatingadmissionpolicybindings",
        .namespaced = false,
        .list_kind = AdmissionregistrationV1ValidatingAdmissionPolicyBindingList,
    };

    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// metadata is the standard object metadata; More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata.
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// spec defines the desired behavior of the ValidatingAdmissionPolicyBinding.
    spec: AdmissionregistrationV1ValidatingAdmissionPolicyBindingSpec,
};

/// ValidatingAdmissionPolicyBindingList is a list of ValidatingAdmissionPolicyBinding.
pub const AdmissionregistrationV1ValidatingAdmissionPolicyBindingList = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// List of PolicyBinding.
    items: []const AdmissionregistrationV1ValidatingAdmissionPolicyBinding,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// metadata is the standard list metadata. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    metadata: ?meta_v1.MetaV1ListMeta = null,
};

/// ValidatingAdmissionPolicyBindingSpec is the specification of the ValidatingAdmissionPolicyBinding.
pub const AdmissionregistrationV1ValidatingAdmissionPolicyBindingSpec = struct {
    /// matchResources declares what resources match this binding and will be validated by it. Note that this is intersected with the policy's matchConstraints, so only requests that are matched by the policy can be selected by this. If this is unset, all resources matched by the policy are validated by this binding When resourceRules is unset, it does not constrain resource matching. If a resource is matched by the other fields of this object, it will be validated. Note that this is differs from ValidatingAdmissionPolicy matchConstraints, where resourceRules are required.
    matchResources: ?AdmissionregistrationV1MatchResources = null,
    /// paramRef specifies the parameter resource used to configure the admission control policy. It should point to a resource of the type specified in ParamKind of the bound ValidatingAdmissionPolicy. If the policy specifies a ParamKind and the resource referred to by ParamRef does not exist, this binding is considered mis-configured and the FailurePolicy of the ValidatingAdmissionPolicy applied. If the policy does not specify a ParamKind then this field is ignored, and the rules are evaluated without a param.
    paramRef: ?AdmissionregistrationV1ParamRef = null,
    /// policyName references a ValidatingAdmissionPolicy name which the ValidatingAdmissionPolicyBinding binds to. If the referenced resource does not exist, this binding is considered invalid and will be ignored Required.
    policyName: []const u8,
    /// validationActions declares how Validations of the referenced ValidatingAdmissionPolicy are enforced. If a validation evaluates to false it is always enforced according to these actions.
    validationActions: []const []const u8,
};

/// ValidatingAdmissionPolicyList is a list of ValidatingAdmissionPolicy.
pub const AdmissionregistrationV1ValidatingAdmissionPolicyList = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// List of ValidatingAdmissionPolicy.
    items: []const AdmissionregistrationV1ValidatingAdmissionPolicy,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// metadata is the standard list metadata. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    metadata: ?meta_v1.MetaV1ListMeta = null,
};

/// ValidatingAdmissionPolicySpec is the specification of the desired behavior of the AdmissionPolicy.
pub const AdmissionregistrationV1ValidatingAdmissionPolicySpec = struct {
    /// auditAnnotations contains CEL expressions which are used to produce audit annotations for the audit event of the API request. validations and auditAnnotations may not both be empty; a least one of validations or auditAnnotations is required.
    auditAnnotations: ?[]const AdmissionregistrationV1AuditAnnotation = null,
    /// failurePolicy defines how to handle failures for the admission policy. Failures can occur from CEL expression parse errors, type check errors, runtime errors and invalid or mis-configured policy definitions or bindings.
    failurePolicy: ?[]const u8 = null,
    /// matchConditions is a list of conditions that must be met for a request to be validated. Match conditions filter requests that have already been matched by the rules, namespaceSelector, and objectSelector. An empty list of matchConditions matches all requests. There are a maximum of 64 match conditions allowed.
    matchConditions: ?[]const AdmissionregistrationV1MatchCondition = null,
    /// matchConstraints specifies what resources this policy is designed to validate. The AdmissionPolicy cares about a request if it matches _all_ Constraints. However, in order to prevent clusters from being put into an unstable state that cannot be recovered from via the API ValidatingAdmissionPolicy cannot match ValidatingAdmissionPolicy and ValidatingAdmissionPolicyBinding. Required.
    matchConstraints: ?AdmissionregistrationV1MatchResources = null,
    /// paramKind specifies the kind of resources used to parameterize this policy. If absent, there are no parameters for this policy and the param CEL variable will not be provided to validation expressions. If ParamKind refers to a non-existent kind, this policy definition is mis-configured and the FailurePolicy is applied. If paramKind is specified but paramRef is unset in ValidatingAdmissionPolicyBinding, the params variable will be null.
    paramKind: ?AdmissionregistrationV1ParamKind = null,
    /// validations contain CEL expressions which is used to apply the validation. Validations and AuditAnnotations may not both be empty; a minimum of one Validations or AuditAnnotations is required.
    validations: ?[]const AdmissionregistrationV1Validation = null,
    /// variables contain definitions of variables that can be used in composition of other expressions. Each variable is defined as a named CEL expression. The variables defined here will be available under `variables` in other expressions of the policy except MatchConditions because MatchConditions are evaluated before the rest of the policy.
    variables: ?[]const AdmissionregistrationV1Variable = null,
};

/// ValidatingAdmissionPolicyStatus represents the status of an admission validation policy.
pub const AdmissionregistrationV1ValidatingAdmissionPolicyStatus = struct {
    /// conditions represent the latest available observations of a policy's current state.
    conditions: ?[]const meta_v1.MetaV1Condition = null,
    /// observedGeneration is the generation observed by the controller.
    observedGeneration: ?i64 = null,
    /// typeChecking contains the results of type checking for each expression. Presence of this field indicates the completion of the type checking.
    typeChecking: ?AdmissionregistrationV1TypeChecking = null,
};

/// ValidatingWebhook describes an admission webhook and the resources and operations it applies to.
pub const AdmissionregistrationV1ValidatingWebhook = struct {
    /// admissionReviewVersions is an ordered list of preferred `AdmissionReview` versions the Webhook expects. API server will try to use first version in the list which it supports. If none of the versions specified in this list supported by API server, validation will fail for this object. If a persisted webhook configuration specifies allowed versions and does not include any versions known to the API Server, calls to the webhook will fail and be subject to the failure policy.
    admissionReviewVersions: []const []const u8,
    /// clientConfig defines how to communicate with the hook. Required
    clientConfig: AdmissionregistrationV1WebhookClientConfig,
    /// failurePolicy defines how unrecognized errors from the admission endpoint are handled - allowed values are Ignore or Fail. Defaults to Fail.
    failurePolicy: ?[]const u8 = null,
    /// matchConditions is a list of conditions that must be met for a request to be sent to this webhook. Match conditions filter requests that have already been matched by the rules, namespaceSelector, and objectSelector. An empty list of matchConditions matches all requests. There are a maximum of 64 match conditions allowed.
    matchConditions: ?[]const AdmissionregistrationV1MatchCondition = null,
    /// matchPolicy defines how the "rules" list is used to match incoming requests. Allowed values are "Exact" or "Equivalent".
    matchPolicy: ?[]const u8 = null,
    /// name is the name of the admission webhook. Name should be fully qualified, e.g., imagepolicy.kubernetes.io, where "imagepolicy" is the name of the webhook, and kubernetes.io is the name of the organization. Required.
    name: []const u8,
    /// namespaceSelector decides whether to run the webhook on an object based on whether the namespace for that object matches the selector. If the object itself is a namespace, the matching is performed on object.metadata.labels. If the object is another cluster scoped resource, it never skips the webhook.
    namespaceSelector: ?meta_v1.MetaV1LabelSelector = null,
    /// objectSelector decides whether to run the webhook based on if the object has matching labels. objectSelector is evaluated against both the oldObject and newObject that would be sent to the webhook, and is considered to match if either object matches the selector. A null object (oldObject in the case of create, or newObject in the case of delete) or an object that cannot have labels (like a DeploymentRollback or a PodProxyOptions object) is not considered to match. Use the object selector only if the webhook is opt-in, because end users may skip the admission webhook by setting the labels. Default to the empty LabelSelector, which matches everything.
    objectSelector: ?meta_v1.MetaV1LabelSelector = null,
    /// rules describes what operations on what resources/subresources the webhook cares about. The webhook cares about an operation if it matches _any_ Rule. However, in order to prevent ValidatingAdmissionWebhooks and MutatingAdmissionWebhooks from putting the cluster in a state which cannot be recovered from without completely disabling the plugin, ValidatingAdmissionWebhooks and MutatingAdmissionWebhooks are never called on admission requests for ValidatingWebhookConfiguration and MutatingWebhookConfiguration objects.
    rules: ?[]const AdmissionregistrationV1RuleWithOperations = null,
    /// sideEffects states whether this webhook has side effects. Acceptable values are: None, NoneOnDryRun (webhooks created via v1beta1 may also specify Some or Unknown). Webhooks with side effects MUST implement a reconciliation system, since a request may be rejected by a future step in the admission chain and the side effects therefore need to be undone. Requests with the dryRun attribute will be auto-rejected if they match a webhook with sideEffects == Unknown or Some.
    sideEffects: []const u8,
    /// timeoutSeconds specifies the timeout for this webhook. After the timeout passes, the webhook call will be ignored or the API call will fail based on the failure policy. The timeout value must be between 1 and 30 seconds. Default to 10 seconds.
    timeoutSeconds: ?i32 = null,
};

/// ValidatingWebhookConfiguration describes the configuration of and admission webhook that accept or reject and object without changing it.
pub const AdmissionregistrationV1ValidatingWebhookConfiguration = struct {
    pub const resource_meta = .{
        .group = "admissionregistration.k8s.io",
        .version = "v1",
        .kind = "ValidatingWebhookConfiguration",
        .resource = "validatingwebhookconfigurations",
        .namespaced = false,
        .list_kind = AdmissionregistrationV1ValidatingWebhookConfigurationList,
    };

    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// metadata is the standard object metadata; More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata.
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// webhooks is a list of webhooks and the affected resources and operations.
    webhooks: ?[]const AdmissionregistrationV1ValidatingWebhook = null,
};

/// ValidatingWebhookConfigurationList is a list of ValidatingWebhookConfiguration.
pub const AdmissionregistrationV1ValidatingWebhookConfigurationList = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// List of ValidatingWebhookConfiguration.
    items: []const AdmissionregistrationV1ValidatingWebhookConfiguration,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// metadata is the standard list metadata. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    metadata: ?meta_v1.MetaV1ListMeta = null,
};

/// Validation specifies the CEL expression which is used to apply the validation.
pub const AdmissionregistrationV1Validation = struct {
    /// expression represents the expression which will be evaluated by CEL. ref: https://github.com/google/cel-spec CEL expressions have access to the contents of the API request/response, organized into CEL variables as well as some other useful variables:
    expression: []const u8,
    /// message represents the message displayed when validation fails. The message is required if the Expression contains line breaks. The message must not contain line breaks. If unset, the message is "failed rule: {Rule}". e.g. "must be a URL with the host matching spec.host" If the Expression contains line breaks. Message is required. The message must not contain line breaks. If unset, the message is "failed Expression: {Expression}".
    message: ?[]const u8 = null,
    /// messageExpression declares a CEL expression that evaluates to the validation failure message that is returned when this rule fails. Since messageExpression is used as a failure message, it must evaluate to a string. If both message and messageExpression are present on a validation, then messageExpression will be used if validation fails. If messageExpression results in a runtime error, the runtime error is logged, and the validation failure message is produced as if the messageExpression field were unset. If messageExpression evaluates to an empty string, a string with only spaces, or a string that contains line breaks, then the validation failure message will also be produced as if the messageExpression field were unset, and the fact that messageExpression produced an empty string/string with only spaces/string with line breaks will be logged. messageExpression has access to all the same variables as the `expression` except for 'authorizer' and 'authorizer.requestResource'. Example: "object.x must be less than max ("+string(params.max)+")"
    messageExpression: ?[]const u8 = null,
    /// reason represents a machine-readable description of why this validation failed. If this is the first validation in the list to fail, this reason, as well as the corresponding HTTP response code, are used in the HTTP response to the client. The currently supported reasons are: "Unauthorized", "Forbidden", "Invalid", "RequestEntityTooLarge". If not set, StatusReasonInvalid is used in the response to the client.
    reason: ?[]const u8 = null,
};

/// Variable is the definition of a variable that is used for composition. A variable is defined as a named expression.
pub const AdmissionregistrationV1Variable = struct {
    /// expression is the expression that will be evaluated as the value of the variable. The CEL expression has access to the same identifiers as the CEL expressions in Validation.
    expression: []const u8,
    /// name is the name of the variable. The name must be a valid CEL identifier and unique among all variables. The variable can be accessed in other expressions through `variables` For example, if name is "foo", the variable will be available as `variables.foo`
    name: []const u8,
};

/// WebhookClientConfig contains the information to make a TLS connection with the webhook
pub const AdmissionregistrationV1WebhookClientConfig = struct {
    /// caBundle is a PEM encoded CA bundle which will be used to validate the webhook's server certificate. If unspecified, system trust roots on the apiserver are used.
    caBundle: ?[]const u8 = null,
    /// service is a reference to the service for this webhook. Either `service` or `url` must be specified.
    service: ?AdmissionregistrationV1ServiceReference = null,
    /// url gives the location of the webhook, in standard URL form (`scheme://host:port/path`). Exactly one of `url` or `service` must be specified.
    url: ?[]const u8 = null,
};
