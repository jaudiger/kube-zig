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
    token_mtime: ?i96,
    mu: std.Io.Mutex,
    last_unauthorized: std.atomic.Value(bool),
    logger: Logger,

    /// Error set for authentication operations.
    pub const Error = error{ OutOfMemory, TokenReadFailed };

    /// Create an AuthProvider that reads tokens from `token_path`.
    pub fn init(allocator: std.mem.Allocator, token_path: ?[]const u8, logger: Logger) AuthProvider {
        return .{
            .allocator = allocator,
            .token_path = token_path,
            .token_buf = null,
            .bearer_header = null,
            .token_mtime = null,
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
    ///
    /// Uses mtime-based caching: stat the file outside the lock to avoid
    /// holding the mutex during disk I/O, then double-check under the lock
    /// before installing a freshly-read token.
    pub fn getAuthHeader(self: *AuthProvider, io: std.Io, force: bool) Error!?[]const u8 {
        const path = self.token_path orelse return null;

        const s = std.Io.Dir.cwd().statFile(io, path, .{}) catch return error.TokenReadFailed;
        const current_mtime: i96 = s.mtime.nanoseconds;

        // Fast path: cache is valid and no force refresh.
        {
            self.mu.lockUncancelable(io);
            defer self.mu.unlock(io);
            const should_use_cache = !force and if (self.token_mtime) |m| m == current_mtime else false;
            if (should_use_cache) {
                return if (self.bearer_header) |bh|
                    self.allocator.dupe(u8, bh) catch error.OutOfMemory
                else
                    null;
            }
        }

        if (force) self.logger.warn("forcing token refresh after unauthorized response", &.{});

        // Read outside lock.
        const new_token = std.Io.Dir.cwd().readFileAlloc(io, path, self.allocator, .limited(1024 * 1024)) catch |err| {
            self.logger.err("failed to read service account token", &.{
                LogField.string("token_path", path),
                LogField.string("error", @errorName(err)),
            });
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.TokenReadFailed,
            };
        };
        const new_header = std.fmt.allocPrint(self.allocator, "Bearer {s}", .{new_token}) catch {
            self.allocator.free(new_token);
            return error.OutOfMemory;
        };

        // Install if still stale; discard if a concurrent caller already updated.
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);

        if (force or self.token_mtime == null or current_mtime > self.token_mtime.?) {
            if (self.token_buf) |old| self.allocator.free(old);
            if (self.bearer_header) |old| self.allocator.free(old);
            self.token_buf = new_token;
            self.bearer_header = new_header;
            self.token_mtime = current_mtime;
            self.logger.debug("service account token refreshed", &.{
                LogField.string("token_path", path),
            });
        } else {
            self.allocator.free(new_token);
            self.allocator.free(new_header);
        }

        return if (self.bearer_header) |bh|
            self.allocator.dupe(u8, bh) catch error.OutOfMemory
        else
            null;
    }
};

test "readToken caches until mtime changes" {
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

    // Act: second call with unchanged file returns cached token.
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
