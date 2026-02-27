// Auto-generated from Kubernetes OpenAPI spec.
// Do not edit manually. Regenerate with: zig build generate

const std = @import("std");
const json = std.json;
const meta_v1 = @import("meta_v1.zig");

/// CustomResourceColumnDefinition specifies a column for server side printing.
pub const ApiextensionsV1CustomResourceColumnDefinition = struct {
    /// description is a human readable description of this column.
    description: ?[]const u8 = null,
    /// format is an optional OpenAPI type definition for this column. The 'name' format is applied to the primary identifier column to assist in clients identifying column is the resource name. See https://github.com/OAI/OpenAPI-Specification/blob/master/versions/2.0.md#data-types for details.
    format: ?[]const u8 = null,
    /// jsonPath is a simple JSON path (i.e. with array notation) which is evaluated against each custom resource to produce the value for this column.
    jsonPath: []const u8,
    /// name is a human readable name for the column.
    name: []const u8,
    /// priority is an integer defining the relative importance of this column compared to others. Lower numbers are considered higher priority. Columns that may be omitted in limited space scenarios should be given a priority greater than 0.
    priority: ?i32 = null,
    /// type is an OpenAPI type definition for this column. See https://github.com/OAI/OpenAPI-Specification/blob/master/versions/2.0.md#data-types for details.
    type: []const u8,
};

/// CustomResourceConversion describes how to convert different versions of a CR.
pub const ApiextensionsV1CustomResourceConversion = struct {
    /// strategy specifies how custom resources are converted between versions. Allowed values are: - `"None"`: The converter only change the apiVersion and would not touch any other field in the custom resource. - `"Webhook"`: API Server will call to an external webhook to do the conversion. Additional information
    strategy: []const u8,
    /// webhook describes how to call the conversion webhook. Required when `strategy` is set to `"Webhook"`.
    webhook: ?ApiextensionsV1WebhookConversion = null,
};

/// CustomResourceDefinition represents a resource that should be exposed on the API server.  Its name MUST be in the format <.spec.name>.<.spec.group>.
pub const ApiextensionsV1CustomResourceDefinition = struct {
    pub const resource_meta = .{
        .group = "apiextensions.k8s.io",
        .version = "v1",
        .kind = "CustomResourceDefinition",
        .resource = "customresourcedefinitions",
        .namespaced = false,
        .list_kind = ApiextensionsV1CustomResourceDefinitionList,
    };

    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard object's metadata More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// spec describes how the user wants the resources to appear
    spec: ApiextensionsV1CustomResourceDefinitionSpec,
    /// status indicates the actual state of the CustomResourceDefinition
    status: ?ApiextensionsV1CustomResourceDefinitionStatus = null,
};

/// CustomResourceDefinitionCondition contains details for the current condition of this pod.
pub const ApiextensionsV1CustomResourceDefinitionCondition = struct {
    /// lastTransitionTime last time the condition transitioned from one status to another.
    lastTransitionTime: ?meta_v1.MetaV1Time = null,
    /// message is a human-readable message indicating details about last transition.
    message: ?[]const u8 = null,
    /// observedGeneration represents the .metadata.generation that the condition was set based upon. For instance, if .metadata.generation is currently 12, but the .status.conditions[x].observedGeneration is 9, the condition is out of date with respect to the current state of the instance.
    observedGeneration: ?i64 = null,
    /// reason is a unique, one-word, CamelCase reason for the condition's last transition.
    reason: ?[]const u8 = null,
    /// status is the status of the condition. Can be True, False, Unknown.
    status: []const u8,
    /// type is the type of the condition. Types include Established, NamesAccepted and Terminating.
    type: []const u8,
};

/// CustomResourceDefinitionList is a list of CustomResourceDefinition objects.
pub const ApiextensionsV1CustomResourceDefinitionList = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// items list individual CustomResourceDefinition objects
    items: []const ApiextensionsV1CustomResourceDefinition,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard object's metadata More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata
    metadata: ?meta_v1.MetaV1ListMeta = null,
};

/// CustomResourceDefinitionNames indicates the names to serve this CustomResourceDefinition
pub const ApiextensionsV1CustomResourceDefinitionNames = struct {
    /// categories is a list of grouped resources this custom resource belongs to (e.g. 'all'). This is published in API discovery documents, and used by clients to support invocations like `kubectl get all`.
    categories: ?[]const []const u8 = null,
    /// kind is the serialized kind of the resource. It is normally CamelCase and singular. Custom resource instances will use this value as the `kind` attribute in API calls.
    kind: []const u8,
    /// listKind is the serialized kind of the list for this resource. Defaults to "`kind`List".
    listKind: ?[]const u8 = null,
    /// plural is the plural name of the resource to serve. The custom resources are served under `/apis/<group>/<version>/.../<plural>`. Must match the name of the CustomResourceDefinition (in the form `<names.plural>.<group>`). Must be all lowercase.
    plural: []const u8,
    /// shortNames are short names for the resource, exposed in API discovery documents, and used by clients to support invocations like `kubectl get <shortname>`. It must be all lowercase.
    shortNames: ?[]const []const u8 = null,
    /// singular is the singular name of the resource. It must be all lowercase. Defaults to lowercased `kind`.
    singular: ?[]const u8 = null,
};

/// CustomResourceDefinitionSpec describes how a user wants their resource to appear
pub const ApiextensionsV1CustomResourceDefinitionSpec = struct {
    /// conversion defines conversion settings for the CRD.
    conversion: ?ApiextensionsV1CustomResourceConversion = null,
    /// group is the API group of the defined custom resource. The custom resources are served under `/apis/<group>/...`. Must match the name of the CustomResourceDefinition (in the form `<names.plural>.<group>`).
    group: []const u8,
    /// names specify the resource and kind names for the custom resource.
    names: ApiextensionsV1CustomResourceDefinitionNames,
    /// preserveUnknownFields indicates that object fields which are not specified in the OpenAPI schema should be preserved when persisting to storage. apiVersion, kind, metadata and known fields inside metadata are always preserved. This field is deprecated in favor of setting `x-preserve-unknown-fields` to true in `spec.versions[*].schema.openAPIV3Schema`. See https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/#field-pruning for details.
    preserveUnknownFields: ?bool = null,
    /// scope indicates whether the defined custom resource is cluster- or namespace-scoped. Allowed values are `Cluster` and `Namespaced`.
    scope: []const u8,
    /// versions is the list of all API versions of the defined custom resource. Version names are used to compute the order in which served versions are listed in API discovery. If the version string is "kube-like", it will sort above non "kube-like" version strings, which are ordered lexicographically. "Kube-like" versions start with a "v", then are followed by a number (the major version), then optionally the string "alpha" or "beta" and another number (the minor version). These are sorted first by GA > beta > alpha (where GA is a version with no suffix such as beta or alpha), and then by comparing major version, then minor version. An example sorted list of versions: v10, v2, v1, v11beta2, v10beta3, v3beta1, v12alpha1, v11alpha2, foo1, foo10.
    versions: []const ApiextensionsV1CustomResourceDefinitionVersion,
};

/// CustomResourceDefinitionStatus indicates the state of the CustomResourceDefinition
pub const ApiextensionsV1CustomResourceDefinitionStatus = struct {
    /// acceptedNames are the names that are actually being used to serve discovery. They may be different than the names in spec.
    acceptedNames: ?ApiextensionsV1CustomResourceDefinitionNames = null,
    /// conditions indicate state for particular aspects of a CustomResourceDefinition
    conditions: ?[]const ApiextensionsV1CustomResourceDefinitionCondition = null,
    /// The generation observed by the CRD controller.
    observedGeneration: ?i64 = null,
    /// storedVersions lists all versions of CustomResources that were ever persisted. Tracking these versions allows a migration path for stored versions in etcd. The field is mutable so a migration controller can finish a migration to another version (ensuring no old objects are left in storage), and then remove the rest of the versions from this list. Versions may not be removed from `spec.versions` while they exist in this list.
    storedVersions: ?[]const []const u8 = null,
};

/// CustomResourceDefinitionVersion describes a version for CRD.
pub const ApiextensionsV1CustomResourceDefinitionVersion = struct {
    /// additionalPrinterColumns specifies additional columns returned in Table output. See https://kubernetes.io/docs/reference/using-api/api-concepts/#receiving-resources-as-tables for details. If no columns are specified, a single column displaying the age of the custom resource is used.
    additionalPrinterColumns: ?[]const ApiextensionsV1CustomResourceColumnDefinition = null,
    /// deprecated indicates this version of the custom resource API is deprecated. When set to true, API requests to this version receive a warning header in the server response. Defaults to false.
    deprecated: ?bool = null,
    /// deprecationWarning overrides the default warning returned to API clients. May only be set when `deprecated` is true. The default warning indicates this version is deprecated and recommends use of the newest served version of equal or greater stability, if one exists.
    deprecationWarning: ?[]const u8 = null,
    /// name is the version name, e.g. “v1”, “v2beta1”, etc. The custom resources are served under this version at `/apis/<group>/<version>/...` if `served` is true.
    name: []const u8,
    /// schema describes the schema used for validation, pruning, and defaulting of this version of the custom resource.
    schema: ?ApiextensionsV1CustomResourceValidation = null,
    /// selectableFields specifies paths to fields that may be used as field selectors. A maximum of 8 selectable fields are allowed. See https://kubernetes.io/docs/concepts/overview/working-with-objects/field-selectors
    selectableFields: ?[]const ApiextensionsV1SelectableField = null,
    /// served is a flag enabling/disabling this version from being served via REST APIs
    served: bool,
    /// storage indicates this version should be used when persisting custom resources to storage. There must be exactly one version with storage=true.
    storage: bool,
    /// subresources specify what subresources this version of the defined custom resource have.
    subresources: ?ApiextensionsV1CustomResourceSubresources = null,
};

/// CustomResourceSubresourceScale defines how to serve the scale subresource for CustomResources.
pub const ApiextensionsV1CustomResourceSubresourceScale = struct {
    /// labelSelectorPath defines the JSON path inside of a custom resource that corresponds to Scale `status.selector`. Only JSON paths without the array notation are allowed. Must be a JSON Path under `.status` or `.spec`. Must be set to work with HorizontalPodAutoscaler. The field pointed by this JSON path must be a string field (not a complex selector struct) which contains a serialized label selector in string form. More info: https://kubernetes.io/docs/tasks/access-kubernetes-api/custom-resources/custom-resource-definitions#scale-subresource If there is no value under the given path in the custom resource, the `status.selector` value in the `/scale` subresource will default to the empty string.
    labelSelectorPath: ?[]const u8 = null,
    /// specReplicasPath defines the JSON path inside of a custom resource that corresponds to Scale `spec.replicas`. Only JSON paths without the array notation are allowed. Must be a JSON Path under `.spec`. If there is no value under the given path in the custom resource, the `/scale` subresource will return an error on GET.
    specReplicasPath: []const u8,
    /// statusReplicasPath defines the JSON path inside of a custom resource that corresponds to Scale `status.replicas`. Only JSON paths without the array notation are allowed. Must be a JSON Path under `.status`. If there is no value under the given path in the custom resource, the `status.replicas` value in the `/scale` subresource will default to 0.
    statusReplicasPath: []const u8,
};

/// CustomResourceSubresourceStatus defines how to serve the status subresource for CustomResources. Status is represented by the `.status` JSON path inside of a CustomResource. When set, * exposes a /status subresource for the custom resource * PUT requests to the /status subresource take a custom resource object, and ignore changes to anything except the status stanza * PUT/POST/PATCH requests to the custom resource ignore changes to the status stanza
pub const ApiextensionsV1CustomResourceSubresourceStatus = std.json.Value;

/// CustomResourceSubresources defines the status and scale subresources for CustomResources.
pub const ApiextensionsV1CustomResourceSubresources = struct {
    /// scale indicates the custom resource should serve a `/scale` subresource that returns an `autoscaling/v1` Scale object.
    scale: ?ApiextensionsV1CustomResourceSubresourceScale = null,
    /// status indicates the custom resource should serve a `/status` subresource. When enabled: 1. requests to the custom resource primary endpoint ignore changes to the `status` stanza of the object. 2. requests to the custom resource `/status` subresource ignore changes to anything other than the `status` stanza of the object.
    status: ?ApiextensionsV1CustomResourceSubresourceStatus = null,
};

/// CustomResourceValidation is a list of validation methods for CustomResources.
pub const ApiextensionsV1CustomResourceValidation = struct {
    /// openAPIV3Schema is the OpenAPI v3 schema to use for validation and pruning.
    openAPIV3Schema: ?ApiextensionsV1JSONSchemaProps = null,
};

/// ExternalDocumentation allows referencing an external resource for extended documentation.
pub const ApiextensionsV1ExternalDocumentation = struct {
    description: ?[]const u8 = null,
    url: ?[]const u8 = null,
};

/// JSON represents any valid JSON value. These types are supported: bool, int64, float64, string, []interface{}, map[string]interface{} and nil.
pub const ApiextensionsV1JSON = std.json.Value;

/// JSONSchemaProps is a JSON-Schema following Specification Draft 4 (http://json-schema.org/).
pub const ApiextensionsV1JSONSchemaProps = struct {
    @"$ref": ?[]const u8 = null,
    @"$schema": ?[]const u8 = null,
    additionalItems: ?ApiextensionsV1JSONSchemaPropsOrBool = null,
    additionalProperties: ?ApiextensionsV1JSONSchemaPropsOrBool = null,
    allOf: ?[]const ApiextensionsV1JSONSchemaProps = null,
    anyOf: ?[]const ApiextensionsV1JSONSchemaProps = null,
    /// default is a default value for undefined object fields. Defaulting is a beta feature under the CustomResourceDefaulting feature gate. Defaulting requires spec.preserveUnknownFields to be false.
    default: ?ApiextensionsV1JSON = null,
    definitions: ?json.ArrayHashMap(ApiextensionsV1JSONSchemaProps) = null,
    dependencies: ?json.ArrayHashMap(ApiextensionsV1JSONSchemaPropsOrStringArray) = null,
    description: ?[]const u8 = null,
    @"enum": ?[]const ApiextensionsV1JSON = null,
    example: ?ApiextensionsV1JSON = null,
    exclusiveMaximum: ?bool = null,
    exclusiveMinimum: ?bool = null,
    externalDocs: ?ApiextensionsV1ExternalDocumentation = null,
    /// format is an OpenAPI v3 format string. Unknown formats are ignored. The following formats are validated:
    format: ?[]const u8 = null,
    id: ?[]const u8 = null,
    items: ?ApiextensionsV1JSONSchemaPropsOrArray = null,
    maxItems: ?i64 = null,
    maxLength: ?i64 = null,
    maxProperties: ?i64 = null,
    maximum: ?f64 = null,
    minItems: ?i64 = null,
    minLength: ?i64 = null,
    minProperties: ?i64 = null,
    minimum: ?f64 = null,
    multipleOf: ?f64 = null,
    not: ?ApiextensionsV1JSONSchemaProps = null,
    nullable: ?bool = null,
    oneOf: ?[]const ApiextensionsV1JSONSchemaProps = null,
    pattern: ?[]const u8 = null,
    patternProperties: ?json.ArrayHashMap(ApiextensionsV1JSONSchemaProps) = null,
    properties: ?json.ArrayHashMap(ApiextensionsV1JSONSchemaProps) = null,
    required: ?[]const []const u8 = null,
    title: ?[]const u8 = null,
    type: ?[]const u8 = null,
    uniqueItems: ?bool = null,
    /// x-kubernetes-embedded-resource defines that the value is an embedded Kubernetes runtime.Object, with TypeMeta and ObjectMeta. The type must be object. It is allowed to further restrict the embedded object. kind, apiVersion and metadata are validated automatically. x-kubernetes-preserve-unknown-fields is allowed to be true, but does not have to be if the object is fully specified (up to kind, apiVersion, metadata).
    @"x-kubernetes-embedded-resource": ?bool = null,
    /// x-kubernetes-int-or-string specifies that this value is either an integer or a string. If this is true, an empty type is allowed and type as child of anyOf is permitted if following one of the following patterns:
    @"x-kubernetes-int-or-string": ?bool = null,
    /// x-kubernetes-list-map-keys annotates an array with the x-kubernetes-list-type `map` by specifying the keys used as the index of the map.
    @"x-kubernetes-list-map-keys": ?[]const []const u8 = null,
    /// x-kubernetes-list-type annotates an array to further describe its topology. This extension must only be used on lists and may have 3 possible values:
    @"x-kubernetes-list-type": ?[]const u8 = null,
    /// x-kubernetes-map-type annotates an object to further describe its topology. This extension must only be used when type is object and may have 2 possible values:
    @"x-kubernetes-map-type": ?[]const u8 = null,
    /// x-kubernetes-preserve-unknown-fields stops the API server decoding step from pruning fields which are not specified in the validation schema. This affects fields recursively, but switches back to normal pruning behaviour if nested properties or additionalProperties are specified in the schema. This can either be true or undefined. False is forbidden.
    @"x-kubernetes-preserve-unknown-fields": ?bool = null,
    /// x-kubernetes-validations describes a list of validation rules written in the CEL expression language.
    @"x-kubernetes-validations": ?[]const ApiextensionsV1ValidationRule = null,
};

/// JSONSchemaPropsOrArray represents a value that can either be a JSONSchemaProps or an array of JSONSchemaProps. Mainly here for serialization purposes.
pub const ApiextensionsV1JSONSchemaPropsOrArray = std.json.Value;

/// JSONSchemaPropsOrBool represents JSONSchemaProps or a boolean value. Defaults to true for the boolean property.
pub const ApiextensionsV1JSONSchemaPropsOrBool = std.json.Value;

/// JSONSchemaPropsOrStringArray represents a JSONSchemaProps or a string array.
pub const ApiextensionsV1JSONSchemaPropsOrStringArray = std.json.Value;

/// SelectableField specifies the JSON path of a field that may be used with field selectors.
pub const ApiextensionsV1SelectableField = struct {
    /// jsonPath is a simple JSON path which is evaluated against each custom resource to produce a field selector value. Only JSON paths without the array notation are allowed. Must point to a field of type string, boolean or integer. Types with enum values and strings with formats are allowed. If jsonPath refers to absent field in a resource, the jsonPath evaluates to an empty string. Must not point to metdata fields. Required.
    jsonPath: []const u8,
};

/// ServiceReference holds a reference to Service.legacy.k8s.io
pub const ApiextensionsV1ServiceReference = struct {
    /// name is the name of the service. Required
    name: []const u8,
    /// namespace is the namespace of the service. Required
    namespace: []const u8,
    /// path is an optional URL path at which the webhook will be contacted.
    path: ?[]const u8 = null,
    /// port is an optional service port at which the webhook will be contacted. `port` should be a valid port number (1-65535, inclusive). Defaults to 443 for backward compatibility.
    port: ?i32 = null,
};

/// ValidationRule describes a validation rule written in the CEL expression language.
pub const ApiextensionsV1ValidationRule = struct {
    /// fieldPath represents the field path returned when the validation fails. It must be a relative JSON path (i.e. with array notation) scoped to the location of this x-kubernetes-validations extension in the schema and refer to an existing field. e.g. when validation checks if a specific attribute `foo` under a map `testMap`, the fieldPath could be set to `.testMap.foo` If the validation checks two lists must have unique attributes, the fieldPath could be set to either of the list: e.g. `.testList` It does not support list numeric index. It supports child operation to refer to an existing field currently. Refer to [JSONPath support in Kubernetes](https://kubernetes.io/docs/reference/kubectl/jsonpath/) for more info. Numeric index of array is not supported. For field name which contains special characters, use `['specialName']` to refer the field name. e.g. for attribute `foo.34$` appears in a list `testList`, the fieldPath could be set to `.testList['foo.34$']`
    fieldPath: ?[]const u8 = null,
    /// Message represents the message displayed when validation fails. The message is required if the Rule contains line breaks. The message must not contain line breaks. If unset, the message is "failed rule: {Rule}". e.g. "must be a URL with the host matching spec.host"
    message: ?[]const u8 = null,
    /// MessageExpression declares a CEL expression that evaluates to the validation failure message that is returned when this rule fails. Since messageExpression is used as a failure message, it must evaluate to a string. If both message and messageExpression are present on a rule, then messageExpression will be used if validation fails. If messageExpression results in a runtime error, the runtime error is logged, and the validation failure message is produced as if the messageExpression field were unset. If messageExpression evaluates to an empty string, a string with only spaces, or a string that contains line breaks, then the validation failure message will also be produced as if the messageExpression field were unset, and the fact that messageExpression produced an empty string/string with only spaces/string with line breaks will be logged. messageExpression has access to all the same variables as the rule; the only difference is the return type. Example: "x must be less than max ("+string(self.max)+")"
    messageExpression: ?[]const u8 = null,
    /// optionalOldSelf is used to opt a transition rule into evaluation even when the object is first created, or if the old object is missing the value.
    optionalOldSelf: ?bool = null,
    /// reason provides a machine-readable validation failure reason that is returned to the caller when a request fails this validation rule. The HTTP status code returned to the caller will match the reason of the reason of the first failed validation rule. The currently supported reasons are: "FieldValueInvalid", "FieldValueForbidden", "FieldValueRequired", "FieldValueDuplicate". If not set, default to use "FieldValueInvalid". All future added reasons must be accepted by clients when reading this value and unknown reasons should be treated as FieldValueInvalid.
    reason: ?[]const u8 = null,
    /// Rule represents the expression which will be evaluated by CEL. ref: https://github.com/google/cel-spec The Rule is scoped to the location of the x-kubernetes-validations extension in the schema. The `self` variable in the CEL expression is bound to the scoped value. Example: - Rule scoped to the root of a resource with a status subresource: {"rule": "self.status.actual <= self.spec.maxDesired"}
    rule: []const u8,
};

/// WebhookClientConfig contains the information to make a TLS connection with the webhook.
pub const ApiextensionsV1WebhookClientConfig = struct {
    /// caBundle is a PEM encoded CA bundle which will be used to validate the webhook's server certificate. If unspecified, system trust roots on the apiserver are used.
    caBundle: ?[]const u8 = null,
    /// service is a reference to the service for this webhook. Either service or url must be specified.
    service: ?ApiextensionsV1ServiceReference = null,
    /// url gives the location of the webhook, in standard URL form (`scheme://host:port/path`). Exactly one of `url` or `service` must be specified.
    url: ?[]const u8 = null,
};

/// WebhookConversion describes how to call a conversion webhook
pub const ApiextensionsV1WebhookConversion = struct {
    /// clientConfig is the instructions for how to call the webhook if strategy is `Webhook`.
    clientConfig: ?ApiextensionsV1WebhookClientConfig = null,
    /// conversionReviewVersions is an ordered list of preferred `ConversionReview` versions the Webhook expects. The API server will use the first version in the list which it supports. If none of the versions specified in this list are supported by API server, conversion will fail for the custom resource. If a persisted Webhook configuration specifies allowed versions and does not include any versions known to the API Server, calls to the webhook will fail.
    conversionReviewVersions: []const []const u8,
};
