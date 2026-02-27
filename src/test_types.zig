//! Canonical test types shared across library test suites.
//!
//! Provides the superset of metadata, spec, status, and owner-reference
//! fields needed by inline tests in api/, cache/, controller/, and util/.
//! Individual tests set only the fields they need; all others default to null.

const std = @import("std");

/// Mirrors generated MetaV1OwnerReference with all six standard fields.
pub const TestOwnerRef = struct {
    apiVersion: []const u8,
    kind: []const u8,
    name: []const u8,
    uid: []const u8,
    controller: ?bool = null,
    blockOwnerDeletion: ?bool = null,
};

/// Mirrors a single managed-fields entry (manager, operation, etc.).
pub const TestManagedFieldsEntry = struct {
    manager: ?[]const u8 = null,
    operation: ?[]const u8 = null,
    subresource: ?[]const u8 = null,
    apiVersion: ?[]const u8 = null,
    fieldsType: ?[]const u8 = null,
};

/// Superset of all metadata fields used across test files.
pub const TestMeta = struct {
    name: ?[]const u8 = null,
    namespace: ?[]const u8 = null,
    resourceVersion: ?[]const u8 = null,
    uid: ?[]const u8 = null,
    generation: ?i64 = null,
    creationTimestamp: ?[]const u8 = null,
    labels: ?std.json.ArrayHashMap([]const u8) = null,
    annotations: ?std.json.ArrayHashMap([]const u8) = null,
    managedFields: ?[]const TestManagedFieldsEntry = null,
    selfLink: ?[]const u8 = null,
    finalizers: ?[]const []const u8 = null,
    ownerReferences: ?[]const TestOwnerRef = null,
};

/// Superset of spec fields: replicas, selector, paused.
pub const TestSpec = struct {
    replicas: ?i64 = null,
    selector: ?[]const u8 = null,
    paused: ?bool = null,
};

/// Status fields used by equality tests.
pub const TestStatus = struct {
    availableReplicas: ?i32 = null,
    readyReplicas: ?i32 = null,
};

/// Generic resource with metadata, spec, and status (no resource_meta).
pub const TestResource = struct {
    metadata: ?TestMeta = null,
    spec: ?TestSpec = null,
    status: ?TestStatus = null,
};

/// List metadata for paginated list responses.
pub const TestListMeta = struct {
    resourceVersion: ?[]const u8 = null,
    @"continue": ?[]const u8 = null,
    remaining_item_count: ?i64 = null,
};

/// Secondary resource with metadata only (no resource_meta).
pub const TestSecondary = struct {
    metadata: ?TestMeta = null,
};
