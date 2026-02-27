//! Request option structs for Kubernetes API operations.
//!
//! Defines option types for list, watch, create, update, delete, patch,
//! apply, and log retrieval operations. Each struct uses optional fields
//! with null defaults so callers only specify the parameters they need.

const testing = @import("std").testing;

/// Kubernetes patch strategy.
pub const PatchType = enum {
    strategic_merge_patch,
    merge_patch,
    apply,

    /// Return the MIME content type string for this patch strategy.
    pub fn contentType(self: PatchType) []const u8 {
        return switch (self) {
            .strategic_merge_patch => "application/strategic-merge-patch+json",
            .merge_patch => "application/merge-patch+json",
            .apply => "application/apply-patch+yaml",
        };
    }
};

/// Options for patch operations.
pub const PatchOptions = struct {
    /// Patch strategy to use (default: strategic merge patch).
    patch_type: PatchType = .strategic_merge_patch,
    /// Identifier of the field manager for server-side apply tracking.
    field_manager: ?[]const u8 = null,
    /// Force apply, allowing field manager conflicts to be overwritten.
    force: bool = false,
};

/// Kubernetes resource version match strategy for list operations.
pub const ResourceVersionMatch = enum {
    /// Return data at least as new as the provided resourceVersion.
    not_older_than,
    /// Return data at the exact resourceVersion provided.
    exact,

    /// Return the Kubernetes API string representation of this match strategy.
    pub fn toValue(self: ResourceVersionMatch) []const u8 {
        return switch (self) {
            .not_older_than => "NotOlderThan",
            .exact => "Exact",
        };
    }
};

/// Kubernetes delete propagation policy.
pub const PropagationPolicy = enum {
    orphan,
    background,
    foreground,

    /// Return the Kubernetes API string representation of this policy.
    pub fn toValue(self: PropagationPolicy) []const u8 {
        return switch (self) {
            .orphan => "Orphan",
            .background => "Background",
            .foreground => "Foreground",
        };
    }
};

/// Options for list operations.
pub const ListOptions = struct {
    /// Kubernetes label selector expression (e.g. `"app=nginx,env!=dev"`).
    label_selector: ?[]const u8 = null,
    /// Kubernetes field selector expression (e.g. `"status.phase=Running"`).
    field_selector: ?[]const u8 = null,
    /// Resource version for consistent reads or watch starting point.
    resource_version: ?[]const u8 = null,
    /// How the resourceVersion parameter is applied (requires resource_version).
    resource_version_match: ?ResourceVersionMatch = null,
    /// Maximum number of results to return per page. The server may return fewer.
    /// Use `continue_token` from the list metadata to fetch subsequent pages.
    limit: ?i64 = null,
    /// Token from a previous paginated list response (`metadata.continue`)
    /// to retrieve the next page of results.
    continue_token: ?[]const u8 = null,
    /// Server-side timeout for the list/watch call in seconds.
    timeout_seconds: ?i64 = null,
};

/// Options for watch operations.
pub const WatchOptions = struct {
    /// Kubernetes label selector expression (e.g. `"app=nginx,env!=dev"`).
    label_selector: ?[]const u8 = null,
    /// Kubernetes field selector expression (e.g. `"status.phase=Running"`).
    field_selector: ?[]const u8 = null,
    /// Resource version for watch starting point.
    resource_version: ?[]const u8 = null,
    /// Server-side timeout for the watch call in seconds.
    timeout_seconds: ?i64 = null,
    /// Enable bookmark events for efficient reconnection (default: true).
    allow_bookmarks: bool = true,
    /// Maximum bytes allowed for a single watch event line (default: 4 MiB).
    /// Prevents unbounded allocation from large or malicious responses.
    max_line_size: usize = 4 * 1024 * 1024,
};

/// Options for create and update (write) operations.
pub const WriteOptions = struct {
    /// When true, the server validates the request without persisting it.
    dry_run: bool = false,
    /// Identifier of the field manager for server-side apply tracking.
    field_manager: ?[]const u8 = null,
};

/// Options for server-side apply (SSA) operations.
pub const ApplyOptions = struct {
    /// Required. Identifier of the field manager performing the apply.
    field_manager: []const u8,
    /// When true, forces the apply even if another manager owns conflicting fields.
    /// Use with caution: this takes ownership of all fields in the patch body.
    force: bool = false,
};

/// Options for delete operations. When fields are set, they are serialized as
/// a JSON request body sent to the Kubernetes API.
pub const DeleteOptions = struct {
    /// How dependent resources are handled: orphan, background, or foreground deletion.
    propagation_policy: ?PropagationPolicy = null,
    /// Duration in seconds to wait before forceful deletion. 0 means immediate.
    grace_period_seconds: ?i64 = null,
    /// Only delete if the resource UID matches this value (optimistic concurrency guard).
    precondition_uid: ?[]const u8 = null,
    /// Only delete if the resource version matches this value (optimistic concurrency guard).
    precondition_resource_version: ?[]const u8 = null,
};

/// Options for pod log retrieval.
pub const LogOptions = struct {
    /// Name of the container to retrieve logs from (required for multi-container pods).
    container: ?[]const u8 = null,
    /// Stream logs continuously instead of returning the current snapshot.
    follow: ?bool = null,
    /// Number of most-recent log lines to return.
    tail_lines: ?i64 = null,
    /// Only return logs newer than this many seconds ago.
    since_seconds: ?i64 = null,
    /// Prefix each log line with an RFC 3339 timestamp.
    timestamps: ?bool = null,
    /// Return logs from a previous container instance (e.g. after a crash).
    previous: ?bool = null,
    /// Maximum number of bytes of log output to return.
    limit_bytes: ?i64 = null,
};

test "PatchType.contentType: strategic merge patch" {
    // Act
    const ct = PatchType.strategic_merge_patch.contentType();

    // Assert
    try testing.expectEqualStrings("application/strategic-merge-patch+json", ct);
}

test "PatchType.contentType: merge patch" {
    // Act
    const ct = PatchType.merge_patch.contentType();

    // Assert
    try testing.expectEqualStrings("application/merge-patch+json", ct);
}

test "PatchType.contentType: apply (SSA)" {
    // Act
    const ct = PatchType.apply.contentType();

    // Assert
    try testing.expectEqualStrings("application/apply-patch+yaml", ct);
}

test "PropagationPolicy.toValue: orphan returns Orphan" {
    // Act
    const val = PropagationPolicy.orphan.toValue();

    // Assert
    try testing.expectEqualStrings("Orphan", val);
}
