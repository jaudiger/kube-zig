// Auto-generated from Kubernetes OpenAPI spec.
// Do not edit manually. Regenerate with: zig build generate

const std = @import("std");
const json = std.json;
const meta_v1 = @import("meta_v1.zig");

/// StorageVersionMigration represents a migration of stored data to the latest storage version.
pub const StoragemigrationV1beta1StorageVersionMigration = struct {
    pub const resource_meta = .{
        .group = "storagemigration.k8s.io",
        .version = "v1beta1",
        .kind = "StorageVersionMigration",
        .resource = "storageversionmigrations",
        .namespaced = false,
        .list_kind = StoragemigrationV1beta1StorageVersionMigrationList,
    };

    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard object metadata. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// Specification of the migration.
    spec: ?StoragemigrationV1beta1StorageVersionMigrationSpec = null,
    /// Status of the migration.
    status: ?StoragemigrationV1beta1StorageVersionMigrationStatus = null,
};

/// StorageVersionMigrationList is a collection of storage version migrations.
pub const StoragemigrationV1beta1StorageVersionMigrationList = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// Items is the list of StorageVersionMigration
    items: []const StoragemigrationV1beta1StorageVersionMigration,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard list metadata More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata
    metadata: ?meta_v1.MetaV1ListMeta = null,
};

/// Spec of the storage version migration.
pub const StoragemigrationV1beta1StorageVersionMigrationSpec = struct {
    /// The resource that is being migrated. The migrator sends requests to the endpoint serving the resource. Immutable.
    resource: meta_v1.MetaV1GroupResource,
};

/// Status of the storage version migration.
pub const StoragemigrationV1beta1StorageVersionMigrationStatus = struct {
    /// The latest available observations of the migration's current state.
    conditions: ?[]const meta_v1.MetaV1Condition = null,
    /// ResourceVersion to compare with the GC cache for performing the migration. This is the current resource version of given group, version and resource when kube-controller-manager first observes this StorageVersionMigration resource.
    resourceVersion: ?[]const u8 = null,
};
