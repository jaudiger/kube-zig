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
    mu: std.Thread.Mutex = .{},

    /// Create a tracker with no flow-control state.
    pub fn init(allocator: std.mem.Allocator) FlowControlTracker {
        return .{ .allocator = allocator };
    }

    /// Free owned header buffers.
    pub fn deinit(self: *FlowControlTracker) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.clearLocked();
    }

    /// Read the current flow-control state (thread-safe).
    pub fn get(self: *FlowControlTracker) FlowControl {
        self.mu.lock();
        defer self.mu.unlock();
        return self.state;
    }

    /// Update flow-control state from a transport response.
    pub fn update(self: *FlowControlTracker, fc: FlowControl) void {
        self.mu.lock();
        defer self.mu.unlock();

        self.clearLocked();
        if (fc.flow_schema_uid) |uid| {
            const dupe = self.allocator.dupe(u8, uid) catch null;
            self.schema_buf = dupe;
            self.state.flow_schema_uid = dupe;
        }
        if (fc.priority_level_uid) |uid| {
            const dupe = self.allocator.dupe(u8, uid) catch null;
            self.priority_buf = dupe;
            self.state.priority_level_uid = dupe;
        }
    }

    fn clearLocked(self: *FlowControlTracker) void {
        if (self.schema_buf) |s| self.allocator.free(s);
        if (self.priority_buf) |s| self.allocator.free(s);
        self.schema_buf = null;
        self.priority_buf = null;
        self.state = .{};
    }
};
