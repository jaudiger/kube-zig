// Auto-generated from Kubernetes OpenAPI spec.
// Do not edit manually. Regenerate with: zig build generate

const std = @import("std");
const json = std.json;
const meta_v1 = @import("meta_v1.zig");

/// AllCompositeDisruptionMode means that children of a CompositePodGroup can only be disrupted or preempted together.
pub const SchedulingV1beta1AllCompositeDisruptionMode = json.ArrayHashMap(json.Value);

/// AllDisruptionMode specifies that children can only be disrupted together.
pub const SchedulingV1beta1AllDisruptionMode = json.ArrayHashMap(json.Value);

/// BasicSchedulingPolicy indicates that standard Kubernetes scheduling behavior should be used.
pub const SchedulingV1beta1BasicSchedulingPolicy = json.ArrayHashMap(json.Value);

/// CompositeBasicSchedulingPolicy indicates that the groups belonging to the composite group should be scheduled independently.
pub const SchedulingV1beta1CompositeBasicSchedulingPolicy = json.ArrayHashMap(json.Value);

/// CompositeDisruptionMode defines how individual entities within a composite pod group can be disrupted. Exactly one mode must be set.
pub const SchedulingV1beta1CompositeDisruptionMode = struct {
    /// all specifies that all children groups can only be disrupted together.
    all: ?SchedulingV1beta1AllCompositeDisruptionMode = null,
    /// single specifies that children groups can be disrupted independently from each other.
    single: ?SchedulingV1beta1SingleCompositeDisruptionMode = null,
};

/// CompositeGangSchedulingPolicy indicates that the groups belonging to the composite group should be scheduled using all-or-nothing semantics.
pub const SchedulingV1beta1CompositeGangSchedulingPolicy = struct {
    /// minGroupCount is the minimum number of child groups that must be schedulable or scheduled at the same time for the scheduler to admit the entire group. It must be a positive integer.
    minGroupCount: i32,
};

/// CompositePodGroupSchedulingConstraints defines scheduling constraints (e.g. topology) for a CompositePodGroup.
pub const SchedulingV1beta1CompositePodGroupSchedulingConstraints = struct {
    /// topology defines the topology constraints for the composite pod group. Currently only a single topology constraint can be specified. This may change in the future.
    topology: ?[]const SchedulingV1beta1TopologyConstraint = null,
};

/// CompositePodGroupSchedulingPolicy defines the scheduling configuration for a CompositePodGroup. Exactly one policy must be set.
pub const SchedulingV1beta1CompositePodGroupSchedulingPolicy = struct {
    /// basic specifies that the groups of this composite group should be scheduled independently. This field is immutable.
    basic: ?SchedulingV1beta1CompositeBasicSchedulingPolicy = null,
    /// gang specifies that the groups of this composite group should be scheduled using all-or-nothing semantics.
    gang: ?SchedulingV1beta1CompositeGangSchedulingPolicy = null,
};

/// CompositePodGroupTemplate represents a template for a CompositePodGroup with a scheduling policy.
pub const SchedulingV1beta1CompositePodGroupTemplate = struct {
    /// compositePodGroupTemplates is the list of templates for children CompositePodGroups. The maximum number of templates is 8. At least one entry in CompositePodGroupTemplates or PodGroupTemplates must be set.
    compositePodGroupTemplates: ?[]const SchedulingV1beta1CompositePodGroupTemplate = null,
    /// disruptionMode defines the mode in which a given CompositePodGroup can be disrupted. One of Single, All. This field is immutable.
    disruptionMode: ?SchedulingV1beta1CompositeDisruptionMode = null,
    /// name is a unique identifier for the CompositePodGroupTemplate within the Workload. It must be a DNS label. This field is required.
    name: []const u8,
    /// podGroupTemplates is the list of templates for children PodGroups. The maximum number of templates is 8. At least one entry in CompositePodGroupTemplates or PodGroupTemplates must be set.
    podGroupTemplates: ?[]const SchedulingV1beta1PodGroupTemplate = null,
    /// preemptionPolicy is the Policy for preempting pods/podgroups with lower priority. One of Never, PreemptLowerPriority. This field is immutable. This field is available only when the PodGroupPreemptionPolicy feature gate is enabled.
    preemptionPolicy: ?[]const u8 = null,
    /// priority is the value of priority of composite pod groups created from this template. Various system components use this field to find the priority of the composite pod group. When Priority Admission Controller is enabled, it prevents users from setting this field. The admission controller populates this field from PriorityClassName. The higher the value, the higher the priority. This field is immutable.
    priority: ?i32 = null,
    /// priorityClassName indicates the priority that should be considered when scheduling a composite pod group created from this template. If no priority class is specified, admission control can set this to the global default priority class if it exists. Otherwise, composite pod groups created from this template will have the priority set to zero. This field is immutable.
    priorityClassName: ?[]const u8 = null,
    /// schedulingConstraints defines optional scheduling constraints (e.g. topology) for this CompositePodGroupTemplate. This field is immutable.
    schedulingConstraints: ?SchedulingV1beta1CompositePodGroupSchedulingConstraints = null,
    /// schedulingPolicy defines the scheduling policy for this template.
    schedulingPolicy: SchedulingV1beta1CompositePodGroupSchedulingPolicy,
};

/// DisruptionMode defines how individual entities within a group can be disrupted. Exactly one mode can be set.
pub const SchedulingV1beta1DisruptionMode = struct {
    /// all specifies that all children can only be disrupted together.
    all: ?SchedulingV1beta1AllDisruptionMode = null,
    /// single specifies that children can be disrupted independently from each other.
    single: ?SchedulingV1beta1SingleDisruptionMode = null,
};

/// GangSchedulingPolicy defines the parameters for gang scheduling.
pub const SchedulingV1beta1GangSchedulingPolicy = struct {
    /// minCount is the minimum number of pods that must be schedulable or scheduled at the same time for the scheduler to admit the entire group. It must be a positive integer. This field is mutable to support workload scaling.
    minCount: i32,
};

/// PodGroup represents a runtime instance of pods grouped together. PodGroups are created by workload controllers (Job, LWS, JobSet, etc...) from Workload.podGroupTemplates. PodGroup API enablement is toggled by the GenericWorkload feature gate.
pub const SchedulingV1beta1PodGroup = struct {
    pub const resource_meta = .{
        .group = "scheduling.k8s.io",
        .version = "v1beta1",
        .kind = "PodGroup",
        .resource = "podgroups",
        .namespaced = true,
        .list_kind = SchedulingV1beta1PodGroupList,
    };

    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// metadata is the standard object metadata. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// spec defines the desired state of the PodGroup.
    spec: SchedulingV1beta1PodGroupSpec,
    /// status represents the current observed state of the PodGroup.
    status: ?SchedulingV1beta1PodGroupStatus = null,
};

/// PodGroupList contains a list of PodGroup resources.
pub const SchedulingV1beta1PodGroupList = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Items is the list of PodGroups.
    items: []const SchedulingV1beta1PodGroup,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard list metadata.
    metadata: ?meta_v1.MetaV1ListMeta = null,
};

/// PodGroupResourceClaim references exactly one ResourceClaim, either directly or by naming a ResourceClaimTemplate which is then turned into a ResourceClaim for the PodGroup.
pub const SchedulingV1beta1PodGroupResourceClaim = struct {
    /// name uniquely identifies this resource claim inside the PodGroup. This must be a DNS_LABEL.
    name: []const u8,
    /// resourceClaimName is the name of a ResourceClaim object in the same namespace as this PodGroup. The ResourceClaim will be reserved for the PodGroup instead of its individual pods.
    resourceClaimName: ?[]const u8 = null,
    /// resourceClaimTemplateName is the name of a ResourceClaimTemplate object in the same namespace as this PodGroup.
    resourceClaimTemplateName: ?[]const u8 = null,
};

/// PodGroupResourceClaimStatus is stored in the PodGroupStatus for each PodGroupResourceClaim which references a ResourceClaimTemplate. It stores the generated name for the corresponding ResourceClaim.
pub const SchedulingV1beta1PodGroupResourceClaimStatus = struct {
    /// name uniquely identifies this resource claim inside the PodGroup. This must match the name of an entry in podgroup.spec.resourceClaims, which implies that the string must be a DNS_LABEL.
    name: []const u8,
    /// resourceClaimName is the name of the ResourceClaim that was generated for the PodGroup in the namespace of the PodGroup. If this is unset, then generating a ResourceClaim was not necessary. The podgroup.spec.resourceClaims entry can be ignored in this case.
    resourceClaimName: ?[]const u8 = null,
};

/// PodGroupSchedulingConstraints defines scheduling constraints (e.g. topology) for a PodGroup.
pub const SchedulingV1beta1PodGroupSchedulingConstraints = struct {
    /// topology defines the topology constraints for the pod group. Currently only a single topology constraint can be specified. This may change in the future.
    topology: ?[]const SchedulingV1beta1TopologyConstraint = null,
};

/// PodGroupSchedulingPolicy defines the scheduling configuration for a PodGroup. Exactly one policy must be set. The policy is chosen at creation time by setting either the Basic or Gang field. The PodGroup may not change policy after creation. Fields within chosen policy may be updated after creation when their individual fields allow it.
pub const SchedulingV1beta1PodGroupSchedulingPolicy = struct {
    /// basic specifies that the pods in this group should be scheduled using standard Kubernetes scheduling behavior. Setting this field at group creation time opts this group to basic scheduling; this field cannot be changed afterward.
    basic: ?SchedulingV1beta1BasicSchedulingPolicy = null,
    /// gang specifies that the pods in this group should be scheduled using all-or-nothing semantics. Setting this field at group creation time opts this group to gang scheduling; this field cannot be set or unset afterward. The minCount field within Gang scheduling policy remains mutable after group creation.
    gang: ?SchedulingV1beta1GangSchedulingPolicy = null,
};

/// PodGroupSpec defines the desired state of a PodGroup.
pub const SchedulingV1beta1PodGroupSpec = struct {
    /// disruptionMode defines the mode in which a given PodGroup can be disrupted. Controllers are expected to fill this field by copying it from a PodGroupTemplate. One of Single, All. Defaults to Single if unset. This field is immutable.
    disruptionMode: ?SchedulingV1beta1DisruptionMode = null,
    /// parentCompositePodGroupName contains the name of the parent composite pod group within the same namespace as this pod group. If it's nil, then this pod group is a root of a workload's hierarchy. This field is used only when the CompositePodGroup feature gate is enabled. This field is immutable.
    parentCompositePodGroupName: ?[]const u8 = null,
    /// preemptionPolicy is the Policy for preempting pods/podgroups with lower priority. One of Never, PreemptLowerPriority. Defaults to PreemptLowerPriority if unset. When Priority Admission Controller is enabled, it populates this field from PriorityClassName, and defaults to PreemptLowerPriority if value is unset in PriorityClass. This field is immutable. This field is available only when the PodGroupPreemptionPolicy feature gate is enabled.
    preemptionPolicy: ?[]const u8 = null,
    /// priority is the value of priority of this pod group. Various system components use this field to find the priority of the pod group. When Priority Admission Controller is enabled, it prevents users from setting this field. The admission controller populates this field from PriorityClassName. The higher the value, the higher the priority. This field is immutable.
    priority: ?i32 = null,
    /// priorityClassName defines the priority that should be considered when scheduling this pod group. Controllers are expected to fill this field by copying it from a PodGroupTemplate. Otherwise, it is validated and resolved similarly to the PriorityClassName on PodGroupTemplate (i.e. if no priority class is specified, admission control can set this to the global default priority class if it exists. Otherwise, the pod group's priority will be zero). This field is immutable.
    priorityClassName: ?[]const u8 = null,
    /// resourceClaims defines which ResourceClaims may be shared among Pods in the group. Pods consume the devices allocated to a PodGroup's claim by defining a claim in its own Spec.ResourceClaims that matches the PodGroup's claim exactly. The claim must have the same name and refer to the same ResourceClaim or ResourceClaimTemplate.
    resourceClaims: ?[]const SchedulingV1beta1PodGroupResourceClaim = null,
    /// schedulingConstraints defines optional scheduling constraints (e.g. topology) for this PodGroup. Controllers are expected to fill this field by copying it from a PodGroupTemplate. This field is immutable. This field is only available when the TopologyAwareWorkloadScheduling feature gate is enabled.
    schedulingConstraints: ?SchedulingV1beta1PodGroupSchedulingConstraints = null,
    /// schedulingPolicy defines the scheduling policy for this instance of the PodGroup. Controllers are expected to fill this field by copying it from a PodGroupTemplate.
    schedulingPolicy: SchedulingV1beta1PodGroupSchedulingPolicy,
    /// workloadRef references an optional PodGroup template within the Workload object that was used to create the PodGroup. This field is immutable.
    workloadRef: ?SchedulingV1beta1WorkloadReference = null,
};

/// PodGroupStatus represents information about the status of a pod group.
pub const SchedulingV1beta1PodGroupStatus = struct {
    /// conditions represent the latest observations of the PodGroup's state.
    conditions: ?[]const meta_v1.MetaV1Condition = null,
    /// resourceClaimStatuses is status of resource claims.
    resourceClaimStatuses: ?[]const SchedulingV1beta1PodGroupResourceClaimStatus = null,
};

/// PodGroupTemplate represents a template for a set of pods with a scheduling policy.
pub const SchedulingV1beta1PodGroupTemplate = struct {
    /// disruptionMode defines the mode in which a given PodGroup can be disrupted. One of Single, All. This field is immutable.
    disruptionMode: ?SchedulingV1beta1DisruptionMode = null,
    /// name is a unique identifier for the PodGroupTemplate within the Workload. It must be a DNS label. This field is immutable.
    name: []const u8,
    /// preemptionPolicy is the Policy for preempting pods/podgroups with lower priority. One of Never, PreemptLowerPriority. This field is immutable. This field is available only when the PodGroupPreemptionPolicy feature gate is enabled.
    preemptionPolicy: ?[]const u8 = null,
    /// priority is the value of priority of pod groups created from this template. Various system components use this field to find the priority of the pod group. The higher the value, the higher the priority. This field is immutable.
    priority: ?i32 = null,
    /// priorityClassName indicates the priority that should be considered when scheduling a pod group created from this template. This field is immutable.
    priorityClassName: ?[]const u8 = null,
    /// resourceClaims defines which ResourceClaims may be shared among Pods in the group. Pods consume the devices allocated to a PodGroup's claim by defining a claim in its own Spec.ResourceClaims that matches the PodGroup's claim exactly. The claim must have the same name and refer to the same ResourceClaim or ResourceClaimTemplate.
    resourceClaims: ?[]const SchedulingV1beta1PodGroupResourceClaim = null,
    /// schedulingConstraints defines optional scheduling constraints (e.g. topology) for this PodGroupTemplate. This field is only available when the TopologyAwareWorkloadScheduling feature gate is enabled. This field is immutable.
    schedulingConstraints: ?SchedulingV1beta1PodGroupSchedulingConstraints = null,
    /// schedulingPolicy defines the scheduling policy for this PodGroupTemplate.
    schedulingPolicy: SchedulingV1beta1PodGroupSchedulingPolicy,
};

/// SingleCompositeDisruptionMode means that individual children of a CompositePodGroup can be disrupted or preempted independently.
pub const SchedulingV1beta1SingleCompositeDisruptionMode = json.ArrayHashMap(json.Value);

/// SingleDisruptionMode specifies that children can be disrupted independently.
pub const SchedulingV1beta1SingleDisruptionMode = json.ArrayHashMap(json.Value);

/// TopologyConstraint defines a topology constraint for a PodGroup.
pub const SchedulingV1beta1TopologyConstraint = struct {
    /// key specifies the key of the node label representing the topology domain. All pods within the PodGroup must be colocated within the same domain instance. Different PodGroups can land on different domain instances even if they derive from the same PodGroupTemplate. Examples: "topology.kubernetes.io/rack"
    key: []const u8,
};

/// TypedLocalObjectReference allows to reference typed object inside the same namespace.
pub const SchedulingV1beta1TypedLocalObjectReference = struct {
    /// apiGroup is the group for the resource being referenced. If apiGroup is empty, the specified Kind must be in the core API group. For any other third-party types, setting apiGroup is required. It must be a DNS subdomain.
    apiGroup: ?[]const u8 = null,
    /// kind is the type of resource being referenced. It must be a path segment name.
    kind: []const u8,
    /// name is the name of resource being referenced. It must be a path segment name.
    name: []const u8,
};

/// Workload allows for expressing scheduling constraints that should be used when managing the lifecycle of workloads from the scheduling perspective, including scheduling, preemption, eviction and other phases. Workload API enablement is toggled by the GenericWorkload feature gate.
pub const SchedulingV1beta1Workload = struct {
    pub const resource_meta = .{
        .group = "scheduling.k8s.io",
        .version = "v1beta1",
        .kind = "Workload",
        .resource = "workloads",
        .namespaced = true,
        .list_kind = SchedulingV1beta1WorkloadList,
    };

    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// metadata is the standard object metadata. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// spec defines the desired behavior of a Workload.
    spec: SchedulingV1beta1WorkloadSpec,
};

/// WorkloadList contains a list of Workload resources.
pub const SchedulingV1beta1WorkloadList = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// items is the list of Workloads.
    items: []const SchedulingV1beta1Workload,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// metadata is the standard list metadata.
    metadata: ?meta_v1.MetaV1ListMeta = null,
};

/// WorkloadReference references the Workload object together with the template that was used to create a particular PodGroup.
pub const SchedulingV1beta1WorkloadReference = struct {
    /// templateName is the name of a template within the Workload object that was used to create a pod group. It must be a DNS label. This field is required.
    templateName: []const u8,
    /// workloadName is the name of the Workload object that contains a template that was used when creating a pod group. It must be a DNS name. This field is required.
    workloadName: []const u8,
};

/// WorkloadSpec defines the desired state of a Workload.
pub const SchedulingV1beta1WorkloadSpec = struct {
    /// compositePodGroupTemplates is the list of CompositePodGroup templates that make up the Workload. The maximum number of templates is 8. This field is immutable. Exactly one of CompositePodGroupTemplates and PodGroupTemplates must be set.
    compositePodGroupTemplates: ?[]const SchedulingV1beta1CompositePodGroupTemplate = null,
    /// controllerRef is an optional reference to the controlling object, such as a Deployment or Job. This field is intended for use by tools like CLIs to provide a link back to the original workload definition. This field is immutable.
    controllerRef: ?SchedulingV1beta1TypedLocalObjectReference = null,
    /// podGroupTemplates is the list of templates that make up the Workload. The maximum number of templates is 8. Templates cannot be added or removed after the workload is created. Existing templates may still be updated where their individual fields allow it. Exactly one of CompositePodGroupTemplates and PodGroupTemplates must be set.
    podGroupTemplates: ?[]const SchedulingV1beta1PodGroupTemplate = null,
};
