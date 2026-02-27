// Auto-generated from Kubernetes OpenAPI spec.
// Do not edit manually. Regenerate with: zig build generate

const std = @import("std");
const json = std.json;
const api_resource = @import("api_resource.zig");
const core_v1 = @import("core_v1.zig");
const meta_v1 = @import("meta_v1.zig");
const pkg_runtime = @import("pkg_runtime.zig");

/// AllocatedDeviceStatus contains the status of an allocated device, if the driver chooses to report it. This may include driver-specific information.
pub const ResourceV1beta1AllocatedDeviceStatus = struct {
    /// Conditions contains the latest observation of the device's state. If the device has been configured according to the class and claim config references, the `Ready` condition should be True.
    conditions: ?[]const meta_v1.MetaV1Condition = null,
    /// Data contains arbitrary driver-specific data.
    data: ?pkg_runtime.PkgRuntimeRawExtension = null,
    /// Device references one device instance via its name in the driver's resource pool. It must be a DNS label.
    device: []const u8,
    /// Driver specifies the name of the DRA driver whose kubelet plugin should be invoked to process the allocation once the claim is needed on a node.
    driver: []const u8,
    /// NetworkData contains network-related information specific to the device.
    networkData: ?ResourceV1beta1NetworkDeviceData = null,
    /// This name together with the driver name and the device name field identify which device was allocated (`<driver name>/<pool name>/<device name>`).
    pool: []const u8,
    /// ShareID uniquely identifies an individual allocation share of the device.
    shareID: ?[]const u8 = null,
};

/// AllocationResult contains attributes of an allocated resource.
pub const ResourceV1beta1AllocationResult = struct {
    /// AllocationTimestamp stores the time when the resources were allocated. This field is not guaranteed to be set, in which case that time is unknown.
    allocationTimestamp: ?meta_v1.MetaV1Time = null,
    /// Devices is the result of allocating devices.
    devices: ?ResourceV1beta1DeviceAllocationResult = null,
    /// NodeSelector defines where the allocated resources are available. If unset, they are available everywhere.
    nodeSelector: ?core_v1.CoreV1NodeSelector = null,
};

/// BasicDevice defines one device instance.
pub const ResourceV1beta1BasicDevice = struct {
    /// AllNodes indicates that all nodes have access to the device.
    allNodes: ?bool = null,
    /// AllowMultipleAllocations marks whether the device is allowed to be allocated to multiple DeviceRequests.
    allowMultipleAllocations: ?bool = null,
    /// Attributes defines the set of attributes for this device. The name of each attribute must be unique in that set.
    attributes: ?json.ArrayHashMap(ResourceV1beta1DeviceAttribute) = null,
    /// BindingConditions defines the conditions for proceeding with binding. All of these conditions must be set in the per-device status conditions with a value of True to proceed with binding the pod to the node while scheduling the pod.
    bindingConditions: ?[]const []const u8 = null,
    /// BindingFailureConditions defines the conditions for binding failure. They may be set in the per-device status conditions. If any is true, a binding failure occurred.
    bindingFailureConditions: ?[]const []const u8 = null,
    /// BindsToNode indicates if the usage of an allocation involving this device has to be limited to exactly the node that was chosen when allocating the claim. If set to true, the scheduler will set the ResourceClaim.Status.Allocation.NodeSelector to match the node where the allocation was made.
    bindsToNode: ?bool = null,
    /// Capacity defines the set of capacities for this device. The name of each capacity must be unique in that set.
    capacity: ?json.ArrayHashMap(ResourceV1beta1DeviceCapacity) = null,
    /// ConsumesCounters defines a list of references to sharedCounters and the set of counters that the device will consume from those counter sets.
    consumesCounters: ?[]const ResourceV1beta1DeviceCounterConsumption = null,
    /// NodeName identifies the node where the device is available.
    nodeName: ?[]const u8 = null,
    /// NodeSelector defines the nodes where the device is available.
    nodeSelector: ?core_v1.CoreV1NodeSelector = null,
    /// If specified, these are the driver-defined taints.
    taints: ?[]const ResourceV1beta1DeviceTaint = null,
};

/// CELDeviceSelector contains a CEL expression for selecting a device.
pub const ResourceV1beta1CELDeviceSelector = struct {
    /// Expression is a CEL expression which evaluates a single device. It must evaluate to true when the device under consideration satisfies the desired criteria, and false when it does not. Any other result is an error and causes allocation of devices to abort.
    expression: []const u8,
};

/// CapacityRequestPolicy defines how requests consume device capacity.
pub const ResourceV1beta1CapacityRequestPolicy = struct {
    /// Default specifies how much of this capacity is consumed by a request that does not contain an entry for it in DeviceRequest's Capacity.
    default: ?api_resource.ApiResourceQuantity = null,
    /// ValidRange defines an acceptable quantity value range in consuming requests.
    validRange: ?ResourceV1beta1CapacityRequestPolicyRange = null,
    /// ValidValues defines a set of acceptable quantity values in consuming requests.
    validValues: ?[]const api_resource.ApiResourceQuantity = null,
};

/// CapacityRequestPolicyRange defines a valid range for consumable capacity values.
pub const ResourceV1beta1CapacityRequestPolicyRange = struct {
    /// Max defines the upper limit for capacity that can be requested.
    max: ?api_resource.ApiResourceQuantity = null,
    /// Min specifies the minimum capacity allowed for a consumption request.
    min: api_resource.ApiResourceQuantity,
    /// Step defines the step size between valid capacity amounts within the range.
    step: ?api_resource.ApiResourceQuantity = null,
};

/// CapacityRequirements defines the capacity requirements for a specific device request.
pub const ResourceV1beta1CapacityRequirements = struct {
    /// Requests represent individual device resource requests for distinct resources, all of which must be provided by the device.
    requests: ?json.ArrayHashMap(api_resource.ApiResourceQuantity) = null,
};

/// Counter describes a quantity associated with a device.
pub const ResourceV1beta1Counter = struct {
    /// Value defines how much of a certain device counter is available.
    value: api_resource.ApiResourceQuantity,
};

/// CounterSet defines a named set of counters that are available to be used by devices defined in the ResourcePool.
pub const ResourceV1beta1CounterSet = struct {
    /// Counters defines the set of counters for this CounterSet The name of each counter must be unique in that set and must be a DNS label.
    counters: json.ArrayHashMap(ResourceV1beta1Counter),
    /// Name defines the name of the counter set. It must be a DNS label.
    name: []const u8,
};

/// Device represents one individual hardware instance that can be selected based on its attributes. Besides the name, exactly one field must be set.
pub const ResourceV1beta1Device = struct {
    /// Basic defines one device instance.
    basic: ?ResourceV1beta1BasicDevice = null,
    /// Name is unique identifier among all devices managed by the driver in the pool. It must be a DNS label.
    name: []const u8,
};

/// DeviceAllocationConfiguration gets embedded in an AllocationResult.
pub const ResourceV1beta1DeviceAllocationConfiguration = struct {
    /// Opaque provides driver-specific configuration parameters.
    @"opaque": ?ResourceV1beta1OpaqueDeviceConfiguration = null,
    /// Requests lists the names of requests where the configuration applies. If empty, its applies to all requests.
    requests: ?[]const []const u8 = null,
    /// Source records whether the configuration comes from a class and thus is not something that a normal user would have been able to set or from a claim.
    source: []const u8,
};

/// DeviceAllocationResult is the result of allocating devices.
pub const ResourceV1beta1DeviceAllocationResult = struct {
    /// This field is a combination of all the claim and class configuration parameters. Drivers can distinguish between those based on a flag.
    config: ?[]const ResourceV1beta1DeviceAllocationConfiguration = null,
    /// Results lists all allocated devices.
    results: ?[]const ResourceV1beta1DeviceRequestAllocationResult = null,
};

/// DeviceAttribute must have exactly one field set.
pub const ResourceV1beta1DeviceAttribute = struct {
    /// BoolValue is a true/false value.
    bool: ?bool = null,
    /// IntValue is a number.
    int: ?i64 = null,
    /// StringValue is a string. Must not be longer than 64 characters.
    string: ?[]const u8 = null,
    /// VersionValue is a semantic version according to semver.org spec 2.0.0. Must not be longer than 64 characters.
    version: ?[]const u8 = null,
};

/// DeviceCapacity describes a quantity associated with a device.
pub const ResourceV1beta1DeviceCapacity = struct {
    /// RequestPolicy defines how this DeviceCapacity must be consumed when the device is allowed to be shared by multiple allocations.
    requestPolicy: ?ResourceV1beta1CapacityRequestPolicy = null,
    /// Value defines how much of a certain capacity that device has.
    value: api_resource.ApiResourceQuantity,
};

/// DeviceClaim defines how to request devices with a ResourceClaim.
pub const ResourceV1beta1DeviceClaim = struct {
    /// This field holds configuration for multiple potential drivers which could satisfy requests in this claim. It is ignored while allocating the claim.
    config: ?[]const ResourceV1beta1DeviceClaimConfiguration = null,
    /// These constraints must be satisfied by the set of devices that get allocated for the claim.
    constraints: ?[]const ResourceV1beta1DeviceConstraint = null,
    /// Requests represent individual requests for distinct devices which must all be satisfied. If empty, nothing needs to be allocated.
    requests: ?[]const ResourceV1beta1DeviceRequest = null,
};

/// DeviceClaimConfiguration is used for configuration parameters in DeviceClaim.
pub const ResourceV1beta1DeviceClaimConfiguration = struct {
    /// Opaque provides driver-specific configuration parameters.
    @"opaque": ?ResourceV1beta1OpaqueDeviceConfiguration = null,
    /// Requests lists the names of requests where the configuration applies. If empty, it applies to all requests.
    requests: ?[]const []const u8 = null,
};

/// DeviceClass is a vendor- or admin-provided resource that contains device configuration and selectors. It can be referenced in the device requests of a claim to apply these presets. Cluster scoped.
pub const ResourceV1beta1DeviceClass = struct {
    pub const resource_meta = .{
        .group = "resource.k8s.io",
        .version = "v1beta1",
        .kind = "DeviceClass",
        .resource = "deviceclasses",
        .namespaced = false,
        .list_kind = ResourceV1beta1DeviceClassList,
    };

    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard object metadata
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// Spec defines what can be allocated and how to configure it.
    spec: ResourceV1beta1DeviceClassSpec,
};

/// DeviceClassConfiguration is used in DeviceClass.
pub const ResourceV1beta1DeviceClassConfiguration = struct {
    /// Opaque provides driver-specific configuration parameters.
    @"opaque": ?ResourceV1beta1OpaqueDeviceConfiguration = null,
};

/// DeviceClassList is a collection of classes.
pub const ResourceV1beta1DeviceClassList = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Items is the list of resource classes.
    items: []const ResourceV1beta1DeviceClass,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard list metadata
    metadata: ?meta_v1.MetaV1ListMeta = null,
};

/// DeviceClassSpec is used in a [DeviceClass] to define what can be allocated and how to configure it.
pub const ResourceV1beta1DeviceClassSpec = struct {
    /// Config defines configuration parameters that apply to each device that is claimed via this class. Some classses may potentially be satisfied by multiple drivers, so each instance of a vendor configuration applies to exactly one driver.
    config: ?[]const ResourceV1beta1DeviceClassConfiguration = null,
    /// ExtendedResourceName is the extended resource name for the devices of this class. The devices of this class can be used to satisfy a pod's extended resource requests. It has the same format as the name of a pod's extended resource. It should be unique among all the device classes in a cluster. If two device classes have the same name, then the class created later is picked to satisfy a pod's extended resource requests. If two classes are created at the same time, then the name of the class lexicographically sorted first is picked.
    extendedResourceName: ?[]const u8 = null,
    /// Each selector must be satisfied by a device which is claimed via this class.
    selectors: ?[]const ResourceV1beta1DeviceSelector = null,
};

/// DeviceConstraint must have exactly one field set besides Requests.
pub const ResourceV1beta1DeviceConstraint = struct {
    /// DistinctAttribute requires that all devices in question have this attribute and that its type and value are unique across those devices.
    distinctAttribute: ?[]const u8 = null,
    /// MatchAttribute requires that all devices in question have this attribute and that its type and value are the same across those devices.
    matchAttribute: ?[]const u8 = null,
    /// Requests is a list of the one or more requests in this claim which must co-satisfy this constraint. If a request is fulfilled by multiple devices, then all of the devices must satisfy the constraint. If this is not specified, this constraint applies to all requests in this claim.
    requests: ?[]const []const u8 = null,
};

/// DeviceCounterConsumption defines a set of counters that a device will consume from a CounterSet.
pub const ResourceV1beta1DeviceCounterConsumption = struct {
    /// CounterSet is the name of the set from which the counters defined will be consumed.
    counterSet: []const u8,
    /// Counters defines the counters that will be consumed by the device.
    counters: json.ArrayHashMap(ResourceV1beta1Counter),
};

/// DeviceRequest is a request for devices required for a claim. This is typically a request for a single resource like a device, but can also ask for several identical devices.
pub const ResourceV1beta1DeviceRequest = struct {
    /// AdminAccess indicates that this is a claim for administrative access to the device(s). Claims with AdminAccess are expected to be used for monitoring or other management services for a device.  They ignore all ordinary claims to the device with respect to access modes and any resource allocations.
    adminAccess: ?bool = null,
    /// AllocationMode and its related fields define how devices are allocated to satisfy this request. Supported values are:
    allocationMode: ?[]const u8 = null,
    /// Capacity define resource requirements against each capacity.
    capacity: ?ResourceV1beta1CapacityRequirements = null,
    /// Count is used only when the count mode is "ExactCount". Must be greater than zero. If AllocationMode is ExactCount and this field is not specified, the default is one.
    count: ?i64 = null,
    /// DeviceClassName references a specific DeviceClass, which can define additional configuration and selectors to be inherited by this request.
    deviceClassName: ?[]const u8 = null,
    /// FirstAvailable contains subrequests, of which exactly one will be satisfied by the scheduler to satisfy this request. It tries to satisfy them in the order in which they are listed here. So if there are two entries in the list, the scheduler will only check the second one if it determines that the first one cannot be used.
    firstAvailable: ?[]const ResourceV1beta1DeviceSubRequest = null,
    /// Name can be used to reference this request in a pod.spec.containers[].resources.claims entry and in a constraint of the claim.
    name: []const u8,
    /// Selectors define criteria which must be satisfied by a specific device in order for that device to be considered for this request. All selectors must be satisfied for a device to be considered.
    selectors: ?[]const ResourceV1beta1DeviceSelector = null,
    /// If specified, the request's tolerations.
    tolerations: ?[]const ResourceV1beta1DeviceToleration = null,
};

/// DeviceRequestAllocationResult contains the allocation result for one request.
pub const ResourceV1beta1DeviceRequestAllocationResult = struct {
    /// AdminAccess indicates that this device was allocated for administrative access. See the corresponding request field for a definition of mode.
    adminAccess: ?bool = null,
    /// BindingConditions contains a copy of the BindingConditions from the corresponding ResourceSlice at the time of allocation.
    bindingConditions: ?[]const []const u8 = null,
    /// BindingFailureConditions contains a copy of the BindingFailureConditions from the corresponding ResourceSlice at the time of allocation.
    bindingFailureConditions: ?[]const []const u8 = null,
    /// ConsumedCapacity tracks the amount of capacity consumed per device as part of the claim request. The consumed amount may differ from the requested amount: it is rounded up to the nearest valid value based on the device’s requestPolicy if applicable (i.e., may not be less than the requested amount).
    consumedCapacity: ?json.ArrayHashMap(api_resource.ApiResourceQuantity) = null,
    /// Device references one device instance via its name in the driver's resource pool. It must be a DNS label.
    device: []const u8,
    /// Driver specifies the name of the DRA driver whose kubelet plugin should be invoked to process the allocation once the claim is needed on a node.
    driver: []const u8,
    /// This name together with the driver name and the device name field identify which device was allocated (`<driver name>/<pool name>/<device name>`).
    pool: []const u8,
    /// Request is the name of the request in the claim which caused this device to be allocated. If it references a subrequest in the firstAvailable list on a DeviceRequest, this field must include both the name of the main request and the subrequest using the format <main request>/<subrequest>.
    request: []const u8,
    /// ShareID uniquely identifies an individual allocation share of the device, used when the device supports multiple simultaneous allocations. It serves as an additional map key to differentiate concurrent shares of the same device.
    shareID: ?[]const u8 = null,
    /// A copy of all tolerations specified in the request at the time when the device got allocated.
    tolerations: ?[]const ResourceV1beta1DeviceToleration = null,
};

/// DeviceSelector must have exactly one field set.
pub const ResourceV1beta1DeviceSelector = struct {
    /// CEL contains a CEL expression for selecting a device.
    cel: ?ResourceV1beta1CELDeviceSelector = null,
};

/// DeviceSubRequest describes a request for device provided in the claim.spec.devices.requests[].firstAvailable array. Each is typically a request for a single resource like a device, but can also ask for several identical devices.
pub const ResourceV1beta1DeviceSubRequest = struct {
    /// AllocationMode and its related fields define how devices are allocated to satisfy this subrequest. Supported values are:
    allocationMode: ?[]const u8 = null,
    /// Capacity define resource requirements against each capacity.
    capacity: ?ResourceV1beta1CapacityRequirements = null,
    /// Count is used only when the count mode is "ExactCount". Must be greater than zero. If AllocationMode is ExactCount and this field is not specified, the default is one.
    count: ?i64 = null,
    /// DeviceClassName references a specific DeviceClass, which can define additional configuration and selectors to be inherited by this subrequest.
    deviceClassName: []const u8,
    /// Name can be used to reference this subrequest in the list of constraints or the list of configurations for the claim. References must use the format <main request>/<subrequest>.
    name: []const u8,
    /// Selectors define criteria which must be satisfied by a specific device in order for that device to be considered for this subrequest. All selectors must be satisfied for a device to be considered.
    selectors: ?[]const ResourceV1beta1DeviceSelector = null,
    /// If specified, the request's tolerations.
    tolerations: ?[]const ResourceV1beta1DeviceToleration = null,
};

/// The device this taint is attached to has the "effect" on any claim which does not tolerate the taint and, through the claim, to pods using the claim.
pub const ResourceV1beta1DeviceTaint = struct {
    /// The effect of the taint on claims that do not tolerate the taint and through such claims on the pods using them.
    effect: []const u8,
    /// The taint key to be applied to a device. Must be a label name.
    key: []const u8,
    /// TimeAdded represents the time at which the taint was added. Added automatically during create or update if not set.
    timeAdded: ?meta_v1.MetaV1Time = null,
    /// The taint value corresponding to the taint key. Must be a label value.
    value: ?[]const u8 = null,
};

/// The ResourceClaim this DeviceToleration is attached to tolerates any taint that matches the triple <key,value,effect> using the matching operator <operator>.
pub const ResourceV1beta1DeviceToleration = struct {
    /// Effect indicates the taint effect to match. Empty means match all taint effects. When specified, allowed values are NoSchedule and NoExecute.
    effect: ?[]const u8 = null,
    /// Key is the taint key that the toleration applies to. Empty means match all taint keys. If the key is empty, operator must be Exists; this combination means to match all values and all keys. Must be a label name.
    key: ?[]const u8 = null,
    /// Operator represents a key's relationship to the value. Valid operators are Exists and Equal. Defaults to Equal. Exists is equivalent to wildcard for value, so that a ResourceClaim can tolerate all taints of a particular category.
    operator: ?[]const u8 = null,
    /// TolerationSeconds represents the period of time the toleration (which must be of effect NoExecute, otherwise this field is ignored) tolerates the taint. By default, it is not set, which means tolerate the taint forever (do not evict). Zero and negative values will be treated as 0 (evict immediately) by the system. If larger than zero, the time when the pod needs to be evicted is calculated as <time when taint was adedd> + <toleration seconds>.
    tolerationSeconds: ?i64 = null,
    /// Value is the taint value the toleration matches to. If the operator is Exists, the value must be empty, otherwise just a regular string. Must be a label value.
    value: ?[]const u8 = null,
};

/// NetworkDeviceData provides network-related details for the allocated device. This information may be filled by drivers or other components to configure or identify the device within a network context.
pub const ResourceV1beta1NetworkDeviceData = struct {
    /// HardwareAddress represents the hardware address (e.g. MAC Address) of the device's network interface.
    hardwareAddress: ?[]const u8 = null,
    /// InterfaceName specifies the name of the network interface associated with the allocated device. This might be the name of a physical or virtual network interface being configured in the pod.
    interfaceName: ?[]const u8 = null,
    /// IPs lists the network addresses assigned to the device's network interface. This can include both IPv4 and IPv6 addresses. The IPs are in the CIDR notation, which includes both the address and the associated subnet mask. e.g.: "192.0.2.5/24" for IPv4 and "2001:db8::5/64" for IPv6.
    ips: ?[]const []const u8 = null,
};

/// OpaqueDeviceConfiguration contains configuration parameters for a driver in a format defined by the driver vendor.
pub const ResourceV1beta1OpaqueDeviceConfiguration = struct {
    /// Driver is used to determine which kubelet plugin needs to be passed these configuration parameters.
    driver: []const u8,
    /// Parameters can contain arbitrary data. It is the responsibility of the driver developer to handle validation and versioning. Typically this includes self-identification and a version ("kind" + "apiVersion" for Kubernetes types), with conversion between different versions.
    parameters: pkg_runtime.PkgRuntimeRawExtension,
};

/// ResourceClaim describes a request for access to resources in the cluster, for use by workloads. For example, if a workload needs an accelerator device with specific properties, this is how that request is expressed. The status stanza tracks whether this claim has been satisfied and what specific resources have been allocated.
pub const ResourceV1beta1ResourceClaim = struct {
    pub const resource_meta = .{
        .group = "resource.k8s.io",
        .version = "v1beta1",
        .kind = "ResourceClaim",
        .resource = "resourceclaims",
        .namespaced = true,
        .list_kind = ResourceV1beta1ResourceClaimList,
    };

    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard object metadata
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// Spec describes what is being requested and how to configure it. The spec is immutable.
    spec: ResourceV1beta1ResourceClaimSpec,
    /// Status describes whether the claim is ready to use and what has been allocated.
    status: ?ResourceV1beta1ResourceClaimStatus = null,
};

/// ResourceClaimConsumerReference contains enough information to let you locate the consumer of a ResourceClaim. The user must be a resource in the same namespace as the ResourceClaim.
pub const ResourceV1beta1ResourceClaimConsumerReference = struct {
    /// APIGroup is the group for the resource being referenced. It is empty for the core API. This matches the group in the APIVersion that is used when creating the resources.
    apiGroup: ?[]const u8 = null,
    /// Name is the name of resource being referenced.
    name: []const u8,
    /// Resource is the type of resource being referenced, for example "pods".
    resource: []const u8,
    /// UID identifies exactly one incarnation of the resource.
    uid: []const u8,
};

/// ResourceClaimList is a collection of claims.
pub const ResourceV1beta1ResourceClaimList = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Items is the list of resource claims.
    items: []const ResourceV1beta1ResourceClaim,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard list metadata
    metadata: ?meta_v1.MetaV1ListMeta = null,
};

/// ResourceClaimSpec defines what is being requested in a ResourceClaim and how to configure it.
pub const ResourceV1beta1ResourceClaimSpec = struct {
    /// Devices defines how to request devices.
    devices: ?ResourceV1beta1DeviceClaim = null,
};

/// ResourceClaimStatus tracks whether the resource has been allocated and what the result of that was.
pub const ResourceV1beta1ResourceClaimStatus = struct {
    /// Allocation is set once the claim has been allocated successfully.
    allocation: ?ResourceV1beta1AllocationResult = null,
    /// Devices contains the status of each device allocated for this claim, as reported by the driver. This can include driver-specific information. Entries are owned by their respective drivers.
    devices: ?[]const ResourceV1beta1AllocatedDeviceStatus = null,
    /// ReservedFor indicates which entities are currently allowed to use the claim. A Pod which references a ResourceClaim which is not reserved for that Pod will not be started. A claim that is in use or might be in use because it has been reserved must not get deallocated.
    reservedFor: ?[]const ResourceV1beta1ResourceClaimConsumerReference = null,
};

/// ResourceClaimTemplate is used to produce ResourceClaim objects.
pub const ResourceV1beta1ResourceClaimTemplate = struct {
    pub const resource_meta = .{
        .group = "resource.k8s.io",
        .version = "v1beta1",
        .kind = "ResourceClaimTemplate",
        .resource = "resourceclaimtemplates",
        .namespaced = true,
        .list_kind = ResourceV1beta1ResourceClaimTemplateList,
    };

    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard object metadata
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// Describes the ResourceClaim that is to be generated.
    spec: ResourceV1beta1ResourceClaimTemplateSpec,
};

/// ResourceClaimTemplateList is a collection of claim templates.
pub const ResourceV1beta1ResourceClaimTemplateList = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Items is the list of resource claim templates.
    items: []const ResourceV1beta1ResourceClaimTemplate,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard list metadata
    metadata: ?meta_v1.MetaV1ListMeta = null,
};

/// ResourceClaimTemplateSpec contains the metadata and fields for a ResourceClaim.
pub const ResourceV1beta1ResourceClaimTemplateSpec = struct {
    /// ObjectMeta may contain labels and annotations that will be copied into the ResourceClaim when creating it. No other fields are allowed and will be rejected during validation.
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// Spec for the ResourceClaim. The entire content is copied unchanged into the ResourceClaim that gets created from this template. The same fields as in a ResourceClaim are also valid here.
    spec: ResourceV1beta1ResourceClaimSpec,
};

/// ResourcePool describes the pool that ResourceSlices belong to.
pub const ResourceV1beta1ResourcePool = struct {
    /// Generation tracks the change in a pool over time. Whenever a driver changes something about one or more of the resources in a pool, it must change the generation in all ResourceSlices which are part of that pool. Consumers of ResourceSlices should only consider resources from the pool with the highest generation number. The generation may be reset by drivers, which should be fine for consumers, assuming that all ResourceSlices in a pool are updated to match or deleted.
    generation: i64,
    /// Name is used to identify the pool. For node-local devices, this is often the node name, but this is not required.
    name: []const u8,
    /// ResourceSliceCount is the total number of ResourceSlices in the pool at this generation number. Must be greater than zero.
    resourceSliceCount: i64,
};

/// ResourceSlice represents one or more resources in a pool of similar resources, managed by a common driver. A pool may span more than one ResourceSlice, and exactly how many ResourceSlices comprise a pool is determined by the driver.
pub const ResourceV1beta1ResourceSlice = struct {
    pub const resource_meta = .{
        .group = "resource.k8s.io",
        .version = "v1beta1",
        .kind = "ResourceSlice",
        .resource = "resourceslices",
        .namespaced = false,
        .list_kind = ResourceV1beta1ResourceSliceList,
    };

    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard object metadata
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// Contains the information published by the driver.
    spec: ResourceV1beta1ResourceSliceSpec,
};

/// ResourceSliceList is a collection of ResourceSlices.
pub const ResourceV1beta1ResourceSliceList = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Items is the list of resource ResourceSlices.
    items: []const ResourceV1beta1ResourceSlice,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard list metadata
    metadata: ?meta_v1.MetaV1ListMeta = null,
};

/// ResourceSliceSpec contains the information published by the driver in one ResourceSlice.
pub const ResourceV1beta1ResourceSliceSpec = struct {
    /// AllNodes indicates that all nodes have access to the resources in the pool.
    allNodes: ?bool = null,
    /// Devices lists some or all of the devices in this pool.
    devices: ?[]const ResourceV1beta1Device = null,
    /// Driver identifies the DRA driver providing the capacity information. A field selector can be used to list only ResourceSlice objects with a certain driver name.
    driver: []const u8,
    /// NodeName identifies the node which provides the resources in this pool. A field selector can be used to list only ResourceSlice objects belonging to a certain node.
    nodeName: ?[]const u8 = null,
    /// NodeSelector defines which nodes have access to the resources in the pool, when that pool is not limited to a single node.
    nodeSelector: ?core_v1.CoreV1NodeSelector = null,
    /// PerDeviceNodeSelection defines whether the access from nodes to resources in the pool is set on the ResourceSlice level or on each device. If it is set to true, every device defined the ResourceSlice must specify this individually.
    perDeviceNodeSelection: ?bool = null,
    /// Pool describes the pool that this ResourceSlice belongs to.
    pool: ResourceV1beta1ResourcePool,
    /// SharedCounters defines a list of counter sets, each of which has a name and a list of counters available.
    sharedCounters: ?[]const ResourceV1beta1CounterSet = null,
};
