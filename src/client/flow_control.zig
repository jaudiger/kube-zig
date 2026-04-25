//! API Priority and Fairness (APF) flow-control tracking.
//!
//! Kubernetes 1.29+ returns `X-Kubernetes-PF-FlowSchema-UID` and
//! `X-Kubernetes-PF-PriorityLevel-UID` headers on every response.
//! `FlowControlTracker` stores the most recent values so callers can
//! observe which flow schema and priority level their requests are
//! being classified under.

const std = @import("std");

/// Snapshot of APF flow-control header values from a single response.
/// Fields are null when the corresponding header was absent.
pub const FlowControl = struct {
    flow_schema_uid: ?[]const u8 = null,
    priority_level_uid: ?[]const u8 = null,
};

/// Thread-safe tracker for API Priority and Fairness flow-control state.
///
/// Owns heap-allocated copies of the header values so they outlive the
/// transport response that carried them.
pub const FlowControlTracker = struct {
    allocator: std.mem.Allocator,
    state: FlowControl = .{},
    schema_buf: ?[]const u8 = null,
    priority_buf: ?[]const u8 = null,
    mu: std.Io.Mutex = .init,

    /// Create a tracker with no flow-control state.
    pub fn init(allocator: std.mem.Allocator) FlowControlTracker {
        return .{ .allocator = allocator };
    }

    /// Free owned header buffers.
    pub fn deinit(self: *FlowControlTracker, io: std.Io) void {
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        self.clearLocked();
    }

    /// Read the current flow-control state (thread-safe).
    pub fn get(self: *FlowControlTracker, io: std.Io) FlowControl {
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        return self.state;
    }

    /// Update flow-control state from a transport response.
    pub fn update(self: *FlowControlTracker, io: std.Io, fc: FlowControl) error{OutOfMemory}!void {
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);

        // Pre-allocate both strings before clearing old state, so a
        // partial OOM leaves the tracker unchanged rather than half-updated.
        const new_schema = if (fc.flow_schema_uid) |uid|
            try self.allocator.dupe(u8, uid)
        else
            null;
        errdefer if (new_schema) |s| self.allocator.free(s);

        const new_priority = if (fc.priority_level_uid) |uid|
            try self.allocator.dupe(u8, uid)
        else
            null;

        self.clearLocked();
        self.schema_buf = new_schema;
        self.state.flow_schema_uid = new_schema;
        self.priority_buf = new_priority;
        self.state.priority_level_uid = new_priority;
    }

    fn clearLocked(self: *FlowControlTracker) void {
        if (self.schema_buf) |s| self.allocator.free(s);
        if (self.priority_buf) |s| self.allocator.free(s);
        self.schema_buf = null;
        self.priority_buf = null;
        self.state = .{};
    }
};
