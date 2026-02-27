// Auto-generated from Kubernetes OpenAPI spec.
// Do not edit manually. Regenerate with: zig build generate

const std = @import("std");
const json = std.json;
const meta_v1 = @import("meta_v1.zig");

/// ExemptPriorityLevelConfiguration describes the configurable aspects of the handling of exempt requests. In the mandatory exempt configuration object the values in the fields here can be modified by authorized users, unlike the rest of the `spec`.
pub const FlowcontrolV1ExemptPriorityLevelConfiguration = struct {
    /// `lendablePercent` prescribes the fraction of the level's NominalCL that can be borrowed by other priority levels.  This value of this field must be between 0 and 100, inclusive, and it defaults to 0. The number of seats that other levels can borrow from this level, known as this level's LendableConcurrencyLimit (LendableCL), is defined as follows.
    lendablePercent: ?i32 = null,
    /// `nominalConcurrencyShares` (NCS) contributes to the computation of the NominalConcurrencyLimit (NominalCL) of this level. This is the number of execution seats nominally reserved for this priority level. This DOES NOT limit the dispatching from this priority level but affects the other priority levels through the borrowing mechanism. The server's concurrency limit (ServerCL) is divided among all the priority levels in proportion to their NCS values:
    nominalConcurrencyShares: ?i32 = null,
};

/// FlowDistinguisherMethod specifies the method of a flow distinguisher.
pub const FlowcontrolV1FlowDistinguisherMethod = struct {
    /// `type` is the type of flow distinguisher method The supported types are "ByUser" and "ByNamespace". Required.
    type: []const u8,
};

/// FlowSchema defines the schema of a group of flows. Note that a flow is made up of a set of inbound API requests with similar attributes and is identified by a pair of strings: the name of the FlowSchema and a "flow distinguisher".
pub const FlowcontrolV1FlowSchema = struct {
    pub const resource_meta = .{
        .group = "flowcontrol.apiserver.k8s.io",
        .version = "v1",
        .kind = "FlowSchema",
        .resource = "flowschemas",
        .namespaced = false,
        .list_kind = FlowcontrolV1FlowSchemaList,
    };

    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// `metadata` is the standard object's metadata. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// `spec` is the specification of the desired behavior of a FlowSchema. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#spec-and-status
    spec: ?FlowcontrolV1FlowSchemaSpec = null,
    /// `status` is the current status of a FlowSchema. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#spec-and-status
    status: ?FlowcontrolV1FlowSchemaStatus = null,
};

/// FlowSchemaCondition describes conditions for a FlowSchema.
pub const FlowcontrolV1FlowSchemaCondition = struct {
    /// `lastTransitionTime` is the last time the condition transitioned from one status to another.
    lastTransitionTime: ?meta_v1.MetaV1Time = null,
    /// `message` is a human-readable message indicating details about last transition.
    message: ?[]const u8 = null,
    /// `reason` is a unique, one-word, CamelCase reason for the condition's last transition.
    reason: ?[]const u8 = null,
    /// `status` is the status of the condition. Can be True, False, Unknown. Required.
    status: ?[]const u8 = null,
    /// `type` is the type of the condition. Required.
    type: ?[]const u8 = null,
};

/// FlowSchemaList is a list of FlowSchema objects.
pub const FlowcontrolV1FlowSchemaList = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// `items` is a list of FlowSchemas.
    items: []const FlowcontrolV1FlowSchema,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// `metadata` is the standard list metadata. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata
    metadata: ?meta_v1.MetaV1ListMeta = null,
};

/// FlowSchemaSpec describes how the FlowSchema's specification looks like.
pub const FlowcontrolV1FlowSchemaSpec = struct {
    /// `distinguisherMethod` defines how to compute the flow distinguisher for requests that match this schema. `nil` specifies that the distinguisher is disabled and thus will always be the empty string.
    distinguisherMethod: ?FlowcontrolV1FlowDistinguisherMethod = null,
    /// `matchingPrecedence` is used to choose among the FlowSchemas that match a given request. The chosen FlowSchema is among those with the numerically lowest (which we take to be logically highest) MatchingPrecedence.  Each MatchingPrecedence value must be ranged in [1,10000]. Note that if the precedence is not specified, it will be set to 1000 as default.
    matchingPrecedence: ?i32 = null,
    /// `priorityLevelConfiguration` should reference a PriorityLevelConfiguration in the cluster. If the reference cannot be resolved, the FlowSchema will be ignored and marked as invalid in its status. Required.
    priorityLevelConfiguration: FlowcontrolV1PriorityLevelConfigurationReference,
    /// `rules` describes which requests will match this flow schema. This FlowSchema matches a request if and only if at least one member of rules matches the request. if it is an empty slice, there will be no requests matching the FlowSchema.
    rules: ?[]const FlowcontrolV1PolicyRulesWithSubjects = null,
};

/// FlowSchemaStatus represents the current state of a FlowSchema.
pub const FlowcontrolV1FlowSchemaStatus = struct {
    /// `conditions` is a list of the current states of FlowSchema.
    conditions: ?[]const FlowcontrolV1FlowSchemaCondition = null,
};

/// GroupSubject holds detailed information for group-kind subject.
pub const FlowcontrolV1GroupSubject = struct {
    /// name is the user group that matches, or "*" to match all user groups. See https://github.com/kubernetes/apiserver/blob/master/pkg/authentication/user/user.go for some well-known group names. Required.
    name: []const u8,
};

/// LimitResponse defines how to handle requests that can not be executed right now.
pub const FlowcontrolV1LimitResponse = struct {
    /// `queuing` holds the configuration parameters for queuing. This field may be non-empty only if `type` is `"Queue"`.
    queuing: ?FlowcontrolV1QueuingConfiguration = null,
    /// `type` is "Queue" or "Reject". "Queue" means that requests that can not be executed upon arrival are held in a queue until they can be executed or a queuing limit is reached. "Reject" means that requests that can not be executed upon arrival are rejected. Required.
    type: []const u8,
};

/// LimitedPriorityLevelConfiguration specifies how to handle requests that are subject to limits. It addresses two issues:
pub const FlowcontrolV1LimitedPriorityLevelConfiguration = struct {
    /// `borrowingLimitPercent`, if present, configures a limit on how many seats this priority level can borrow from other priority levels. The limit is known as this level's BorrowingConcurrencyLimit (BorrowingCL) and is a limit on the total number of seats that this level may borrow at any one time. This field holds the ratio of that limit to the level's nominal concurrency limit. When this field is non-nil, it must hold a non-negative integer and the limit is calculated as follows.
    borrowingLimitPercent: ?i32 = null,
    /// `lendablePercent` prescribes the fraction of the level's NominalCL that can be borrowed by other priority levels. The value of this field must be between 0 and 100, inclusive, and it defaults to 0. The number of seats that other levels can borrow from this level, known as this level's LendableConcurrencyLimit (LendableCL), is defined as follows.
    lendablePercent: ?i32 = null,
    /// `limitResponse` indicates what to do with requests that can not be executed right now
    limitResponse: ?FlowcontrolV1LimitResponse = null,
    /// `nominalConcurrencyShares` (NCS) contributes to the computation of the NominalConcurrencyLimit (NominalCL) of this level. This is the number of execution seats available at this priority level. This is used both for requests dispatched from this priority level as well as requests dispatched from other priority levels borrowing seats from this level. The server's concurrency limit (ServerCL) is divided among the Limited priority levels in proportion to their NCS values:
    nominalConcurrencyShares: ?i32 = null,
};

/// NonResourcePolicyRule is a predicate that matches non-resource requests according to their verb and the target non-resource URL. A NonResourcePolicyRule matches a request if and only if both (a) at least one member of verbs matches the request and (b) at least one member of nonResourceURLs matches the request.
pub const FlowcontrolV1NonResourcePolicyRule = struct {
    /// `nonResourceURLs` is a set of url prefixes that a user should have access to and may not be empty. For example:
    nonResourceURLs: []const []const u8,
    /// `verbs` is a list of matching verbs and may not be empty. "*" matches all verbs. If it is present, it must be the only entry. Required.
    verbs: []const []const u8,
};

/// PolicyRulesWithSubjects prescribes a test that applies to a request to an apiserver. The test considers the subject making the request, the verb being requested, and the resource to be acted upon. This PolicyRulesWithSubjects matches a request if and only if both (a) at least one member of subjects matches the request and (b) at least one member of resourceRules or nonResourceRules matches the request.
pub const FlowcontrolV1PolicyRulesWithSubjects = struct {
    /// `nonResourceRules` is a list of NonResourcePolicyRules that identify matching requests according to their verb and the target non-resource URL.
    nonResourceRules: ?[]const FlowcontrolV1NonResourcePolicyRule = null,
    /// `resourceRules` is a slice of ResourcePolicyRules that identify matching requests according to their verb and the target resource. At least one of `resourceRules` and `nonResourceRules` has to be non-empty.
    resourceRules: ?[]const FlowcontrolV1ResourcePolicyRule = null,
    /// subjects is the list of normal user, serviceaccount, or group that this rule cares about. There must be at least one member in this slice. A slice that includes both the system:authenticated and system:unauthenticated user groups matches every request. Required.
    subjects: []const FlowcontrolV1Subject,
};

/// PriorityLevelConfiguration represents the configuration of a priority level.
pub const FlowcontrolV1PriorityLevelConfiguration = struct {
    pub const resource_meta = .{
        .group = "flowcontrol.apiserver.k8s.io",
        .version = "v1",
        .kind = "PriorityLevelConfiguration",
        .resource = "prioritylevelconfigurations",
        .namespaced = false,
        .list_kind = FlowcontrolV1PriorityLevelConfigurationList,
    };

    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// `metadata` is the standard object's metadata. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// `spec` is the specification of the desired behavior of a "request-priority". More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#spec-and-status
    spec: ?FlowcontrolV1PriorityLevelConfigurationSpec = null,
    /// `status` is the current status of a "request-priority". More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#spec-and-status
    status: ?FlowcontrolV1PriorityLevelConfigurationStatus = null,
};

/// PriorityLevelConfigurationCondition defines the condition of priority level.
pub const FlowcontrolV1PriorityLevelConfigurationCondition = struct {
    /// `lastTransitionTime` is the last time the condition transitioned from one status to another.
    lastTransitionTime: ?meta_v1.MetaV1Time = null,
    /// `message` is a human-readable message indicating details about last transition.
    message: ?[]const u8 = null,
    /// `reason` is a unique, one-word, CamelCase reason for the condition's last transition.
    reason: ?[]const u8 = null,
    /// `status` is the status of the condition. Can be True, False, Unknown. Required.
    status: ?[]const u8 = null,
    /// `type` is the type of the condition. Required.
    type: ?[]const u8 = null,
};

/// PriorityLevelConfigurationList is a list of PriorityLevelConfiguration objects.
pub const FlowcontrolV1PriorityLevelConfigurationList = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// `items` is a list of request-priorities.
    items: []const FlowcontrolV1PriorityLevelConfiguration,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// `metadata` is the standard object's metadata. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata
    metadata: ?meta_v1.MetaV1ListMeta = null,
};

/// PriorityLevelConfigurationReference contains information that points to the "request-priority" being used.
pub const FlowcontrolV1PriorityLevelConfigurationReference = struct {
    /// `name` is the name of the priority level configuration being referenced Required.
    name: []const u8,
};

/// PriorityLevelConfigurationSpec specifies the configuration of a priority level.
pub const FlowcontrolV1PriorityLevelConfigurationSpec = struct {
    /// `exempt` specifies how requests are handled for an exempt priority level. This field MUST be empty if `type` is `"Limited"`. This field MAY be non-empty if `type` is `"Exempt"`. If empty and `type` is `"Exempt"` then the default values for `ExemptPriorityLevelConfiguration` apply.
    exempt: ?FlowcontrolV1ExemptPriorityLevelConfiguration = null,
    /// `limited` specifies how requests are handled for a Limited priority level. This field must be non-empty if and only if `type` is `"Limited"`.
    limited: ?FlowcontrolV1LimitedPriorityLevelConfiguration = null,
    /// `type` indicates whether this priority level is subject to limitation on request execution.  A value of `"Exempt"` means that requests of this priority level are not subject to a limit (and thus are never queued) and do not detract from the capacity made available to other priority levels.  A value of `"Limited"` means that (a) requests of this priority level _are_ subject to limits and (b) some of the server's limited capacity is made available exclusively to this priority level. Required.
    type: []const u8,
};

/// PriorityLevelConfigurationStatus represents the current state of a "request-priority".
pub const FlowcontrolV1PriorityLevelConfigurationStatus = struct {
    /// `conditions` is the current state of "request-priority".
    conditions: ?[]const FlowcontrolV1PriorityLevelConfigurationCondition = null,
};

/// QueuingConfiguration holds the configuration parameters for queuing
pub const FlowcontrolV1QueuingConfiguration = struct {
    /// `handSize` is a small positive number that configures the shuffle sharding of requests into queues.  When enqueuing a request at this priority level the request's flow identifier (a string pair) is hashed and the hash value is used to shuffle the list of queues and deal a hand of the size specified here.  The request is put into one of the shortest queues in that hand. `handSize` must be no larger than `queues`, and should be significantly smaller (so that a few heavy flows do not saturate most of the queues).  See the user-facing documentation for more extensive guidance on setting this field.  This field has a default value of 8.
    handSize: ?i32 = null,
    /// `queueLengthLimit` is the maximum number of requests allowed to be waiting in a given queue of this priority level at a time; excess requests are rejected.  This value must be positive.  If not specified, it will be defaulted to 50.
    queueLengthLimit: ?i32 = null,
    /// `queues` is the number of queues for this priority level. The queues exist independently at each apiserver. The value must be positive.  Setting it to 1 effectively precludes shufflesharding and thus makes the distinguisher method of associated flow schemas irrelevant.  This field has a default value of 64.
    queues: ?i32 = null,
};

/// ResourcePolicyRule is a predicate that matches some resource requests, testing the request's verb and the target resource. A ResourcePolicyRule matches a resource request if and only if: (a) at least one member of verbs matches the request, (b) at least one member of apiGroups matches the request, (c) at least one member of resources matches the request, and (d) either (d1) the request does not specify a namespace (i.e., `Namespace==""`) and clusterScope is true or (d2) the request specifies a namespace and least one member of namespaces matches the request's namespace.
pub const FlowcontrolV1ResourcePolicyRule = struct {
    /// `apiGroups` is a list of matching API groups and may not be empty. "*" matches all API groups and, if present, must be the only entry. Required.
    apiGroups: []const []const u8,
    /// `clusterScope` indicates whether to match requests that do not specify a namespace (which happens either because the resource is not namespaced or the request targets all namespaces). If this field is omitted or false then the `namespaces` field must contain a non-empty list.
    clusterScope: ?bool = null,
    /// `namespaces` is a list of target namespaces that restricts matches.  A request that specifies a target namespace matches only if either (a) this list contains that target namespace or (b) this list contains "*".  Note that "*" matches any specified namespace but does not match a request that _does not specify_ a namespace (see the `clusterScope` field for that). This list may be empty, but only if `clusterScope` is true.
    namespaces: ?[]const []const u8 = null,
    /// `resources` is a list of matching resources (i.e., lowercase and plural) with, if desired, subresource.  For example, [ "services", "nodes/status" ].  This list may not be empty. "*" matches all resources and, if present, must be the only entry. Required.
    resources: []const []const u8,
    /// `verbs` is a list of matching verbs and may not be empty. "*" matches all verbs and, if present, must be the only entry. Required.
    verbs: []const []const u8,
};

/// ServiceAccountSubject holds detailed information for service-account-kind subject.
pub const FlowcontrolV1ServiceAccountSubject = struct {
    /// `name` is the name of matching ServiceAccount objects, or "*" to match regardless of name. Required.
    name: []const u8,
    /// `namespace` is the namespace of matching ServiceAccount objects. Required.
    namespace: []const u8,
};

/// Subject matches the originator of a request, as identified by the request authentication system. There are three ways of matching an originator; by user, group, or service account.
pub const FlowcontrolV1Subject = struct {
    /// `group` matches based on user group name.
    group: ?FlowcontrolV1GroupSubject = null,
    /// `kind` indicates which one of the other fields is non-empty. Required
    kind: []const u8,
    /// `serviceAccount` matches ServiceAccounts.
    serviceAccount: ?FlowcontrolV1ServiceAccountSubject = null,
    /// `user` matches based on username.
    user: ?FlowcontrolV1UserSubject = null,
};

/// UserSubject holds detailed information for user-kind subject.
pub const FlowcontrolV1UserSubject = struct {
    /// `name` is the username that matches, or "*" to match all usernames. Required.
    name: []const u8,
};
