//! Bearer-token authentication for the Kubernetes API client.
//!
//! Reads a service-account token from disk, caches the resulting
//! `Authorization: Bearer <token>` header, and handles forced refreshes
//! after 401 Unauthorized responses. Thread-safe via a mutex.

const std = @import("std");
const logging_mod = @import("../util/logging.zig");
const Logger = logging_mod.Logger;
const LogField = logging_mod.Field;
const testing = std.testing;

/// Encapsulates bearer-token authentication for the Kubernetes API client.
///
/// Reads a service-account token from disk, caches the resulting
/// Authorization header, and handles forced refreshes after 401 responses.
pub const AuthProvider = struct {
    allocator: std.mem.Allocator,
    token_path: ?[]const u8,
    token_buf: ?[]const u8,
    bearer_header: ?[]const u8,
    token_last_read: ?std.Io.Clock.Timestamp,
    mu: std.Io.Mutex,
    last_unauthorized: std.atomic.Value(bool),
    logger: Logger,

    /// Error set for authentication operations.
    pub const Error = error{ OutOfMemory, HttpRequestFailed };

    /// Create an AuthProvider that reads tokens from `token_path`.
    pub fn init(allocator: std.mem.Allocator, token_path: ?[]const u8, logger: Logger) AuthProvider {
        return .{
            .allocator = allocator,
            .token_path = token_path,
            .token_buf = null,
            .bearer_header = null,
            .token_last_read = null,
            .mu = .init,
            .last_unauthorized = std.atomic.Value(bool).init(false),
            .logger = logger,
        };
    }

    /// Create an AuthProvider with no token path (for tests/mocks).
    pub fn none(allocator: std.mem.Allocator) AuthProvider {
        return init(allocator, null, Logger.noop);
    }

    /// Release token and header buffers.
    pub fn deinit(self: *AuthProvider) void {
        if (self.bearer_header) |bh| self.allocator.free(bh);
        if (self.token_buf) |buf| self.allocator.free(buf);
    }

    /// Check whether a forced token refresh should be attempted
    /// (i.e. the last request received a 401 Unauthorized).
    pub fn shouldForceRefresh(self: *AuthProvider) bool {
        return self.last_unauthorized.load(.acquire);
    }

    /// Mark that an Unauthorized response was received, triggering
    /// a forced token refresh on the next request.
    pub fn markUnauthorized(self: *AuthProvider) void {
        self.last_unauthorized.store(true, .release);
    }

    /// Clear the forced-refresh flag after a successful token read.
    pub fn clearUnauthorized(self: *AuthProvider) void {
        self.last_unauthorized.store(false, .release);
    }

    /// Refresh the bearer token if needed and return a heap-allocated
    /// copy of the current Authorization header, or null if no auth
    /// is configured. The caller owns the returned slice and must
    /// free it with `self.allocator`.
    /// Thread-safe: acquires `mu` so that concurrent callers
    /// cannot race on token state.
    pub fn getAuthHeader(self: *AuthProvider, io: std.Io, force: bool) Error!?[]const u8 {
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        try self.readToken(io, force);
        if (self.bearer_header) |bh| {
            return self.allocator.dupe(u8, bh) catch return error.OutOfMemory;
        }
        return null;
    }

    fn readToken(self: *AuthProvider, io: std.Io, force: bool) Error!void {
        const path = self.token_path orelse return;

        if (force) {
            self.logger.warn("forcing token refresh after unauthorized response", &.{});
        }

        if (!force) {
            if (self.token_last_read) |last| {
                const elapsed_ns: i96 = last.untilNow(io).raw.nanoseconds;
                if (elapsed_ns >= 0 and elapsed_ns < 60 * std.time.ns_per_s) return;
            }
        }

        const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch {
            self.logger.err("failed to read service account token", &.{
                LogField.string("token_path", path),
                LogField.string("error", "open failed"),
            });
            return error.HttpRequestFailed;
        };
        defer file.close(io);

        const new_token = std.Io.Dir.cwd().readFileAlloc(io, path, self.allocator, .limited(1024 * 1024)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                self.logger.err("failed to read service account token", &.{
                    LogField.string("token_path", path),
                    LogField.string("error", @errorName(err)),
                });
                return error.HttpRequestFailed;
            },
        };
        self.token_last_read = .now(io, .awake);

        if (self.token_buf) |old| {
            if (std.mem.eql(u8, old, new_token)) {
                self.allocator.free(new_token);
                return;
            }
            self.allocator.free(old);
        }
        self.token_buf = new_token;

        if (self.bearer_header) |old_hdr| self.allocator.free(old_hdr);
        self.bearer_header = std.fmt.allocPrint(self.allocator, "Bearer {s}", .{new_token}) catch return error.OutOfMemory;
        self.logger.debug("service account token refreshed", &.{
            LogField.string("token_path", path),
        });
    }
};

test "readToken caches within 60s window" {
    // Arrange
    const io = std.testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    tmp.dir.writeFile(io, .{ .sub_path = "token", .data = "test-token-v1" }) catch unreachable;

    const path = try tmp.dir.realPathFileAlloc(io, testing.allocator, "token");
    defer testing.allocator.free(path);

    var auth = AuthProvider.init(testing.allocator, path, Logger.noop);
    defer auth.deinit();

    // Act: first call reads the token from disk.
    const h1 = (try auth.getAuthHeader(io, false)).?;
    defer testing.allocator.free(h1);

    try testing.expect(auth.token_last_read != null);

    // Overwrite the file on disk.
    tmp.dir.writeFile(io, .{ .sub_path = "token", .data = "test-token-v2" }) catch unreachable;

    // Act: second call within the cache window returns the cached token.
    const h2 = (try auth.getAuthHeader(io, false)).?;
    defer testing.allocator.free(h2);

    // Assert
    try testing.expectEqualStrings("Bearer test-token-v1", h1);
    try testing.expectEqualStrings("Bearer test-token-v1", h2);
}

test "force refresh bypasses cache" {
    // Arrange
    const io = std.testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    tmp.dir.writeFile(io, .{ .sub_path = "token", .data = "test-token-v1" }) catch unreachable;

    const path = try tmp.dir.realPathFileAlloc(io, testing.allocator, "token");
    defer testing.allocator.free(path);

    var auth = AuthProvider.init(testing.allocator, path, Logger.noop);
    defer auth.deinit();

    const h1 = (try auth.getAuthHeader(io, false)).?;
    defer testing.allocator.free(h1);

    // Overwrite the file on disk.
    tmp.dir.writeFile(io, .{ .sub_path = "token", .data = "test-token-v2" }) catch unreachable;

    // Act: force refresh reads the new token.
    const h2 = (try auth.getAuthHeader(io, true)).?;
    defer testing.allocator.free(h2);

    // Assert
    try testing.expectEqualStrings("Bearer test-token-v1", h1);
    try testing.expectEqualStrings("Bearer test-token-v2", h2);
}
