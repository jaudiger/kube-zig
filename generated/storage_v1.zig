// Auto-generated from Kubernetes OpenAPI spec.
// Do not edit manually. Regenerate with: zig build generate

const std = @import("std");
const json = std.json;
const api_resource = @import("api_resource.zig");
const core_v1 = @import("core_v1.zig");
const meta_v1 = @import("meta_v1.zig");

/// CSIDriver captures information about a Container Storage Interface (CSI) volume driver deployed on the cluster. Kubernetes attach detach controller uses this object to determine whether attach is required. Kubelet uses this object to determine whether pod information needs to be passed on mount. CSIDriver objects are non-namespaced.
pub const StorageV1CSIDriver = struct {
    pub const resource_meta = .{
        .group = "storage.k8s.io",
        .version = "v1",
        .kind = "CSIDriver",
        .resource = "csidrivers",
        .namespaced = false,
        .list_kind = StorageV1CSIDriverList,
    };

    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard object metadata. metadata.Name indicates the name of the CSI driver that this object refers to; it MUST be the same name returned by the CSI GetPluginName() call for that driver. The driver name must be 63 characters or less, beginning and ending with an alphanumeric character ([a-z0-9A-Z]) with dashes (-), dots (.), and alphanumerics between. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// spec represents the specification of the CSI Driver.
    spec: StorageV1CSIDriverSpec,
};

/// CSIDriverList is a collection of CSIDriver objects.
pub const StorageV1CSIDriverList = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// items is the list of CSIDriver
    items: []const StorageV1CSIDriver,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard list metadata More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata
    metadata: ?meta_v1.MetaV1ListMeta = null,
};

/// CSIDriverSpec is the specification of a CSIDriver.
pub const StorageV1CSIDriverSpec = struct {
    /// attachRequired indicates this CSI volume driver requires an attach operation (because it implements the CSI ControllerPublishVolume() method), and that the Kubernetes attach detach controller should call the attach volume interface which checks the volumeattachment status and waits until the volume is attached before proceeding to mounting. The CSI external-attacher coordinates with CSI volume driver and updates the volumeattachment status when the attach operation is complete. If the value is specified to false, the attach operation will be skipped. Otherwise the attach operation will be called.
    attachRequired: ?bool = null,
    /// fsGroupPolicy defines if the underlying volume supports changing ownership and permission of the volume before being mounted. Refer to the specific FSGroupPolicy values for additional details.
    fsGroupPolicy: ?[]const u8 = null,
    /// nodeAllocatableUpdatePeriodSeconds specifies the interval between periodic updates of the CSINode allocatable capacity for this driver. When set, both periodic updates and updates triggered by capacity-related failures are enabled. If not set, no updates occur (neither periodic nor upon detecting capacity-related failures), and the allocatable.count remains static. The minimum allowed value for this field is 10 seconds.
    nodeAllocatableUpdatePeriodSeconds: ?i64 = null,
    /// podInfoOnMount indicates this CSI volume driver requires additional pod information (like podName, podUID, etc.) during mount operations, if set to true. If set to false, pod information will not be passed on mount. Default is false.
    podInfoOnMount: ?bool = null,
    /// requiresRepublish indicates the CSI driver wants `NodePublishVolume` being periodically called to reflect any possible change in the mounted volume. This field defaults to false.
    requiresRepublish: ?bool = null,
    /// seLinuxMount specifies if the CSI driver supports "-o context" mount option.
    seLinuxMount: ?bool = null,
    /// serviceAccountTokenInSecrets is an opt-in for CSI drivers to indicate that service account tokens should be passed via the Secrets field in NodePublishVolumeRequest instead of the VolumeContext field. The CSI specification provides a dedicated Secrets field for sensitive information like tokens, which is the appropriate mechanism for handling credentials. This addresses security concerns where sensitive tokens were being logged as part of volume context.
    serviceAccountTokenInSecrets: ?bool = null,
    /// storageCapacity indicates that the CSI volume driver wants pod scheduling to consider the storage capacity that the driver deployment will report by creating CSIStorageCapacity objects with capacity information, if set to true.
    storageCapacity: ?bool = null,
    /// tokenRequests indicates the CSI driver needs pods' service account tokens it is mounting volume for to do necessary authentication. Kubelet will pass the tokens in VolumeContext in the CSI NodePublishVolume calls. The CSI driver should parse and validate the following VolumeContext: "csi.storage.k8s.io/serviceAccount.tokens": {
    tokenRequests: ?[]const StorageV1TokenRequest = null,
    /// volumeLifecycleModes defines what kind of volumes this CSI volume driver supports. The default if the list is empty is "Persistent", which is the usage defined by the CSI specification and implemented in Kubernetes via the usual PV/PVC mechanism.
    volumeLifecycleModes: ?[]const []const u8 = null,
};

/// CSINode holds information about all CSI drivers installed on a node. CSI drivers do not need to create the CSINode object directly. As long as they use the node-driver-registrar sidecar container, the kubelet will automatically populate the CSINode object for the CSI driver as part of kubelet plugin registration. CSINode has the same name as a node. If the object is missing, it means either there are no CSI Drivers available on the node, or the Kubelet version is low enough that it doesn't create this object. CSINode has an OwnerReference that points to the corresponding node object.
pub const StorageV1CSINode = struct {
    pub const resource_meta = .{
        .group = "storage.k8s.io",
        .version = "v1",
        .kind = "CSINode",
        .resource = "csinodes",
        .namespaced = false,
        .list_kind = StorageV1CSINodeList,
    };

    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard object's metadata. metadata.name must be the Kubernetes node name.
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// spec is the specification of CSINode
    spec: StorageV1CSINodeSpec,
};

/// CSINodeDriver holds information about the specification of one CSI driver installed on a node
pub const StorageV1CSINodeDriver = struct {
    /// allocatable represents the volume resources of a node that are available for scheduling. This field is beta.
    allocatable: ?StorageV1VolumeNodeResources = null,
    /// name represents the name of the CSI driver that this object refers to. This MUST be the same name returned by the CSI GetPluginName() call for that driver.
    name: []const u8,
    /// nodeID of the node from the driver point of view. This field enables Kubernetes to communicate with storage systems that do not share the same nomenclature for nodes. For example, Kubernetes may refer to a given node as "node1", but the storage system may refer to the same node as "nodeA". When Kubernetes issues a command to the storage system to attach a volume to a specific node, it can use this field to refer to the node name using the ID that the storage system will understand, e.g. "nodeA" instead of "node1". This field is required.
    nodeID: []const u8,
    /// topologyKeys is the list of keys supported by the driver. When a driver is initialized on a cluster, it provides a set of topology keys that it understands (e.g. "company.com/zone", "company.com/region"). When a driver is initialized on a node, it provides the same topology keys along with values. Kubelet will expose these topology keys as labels on its own node object. When Kubernetes does topology aware provisioning, it can use this list to determine which labels it should retrieve from the node object and pass back to the driver. It is possible for different nodes to use different topology keys. This can be empty if driver does not support topology.
    topologyKeys: ?[]const []const u8 = null,
};

/// CSINodeList is a collection of CSINode objects.
pub const StorageV1CSINodeList = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// items is the list of CSINode
    items: []const StorageV1CSINode,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard list metadata More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata
    metadata: ?meta_v1.MetaV1ListMeta = null,
};

/// CSINodeSpec holds information about the specification of all CSI drivers installed on a node
pub const StorageV1CSINodeSpec = struct {
    /// drivers is a list of information of all CSI Drivers existing on a node. If all drivers in the list are uninstalled, this can become empty.
    drivers: []const StorageV1CSINodeDriver,
};

/// CSIStorageCapacity stores the result of one CSI GetCapacity call. For a given StorageClass, this describes the available capacity in a particular topology segment.  This can be used when considering where to instantiate new PersistentVolumes.
pub const StorageV1CSIStorageCapacity = struct {
    pub const resource_meta = .{
        .group = "storage.k8s.io",
        .version = "v1",
        .kind = "CSIStorageCapacity",
        .resource = "csistoragecapacities",
        .namespaced = true,
        .list_kind = StorageV1CSIStorageCapacityList,
    };

    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// capacity is the value reported by the CSI driver in its GetCapacityResponse for a GetCapacityRequest with topology and parameters that match the previous fields.
    capacity: ?api_resource.ApiResourceQuantity = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// maximumVolumeSize is the value reported by the CSI driver in its GetCapacityResponse for a GetCapacityRequest with topology and parameters that match the previous fields.
    maximumVolumeSize: ?api_resource.ApiResourceQuantity = null,
    /// Standard object's metadata. The name has no particular meaning. It must be a DNS subdomain (dots allowed, 253 characters). To ensure that there are no conflicts with other CSI drivers on the cluster, the recommendation is to use csisc-<uuid>, a generated name, or a reverse-domain name which ends with the unique CSI driver name.
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// nodeTopology defines which nodes have access to the storage for which capacity was reported. If not set, the storage is not accessible from any node in the cluster. If empty, the storage is accessible from all nodes. This field is immutable.
    nodeTopology: ?meta_v1.MetaV1LabelSelector = null,
    /// storageClassName represents the name of the StorageClass that the reported capacity applies to. It must meet the same requirements as the name of a StorageClass object (non-empty, DNS subdomain). If that object no longer exists, the CSIStorageCapacity object is obsolete and should be removed by its creator. This field is immutable.
    storageClassName: []const u8,
};

/// CSIStorageCapacityList is a collection of CSIStorageCapacity objects.
pub const StorageV1CSIStorageCapacityList = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// items is the list of CSIStorageCapacity objects.
    items: []const StorageV1CSIStorageCapacity,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard list metadata More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata
    metadata: ?meta_v1.MetaV1ListMeta = null,
};

/// StorageClass describes the parameters for a class of storage for which PersistentVolumes can be dynamically provisioned.
pub const StorageV1StorageClass = struct {
    pub const resource_meta = .{
        .group = "storage.k8s.io",
        .version = "v1",
        .kind = "StorageClass",
        .resource = "storageclasses",
        .namespaced = false,
        .list_kind = StorageV1StorageClassList,
    };

    /// allowVolumeExpansion shows whether the storage class allow volume expand.
    allowVolumeExpansion: ?bool = null,
    /// allowedTopologies restrict the node topologies where volumes can be dynamically provisioned. Each volume plugin defines its own supported topology specifications. An empty TopologySelectorTerm list means there is no topology restriction. This field is only honored by servers that enable the VolumeScheduling feature.
    allowedTopologies: ?[]const core_v1.CoreV1TopologySelectorTerm = null,
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard object's metadata. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// mountOptions controls the mountOptions for dynamically provisioned PersistentVolumes of this storage class. e.g. ["ro", "soft"]. Not validated - mount of the PVs will simply fail if one is invalid.
    mountOptions: ?[]const []const u8 = null,
    /// parameters holds the parameters for the provisioner that should create volumes of this storage class.
    parameters: ?json.ArrayHashMap([]const u8) = null,
    /// provisioner indicates the type of the provisioner.
    provisioner: []const u8,
    /// reclaimPolicy controls the reclaimPolicy for dynamically provisioned PersistentVolumes of this storage class. Defaults to Delete.
    reclaimPolicy: ?[]const u8 = null,
    /// volumeBindingMode indicates how PersistentVolumeClaims should be provisioned and bound.  When unset, VolumeBindingImmediate is used. This field is only honored by servers that enable the VolumeScheduling feature.
    volumeBindingMode: ?[]const u8 = null,
};

/// StorageClassList is a collection of storage classes.
pub const StorageV1StorageClassList = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// items is the list of StorageClasses
    items: []const StorageV1StorageClass,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard list metadata More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata
    metadata: ?meta_v1.MetaV1ListMeta = null,
};

/// TokenRequest contains parameters of a service account token.
pub const StorageV1TokenRequest = struct {
    /// audience is the intended audience of the token in "TokenRequestSpec". It will default to the audiences of kube apiserver.
    audience: []const u8,
    /// expirationSeconds is the duration of validity of the token in "TokenRequestSpec". It has the same default value of "ExpirationSeconds" in "TokenRequestSpec".
    expirationSeconds: ?i64 = null,
};

/// VolumeAttachment captures the intent to attach or detach the specified volume to/from the specified node.
pub const StorageV1VolumeAttachment = struct {
    pub const resource_meta = .{
        .group = "storage.k8s.io",
        .version = "v1",
        .kind = "VolumeAttachment",
        .resource = "volumeattachments",
        .namespaced = false,
        .list_kind = StorageV1VolumeAttachmentList,
    };

    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard object metadata. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// spec represents specification of the desired attach/detach volume behavior. Populated by the Kubernetes system.
    spec: StorageV1VolumeAttachmentSpec,
    /// status represents status of the VolumeAttachment request. Populated by the entity completing the attach or detach operation, i.e. the external-attacher.
    status: ?StorageV1VolumeAttachmentStatus = null,
};

/// VolumeAttachmentList is a collection of VolumeAttachment objects.
pub const StorageV1VolumeAttachmentList = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// items is the list of VolumeAttachments
    items: []const StorageV1VolumeAttachment,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard list metadata More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata
    metadata: ?meta_v1.MetaV1ListMeta = null,
};

/// VolumeAttachmentSource represents a volume that should be attached. Right now only PersistentVolumes can be attached via external attacher, in the future we may allow also inline volumes in pods. Exactly one member can be set.
pub const StorageV1VolumeAttachmentSource = struct {
    /// inlineVolumeSpec contains all the information necessary to attach a persistent volume defined by a pod's inline VolumeSource. This field is populated only for the CSIMigration feature. It contains translated fields from a pod's inline VolumeSource to a PersistentVolumeSpec. This field is beta-level and is only honored by servers that enabled the CSIMigration feature.
    inlineVolumeSpec: ?core_v1.CoreV1PersistentVolumeSpec = null,
    /// persistentVolumeName represents the name of the persistent volume to attach.
    persistentVolumeName: ?[]const u8 = null,
};

/// VolumeAttachmentSpec is the specification of a VolumeAttachment request.
pub const StorageV1VolumeAttachmentSpec = struct {
    /// attacher indicates the name of the volume driver that MUST handle this request. This is the name returned by GetPluginName().
    attacher: []const u8,
    /// nodeName represents the node that the volume should be attached to.
    nodeName: []const u8,
    /// source represents the volume that should be attached.
    source: StorageV1VolumeAttachmentSource,
};

/// VolumeAttachmentStatus is the status of a VolumeAttachment request.
pub const StorageV1VolumeAttachmentStatus = struct {
    /// attachError represents the last error encountered during attach operation, if any. This field must only be set by the entity completing the attach operation, i.e. the external-attacher.
    attachError: ?StorageV1VolumeError = null,
    /// attached indicates the volume is successfully attached. This field must only be set by the entity completing the attach operation, i.e. the external-attacher.
    attached: bool,
    /// attachmentMetadata is populated with any information returned by the attach operation, upon successful attach, that must be passed into subsequent WaitForAttach or Mount calls. This field must only be set by the entity completing the attach operation, i.e. the external-attacher.
    attachmentMetadata: ?json.ArrayHashMap([]const u8) = null,
    /// detachError represents the last error encountered during detach operation, if any. This field must only be set by the entity completing the detach operation, i.e. the external-attacher.
    detachError: ?StorageV1VolumeError = null,
};

/// VolumeAttributesClass represents a specification of mutable volume attributes defined by the CSI driver. The class can be specified during dynamic provisioning of PersistentVolumeClaims, and changed in the PersistentVolumeClaim spec after provisioning.
pub const StorageV1VolumeAttributesClass = struct {
    pub const resource_meta = .{
        .group = "storage.k8s.io",
        .version = "v1",
        .kind = "VolumeAttributesClass",
        .resource = "volumeattributesclasses",
        .namespaced = false,
        .list_kind = StorageV1VolumeAttributesClassList,
    };

    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Name of the CSI driver This field is immutable.
    driverName: []const u8,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard object's metadata. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// parameters hold volume attributes defined by the CSI driver. These values are opaque to the Kubernetes and are passed directly to the CSI driver. The underlying storage provider supports changing these attributes on an existing volume, however the parameters field itself is immutable. To invoke a volume update, a new VolumeAttributesClass should be created with new parameters, and the PersistentVolumeClaim should be updated to reference the new VolumeAttributesClass.
    parameters: ?json.ArrayHashMap([]const u8) = null,
};

/// VolumeAttributesClassList is a collection of VolumeAttributesClass objects.
pub const StorageV1VolumeAttributesClassList = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// items is the list of VolumeAttributesClass objects.
    items: []const StorageV1VolumeAttributesClass,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard list metadata More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata
    metadata: ?meta_v1.MetaV1ListMeta = null,
};

/// VolumeError captures an error encountered during a volume operation.
pub const StorageV1VolumeError = struct {
    /// errorCode is a numeric gRPC code representing the error encountered during Attach or Detach operations.
    errorCode: ?i32 = null,
    /// message represents the error encountered during Attach or Detach operation. This string may be logged, so it should not contain sensitive information.
    message: ?[]const u8 = null,
    /// time represents the time the error was encountered.
    time: ?meta_v1.MetaV1Time = null,
};

/// VolumeNodeResources is a set of resource limits for scheduling of volumes.
pub const StorageV1VolumeNodeResources = struct {
    /// count indicates the maximum number of unique volumes managed by the CSI driver that can be used on a node. A volume that is both attached and mounted on a node is considered to be used once, not twice. The same rule applies for a unique volume that is shared among multiple pods on the same node. If this field is not specified, then the supported number of volumes on this node is unbounded.
    count: ?i32 = null,
};
