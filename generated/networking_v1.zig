// Auto-generated from Kubernetes OpenAPI spec.
// Do not edit manually. Regenerate with: zig build generate

const std = @import("std");
const json = std.json;
const core_v1 = @import("core_v1.zig");
const meta_v1 = @import("meta_v1.zig");
const util_intstr = @import("util_intstr.zig");

/// HTTPIngressPath associates a path with a backend. Incoming urls matching the path are forwarded to the backend.
pub const NetworkingV1HTTPIngressPath = struct {
    /// backend defines the referenced service endpoint to which the traffic will be forwarded to.
    backend: NetworkingV1IngressBackend,
    /// path is matched against the path of an incoming request. Currently it can contain characters disallowed from the conventional "path" part of a URL as defined by RFC 3986. Paths must begin with a '/' and must be present when using PathType with value "Exact" or "Prefix".
    path: ?[]const u8 = null,
    /// pathType determines the interpretation of the path matching. PathType can be one of the following values: * Exact: Matches the URL path exactly. * Prefix: Matches based on a URL path prefix split by '/'. Matching is
    pathType: []const u8,
};

/// HTTPIngressRuleValue is a list of http selectors pointing to backends. In the example: http://<host>/<path>?<searchpart> -> backend where where parts of the url correspond to RFC 3986, this resource will be used to match against everything after the last '/' and before the first '?' or '#'.
pub const NetworkingV1HTTPIngressRuleValue = struct {
    /// paths is a collection of paths that map requests to backends.
    paths: []const NetworkingV1HTTPIngressPath,
};

/// IPAddress represents a single IP of a single IP Family. The object is designed to be used by APIs that operate on IP addresses. The object is used by the Service core API for allocation of IP addresses. An IP address can be represented in different formats, to guarantee the uniqueness of the IP, the name of the object is the IP address in canonical format, four decimal digits separated by dots suppressing leading zeros for IPv4 and the representation defined by RFC 5952 for IPv6. Valid: 192.168.1.5 or 2001:db8::1 or 2001:db8:aaaa:bbbb:cccc:dddd:eeee:1 Invalid: 10.01.2.3 or 2001:db8:0:0:0::1
pub const NetworkingV1IPAddress = struct {
    pub const resource_meta = .{
        .group = "networking.k8s.io",
        .version = "v1",
        .kind = "IPAddress",
        .resource = "ipaddresses",
        .namespaced = false,
        .list_kind = NetworkingV1IPAddressList,
    };

    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard object's metadata. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// spec is the desired state of the IPAddress. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#spec-and-status
    spec: NetworkingV1IPAddressSpec,
};

/// IPAddressList contains a list of IPAddress.
pub const NetworkingV1IPAddressList = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// items is the list of IPAddresses.
    items: []const NetworkingV1IPAddress,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard object's metadata. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata
    metadata: ?meta_v1.MetaV1ListMeta = null,
};

/// IPAddressSpec describe the attributes in an IP Address.
pub const NetworkingV1IPAddressSpec = struct {
    /// ParentRef references the resource that an IPAddress is attached to. An IPAddress must reference a parent object.
    parentRef: NetworkingV1ParentReference,
};

/// IPBlock describes a particular CIDR (Ex. "192.168.1.0/24","2001:db8::/64") that is allowed to the pods matched by a NetworkPolicySpec's podSelector. The except entry describes CIDRs that should not be included within this rule.
pub const NetworkingV1IPBlock = struct {
    /// cidr is a string representing the IPBlock Valid examples are "192.168.1.0/24" or "2001:db8::/64"
    cidr: []const u8,
    /// except is a slice of CIDRs that should not be included within an IPBlock Valid examples are "192.168.1.0/24" or "2001:db8::/64" Except values will be rejected if they are outside the cidr range
    except: ?[]const []const u8 = null,
};

/// Ingress is a collection of rules that allow inbound connections to reach the endpoints defined by a backend. An Ingress can be configured to give services externally-reachable urls, load balance traffic, terminate SSL, offer name based virtual hosting etc.
pub const NetworkingV1Ingress = struct {
    pub const resource_meta = .{
        .group = "networking.k8s.io",
        .version = "v1",
        .kind = "Ingress",
        .resource = "ingresses",
        .namespaced = true,
        .list_kind = NetworkingV1IngressList,
    };

    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard object's metadata. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// spec is the desired state of the Ingress. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#spec-and-status
    spec: ?NetworkingV1IngressSpec = null,
    /// status is the current state of the Ingress. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#spec-and-status
    status: ?NetworkingV1IngressStatus = null,
};

/// IngressBackend describes all endpoints for a given service and port.
pub const NetworkingV1IngressBackend = struct {
    /// resource is an ObjectRef to another Kubernetes resource in the namespace of the Ingress object. If resource is specified, a service.Name and service.Port must not be specified. This is a mutually exclusive setting with "Service".
    resource: ?core_v1.CoreV1TypedLocalObjectReference = null,
    /// service references a service as a backend. This is a mutually exclusive setting with "Resource".
    service: ?NetworkingV1IngressServiceBackend = null,
};

/// IngressClass represents the class of the Ingress, referenced by the Ingress Spec. The `ingressclass.kubernetes.io/is-default-class` annotation can be used to indicate that an IngressClass should be considered default. When a single IngressClass resource has this annotation set to true, new Ingress resources without a class specified will be assigned this default class.
pub const NetworkingV1IngressClass = struct {
    pub const resource_meta = .{
        .group = "networking.k8s.io",
        .version = "v1",
        .kind = "IngressClass",
        .resource = "ingressclasses",
        .namespaced = false,
        .list_kind = NetworkingV1IngressClassList,
    };

    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard object's metadata. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// spec is the desired state of the IngressClass. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#spec-and-status
    spec: ?NetworkingV1IngressClassSpec = null,
};

/// IngressClassList is a collection of IngressClasses.
pub const NetworkingV1IngressClassList = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// items is the list of IngressClasses.
    items: []const NetworkingV1IngressClass,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard list metadata.
    metadata: ?meta_v1.MetaV1ListMeta = null,
};

/// IngressClassParametersReference identifies an API object. This can be used to specify a cluster or namespace-scoped resource.
pub const NetworkingV1IngressClassParametersReference = struct {
    /// apiGroup is the group for the resource being referenced. If APIGroup is not specified, the specified Kind must be in the core API group. For any other third-party types, APIGroup is required.
    apiGroup: ?[]const u8 = null,
    /// kind is the type of resource being referenced.
    kind: []const u8,
    /// name is the name of resource being referenced.
    name: []const u8,
    /// namespace is the namespace of the resource being referenced. This field is required when scope is set to "Namespace" and must be unset when scope is set to "Cluster".
    namespace: ?[]const u8 = null,
    /// scope represents if this refers to a cluster or namespace scoped resource. This may be set to "Cluster" (default) or "Namespace".
    scope: ?[]const u8 = null,
};

/// IngressClassSpec provides information about the class of an Ingress.
pub const NetworkingV1IngressClassSpec = struct {
    /// controller refers to the name of the controller that should handle this class. This allows for different "flavors" that are controlled by the same controller. For example, you may have different parameters for the same implementing controller. This should be specified as a domain-prefixed path no more than 250 characters in length, e.g. "acme.io/ingress-controller". This field is immutable.
    controller: ?[]const u8 = null,
    /// parameters is a link to a custom resource containing additional configuration for the controller. This is optional if the controller does not require extra parameters.
    parameters: ?NetworkingV1IngressClassParametersReference = null,
};

/// IngressList is a collection of Ingress.
pub const NetworkingV1IngressList = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// items is the list of Ingress.
    items: []const NetworkingV1Ingress,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard object's metadata. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata
    metadata: ?meta_v1.MetaV1ListMeta = null,
};

/// IngressLoadBalancerIngress represents the status of a load-balancer ingress point.
pub const NetworkingV1IngressLoadBalancerIngress = struct {
    /// hostname is set for load-balancer ingress points that are DNS based.
    hostname: ?[]const u8 = null,
    /// ip is set for load-balancer ingress points that are IP based.
    ip: ?[]const u8 = null,
    /// ports provides information about the ports exposed by this LoadBalancer.
    ports: ?[]const NetworkingV1IngressPortStatus = null,
};

/// IngressLoadBalancerStatus represents the status of a load-balancer.
pub const NetworkingV1IngressLoadBalancerStatus = struct {
    /// ingress is a list containing ingress points for the load-balancer.
    ingress: ?[]const NetworkingV1IngressLoadBalancerIngress = null,
};

/// IngressPortStatus represents the error condition of a service port
pub const NetworkingV1IngressPortStatus = struct {
    /// error is to record the problem with the service port The format of the error shall comply with the following rules: - built-in error values shall be specified in this file and those shall use
    @"error": ?[]const u8 = null,
    /// port is the port number of the ingress port.
    port: i32,
    /// protocol is the protocol of the ingress port. The supported values are: "TCP", "UDP", "SCTP"
    protocol: []const u8,
};

/// IngressRule represents the rules mapping the paths under a specified host to the related backend services. Incoming requests are first evaluated for a host match, then routed to the backend associated with the matching IngressRuleValue.
pub const NetworkingV1IngressRule = struct {
    /// host is the fully qualified domain name of a network host, as defined by RFC 3986. Note the following deviations from the "host" part of the URI as defined in RFC 3986: 1. IPs are not allowed. Currently an IngressRuleValue can only apply to
    host: ?[]const u8 = null,
    http: ?NetworkingV1HTTPIngressRuleValue = null,
};

/// IngressServiceBackend references a Kubernetes Service as a Backend.
pub const NetworkingV1IngressServiceBackend = struct {
    /// name is the referenced service. The service must exist in the same namespace as the Ingress object.
    name: []const u8,
    /// port of the referenced service. A port name or port number is required for a IngressServiceBackend.
    port: ?NetworkingV1ServiceBackendPort = null,
};

/// IngressSpec describes the Ingress the user wishes to exist.
pub const NetworkingV1IngressSpec = struct {
    /// defaultBackend is the backend that should handle requests that don't match any rule. If Rules are not specified, DefaultBackend must be specified. If DefaultBackend is not set, the handling of requests that do not match any of the rules will be up to the Ingress controller.
    defaultBackend: ?NetworkingV1IngressBackend = null,
    /// ingressClassName is the name of an IngressClass cluster resource. Ingress controller implementations use this field to know whether they should be serving this Ingress resource, by a transitive connection (controller -> IngressClass -> Ingress resource). Although the `kubernetes.io/ingress.class` annotation (simple constant name) was never formally defined, it was widely supported by Ingress controllers to create a direct binding between Ingress controller and Ingress resources. Newly created Ingress resources should prefer using the field. However, even though the annotation is officially deprecated, for backwards compatibility reasons, ingress controllers should still honor that annotation if present.
    ingressClassName: ?[]const u8 = null,
    /// rules is a list of host rules used to configure the Ingress. If unspecified, or no rule matches, all traffic is sent to the default backend.
    rules: ?[]const NetworkingV1IngressRule = null,
    /// tls represents the TLS configuration. Currently the Ingress only supports a single TLS port, 443. If multiple members of this list specify different hosts, they will be multiplexed on the same port according to the hostname specified through the SNI TLS extension, if the ingress controller fulfilling the ingress supports SNI.
    tls: ?[]const NetworkingV1IngressTLS = null,
};

/// IngressStatus describe the current state of the Ingress.
pub const NetworkingV1IngressStatus = struct {
    /// loadBalancer contains the current status of the load-balancer.
    loadBalancer: ?NetworkingV1IngressLoadBalancerStatus = null,
};

/// IngressTLS describes the transport layer security associated with an ingress.
pub const NetworkingV1IngressTLS = struct {
    /// hosts is a list of hosts included in the TLS certificate. The values in this list must match the name/s used in the tlsSecret. Defaults to the wildcard host setting for the loadbalancer controller fulfilling this Ingress, if left unspecified.
    hosts: ?[]const []const u8 = null,
    /// secretName is the name of the secret used to terminate TLS traffic on port 443. Field is left optional to allow TLS routing based on SNI hostname alone. If the SNI host in a listener conflicts with the "Host" header field used by an IngressRule, the SNI host is used for termination and value of the "Host" header is used for routing.
    secretName: ?[]const u8 = null,
};

/// NetworkPolicy describes what network traffic is allowed for a set of Pods
pub const NetworkingV1NetworkPolicy = struct {
    pub const resource_meta = .{
        .group = "networking.k8s.io",
        .version = "v1",
        .kind = "NetworkPolicy",
        .resource = "networkpolicies",
        .namespaced = true,
        .list_kind = NetworkingV1NetworkPolicyList,
    };

    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard object's metadata. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// spec represents the specification of the desired behavior for this NetworkPolicy.
    spec: ?NetworkingV1NetworkPolicySpec = null,
};

/// NetworkPolicyEgressRule describes a particular set of traffic that is allowed out of pods matched by a NetworkPolicySpec's podSelector. The traffic must match both ports and to. This type is beta-level in 1.8
pub const NetworkingV1NetworkPolicyEgressRule = struct {
    /// ports is a list of destination ports for outgoing traffic. Each item in this list is combined using a logical OR. If this field is empty or missing, this rule matches all ports (traffic not restricted by port). If this field is present and contains at least one item, then this rule allows traffic only if the traffic matches at least one port in the list.
    ports: ?[]const NetworkingV1NetworkPolicyPort = null,
    /// to is a list of destinations for outgoing traffic of pods selected for this rule. Items in this list are combined using a logical OR operation. If this field is empty or missing, this rule matches all destinations (traffic not restricted by destination). If this field is present and contains at least one item, this rule allows traffic only if the traffic matches at least one item in the to list.
    to: ?[]const NetworkingV1NetworkPolicyPeer = null,
};

/// NetworkPolicyIngressRule describes a particular set of traffic that is allowed to the pods matched by a NetworkPolicySpec's podSelector. The traffic must match both ports and from.
pub const NetworkingV1NetworkPolicyIngressRule = struct {
    /// from is a list of sources which should be able to access the pods selected for this rule. Items in this list are combined using a logical OR operation. If this field is empty or missing, this rule matches all sources (traffic not restricted by source). If this field is present and contains at least one item, this rule allows traffic only if the traffic matches at least one item in the from list.
    from: ?[]const NetworkingV1NetworkPolicyPeer = null,
    /// ports is a list of ports which should be made accessible on the pods selected for this rule. Each item in this list is combined using a logical OR. If this field is empty or missing, this rule matches all ports (traffic not restricted by port). If this field is present and contains at least one item, then this rule allows traffic only if the traffic matches at least one port in the list.
    ports: ?[]const NetworkingV1NetworkPolicyPort = null,
};

/// NetworkPolicyList is a list of NetworkPolicy objects.
pub const NetworkingV1NetworkPolicyList = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// items is a list of schema objects.
    items: []const NetworkingV1NetworkPolicy,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard list metadata. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata
    metadata: ?meta_v1.MetaV1ListMeta = null,
};

/// NetworkPolicyPeer describes a peer to allow traffic to/from. Only certain combinations of fields are allowed
pub const NetworkingV1NetworkPolicyPeer = struct {
    /// ipBlock defines policy on a particular IPBlock. If this field is set then neither of the other fields can be.
    ipBlock: ?NetworkingV1IPBlock = null,
    /// namespaceSelector selects namespaces using cluster-scoped labels. This field follows standard label selector semantics; if present but empty, it selects all namespaces.
    namespaceSelector: ?meta_v1.MetaV1LabelSelector = null,
    /// podSelector is a label selector which selects pods. This field follows standard label selector semantics; if present but empty, it selects all pods.
    podSelector: ?meta_v1.MetaV1LabelSelector = null,
};

/// NetworkPolicyPort describes a port to allow traffic on
pub const NetworkingV1NetworkPolicyPort = struct {
    /// endPort indicates that the range of ports from port to endPort if set, inclusive, should be allowed by the policy. This field cannot be defined if the port field is not defined or if the port field is defined as a named (string) port. The endPort must be equal or greater than port.
    endPort: ?i32 = null,
    /// port represents the port on the given protocol. This can either be a numerical or named port on a pod. If this field is not provided, this matches all port names and numbers. If present, only traffic on the specified protocol AND port will be matched.
    port: ?util_intstr.UtilIntstrIntOrString = null,
    /// protocol represents the protocol (TCP, UDP, or SCTP) which traffic must match. If not specified, this field defaults to TCP.
    protocol: ?[]const u8 = null,
};

/// NetworkPolicySpec provides the specification of a NetworkPolicy
pub const NetworkingV1NetworkPolicySpec = struct {
    /// egress is a list of egress rules to be applied to the selected pods. Outgoing traffic is allowed if there are no NetworkPolicies selecting the pod (and cluster policy otherwise allows the traffic), OR if the traffic matches at least one egress rule across all of the NetworkPolicy objects whose podSelector matches the pod. If this field is empty then this NetworkPolicy limits all outgoing traffic (and serves solely to ensure that the pods it selects are isolated by default). This field is beta-level in 1.8
    egress: ?[]const NetworkingV1NetworkPolicyEgressRule = null,
    /// ingress is a list of ingress rules to be applied to the selected pods. Traffic is allowed to a pod if there are no NetworkPolicies selecting the pod (and cluster policy otherwise allows the traffic), OR if the traffic source is the pod's local node, OR if the traffic matches at least one ingress rule across all of the NetworkPolicy objects whose podSelector matches the pod. If this field is empty then this NetworkPolicy does not allow any traffic (and serves solely to ensure that the pods it selects are isolated by default)
    ingress: ?[]const NetworkingV1NetworkPolicyIngressRule = null,
    /// podSelector selects the pods to which this NetworkPolicy object applies. The array of rules is applied to any pods selected by this field. An empty selector matches all pods in the policy's namespace. Multiple network policies can select the same set of pods. In this case, the ingress rules for each are combined additively. This field is optional. If it is not specified, it defaults to an empty selector.
    podSelector: ?meta_v1.MetaV1LabelSelector = null,
    /// policyTypes is a list of rule types that the NetworkPolicy relates to. Valid options are ["Ingress"], ["Egress"], or ["Ingress", "Egress"]. If this field is not specified, it will default based on the existence of ingress or egress rules; policies that contain an egress section are assumed to affect egress, and all policies (whether or not they contain an ingress section) are assumed to affect ingress. If you want to write an egress-only policy, you must explicitly specify policyTypes [ "Egress" ]. Likewise, if you want to write a policy that specifies that no egress is allowed, you must specify a policyTypes value that include "Egress" (since such a policy would not include an egress section and would otherwise default to just [ "Ingress" ]). This field is beta-level in 1.8
    policyTypes: ?[]const []const u8 = null,
};

/// ParentReference describes a reference to a parent object.
pub const NetworkingV1ParentReference = struct {
    /// Group is the group of the object being referenced.
    group: ?[]const u8 = null,
    /// Name is the name of the object being referenced.
    name: []const u8,
    /// Namespace is the namespace of the object being referenced.
    namespace: ?[]const u8 = null,
    /// Resource is the resource of the object being referenced.
    resource: []const u8,
};

/// ServiceBackendPort is the service port being referenced.
pub const NetworkingV1ServiceBackendPort = struct {
    /// name is the name of the port on the Service. This is a mutually exclusive setting with "Number".
    name: ?[]const u8 = null,
    /// number is the numerical port number (e.g. 80) on the Service. This is a mutually exclusive setting with "Name".
    number: ?i32 = null,
};

/// ServiceCIDR defines a range of IP addresses using CIDR format (e.g. 192.168.0.0/24 or 2001:db2::/64). This range is used to allocate ClusterIPs to Service objects.
pub const NetworkingV1ServiceCIDR = struct {
    pub const resource_meta = .{
        .group = "networking.k8s.io",
        .version = "v1",
        .kind = "ServiceCIDR",
        .resource = "servicecidrs",
        .namespaced = false,
        .list_kind = NetworkingV1ServiceCIDRList,
    };

    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard object's metadata. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// spec is the desired state of the ServiceCIDR. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#spec-and-status
    spec: ?NetworkingV1ServiceCIDRSpec = null,
    /// status represents the current state of the ServiceCIDR. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#spec-and-status
    status: ?NetworkingV1ServiceCIDRStatus = null,
};

/// ServiceCIDRList contains a list of ServiceCIDR objects.
pub const NetworkingV1ServiceCIDRList = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// items is the list of ServiceCIDRs.
    items: []const NetworkingV1ServiceCIDR,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard object's metadata. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata
    metadata: ?meta_v1.MetaV1ListMeta = null,
};

/// ServiceCIDRSpec define the CIDRs the user wants to use for allocating ClusterIPs for Services.
pub const NetworkingV1ServiceCIDRSpec = struct {
    /// CIDRs defines the IP blocks in CIDR notation (e.g. "192.168.0.0/24" or "2001:db8::/64") from which to assign service cluster IPs. Max of two CIDRs is allowed, one of each IP family. This field is immutable.
    cidrs: ?[]const []const u8 = null,
};

/// ServiceCIDRStatus describes the current state of the ServiceCIDR.
pub const NetworkingV1ServiceCIDRStatus = struct {
    /// conditions holds an array of metav1.Condition that describe the state of the ServiceCIDR. Current service state
    conditions: ?[]const meta_v1.MetaV1Condition = null,
};
