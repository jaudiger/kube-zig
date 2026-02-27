//! In-cluster Kubernetes client configuration.
//!
//! Detects service-account credentials from the standard pod mount at
//! `/var/run/secrets/kubernetes.io/serviceaccount` and the
//! `KUBERNETES_SERVICE_HOST`/`KUBERNETES_SERVICE_PORT` environment variables.
//! Returns `error.NotInCluster` when not running inside a Kubernetes pod.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

/// Configuration for connecting to the Kubernetes API server from inside a pod.
pub const InClusterConfig = struct {
    /// HTTPS base URL of the API server (e.g. `https://10.0.0.1:443`).
    base_url: []const u8,
    /// Absolute path to the cluster CA certificate file.
    ca_cert_path: []const u8,
    /// Absolute path to the service-account bearer token file.
    token_path: []const u8,
    /// Namespace the pod is running in.
    namespace: []const u8,

    const sa_dir = "/var/run/secrets/kubernetes.io/serviceaccount";
    const ca_cert = sa_dir ++ "/ca.crt";
    const token = sa_dir ++ "/token";
    const ns_file = sa_dir ++ "/namespace";

    /// Detect in-cluster credentials from the standard service-account mount
    /// and environment variables. Returns `error.NotInCluster` when not running
    /// inside a Kubernetes pod.
    pub fn init(allocator: Allocator) !InClusterConfig {
        const host = std.posix.getenv("KUBERNETES_SERVICE_HOST") orelse return error.NotInCluster;
        const port = std.posix.getenv("KUBERNETES_SERVICE_PORT") orelse return error.NotInCluster;

        const base_url = try buildBaseUrl(allocator, host, port);
        errdefer allocator.free(base_url);

        // Verify CA cert and token files exist.
        std.fs.cwd().access(ca_cert, .{}) catch return error.NotInCluster;
        std.fs.cwd().access(token, .{}) catch return error.NotInCluster;

        // Read namespace file and trim trailing whitespace.
        const raw_ns = std.fs.cwd().readFileAlloc(allocator, ns_file, 1024) catch return error.NotInCluster;
        defer allocator.free(raw_ns);
        const trimmed = std.mem.trimRight(u8, raw_ns, &std.ascii.whitespace);
        const namespace = try allocator.dupe(u8, trimmed);
        errdefer allocator.free(namespace);

        return .{
            .base_url = base_url,
            .ca_cert_path = ca_cert,
            .token_path = token,
            .namespace = namespace,
        };
    }

    /// Free owned memory (`base_url` and `namespace`).
    pub fn deinit(self: *InClusterConfig, allocator: Allocator) void {
        allocator.free(self.base_url);
        allocator.free(self.namespace);
        self.* = undefined;
    }

    /// Build the base URL from host and port, wrapping IPv6 addresses in brackets.
    pub fn buildBaseUrl(allocator: Allocator, host: []const u8, port: []const u8) ![]const u8 {
        if (std.mem.indexOfScalar(u8, host, ':') != null) {
            // IPv6: wrap in brackets.
            return std.fmt.allocPrint(allocator, "https://[{s}]:{s}", .{ host, port });
        }
        return std.fmt.allocPrint(allocator, "https://{s}:{s}", .{ host, port });
    }
};

test "init returns NotInCluster when env vars are absent" {
    // Arrange
    const result = InClusterConfig.init(testing.allocator);

    // Act / Assert
    try testing.expectError(error.NotInCluster, result);
}

test "buildBaseUrl wraps IPv4 host with https scheme" {
    // Arrange
    const host = "10.0.0.1";
    const port = "443";

    // Act
    const url = try InClusterConfig.buildBaseUrl(testing.allocator, host, port);
    defer testing.allocator.free(url);

    // Assert
    try testing.expectEqualStrings("https://10.0.0.1:443", url);
}

test "buildBaseUrl wraps IPv6 host in brackets" {
    // Arrange
    const host = "fd00::1";
    const port = "443";

    // Act
    const url = try InClusterConfig.buildBaseUrl(testing.allocator, host, port);
    defer testing.allocator.free(url);

    // Assert
    try testing.expectEqualStrings("https://[fd00::1]:443", url);
}

test "buildBaseUrl handles DNS hostname without brackets" {
    // Arrange
    const host = "kubernetes.default.svc";
    const port = "443";

    // Act
    const url = try InClusterConfig.buildBaseUrl(testing.allocator, host, port);
    defer testing.allocator.free(url);

    // Assert
    try testing.expectEqualStrings("https://kubernetes.default.svc:443", url);
}

test "buildBaseUrl handles custom port number" {
    // Arrange
    const host = "10.96.0.1";
    const port = "6443";

    // Act
    const url = try InClusterConfig.buildBaseUrl(testing.allocator, host, port);
    defer testing.allocator.free(url);

    // Assert
    try testing.expectEqualStrings("https://10.96.0.1:6443", url);
}

test "buildBaseUrl handles IPv6 loopback address" {
    // Arrange
    const host = "::1";
    const port = "443";

    // Act
    const url = try InClusterConfig.buildBaseUrl(testing.allocator, host, port);
    defer testing.allocator.free(url);

    // Assert
    try testing.expectEqualStrings("https://[::1]:443", url);
}

test "buildBaseUrl handles full IPv6 address" {
    // Arrange
    const host = "2001:0db8:85a3:0000:0000:8a2e:0370:7334";
    const port = "6443";

    // Act
    const url = try InClusterConfig.buildBaseUrl(testing.allocator, host, port);
    defer testing.allocator.free(url);

    // Assert
    try testing.expectEqualStrings("https://[2001:0db8:85a3:0000:0000:8a2e:0370:7334]:6443", url);
}

test "buildBaseUrl handles IPv6 with zone ID" {
    // Arrange
    const host = "fe80::1%25eth0";
    const port = "443";

    // Act
    const url = try InClusterConfig.buildBaseUrl(testing.allocator, host, port);
    defer testing.allocator.free(url);

    // Assert
    try testing.expect(std.mem.startsWith(u8, url, "https://["));
    try testing.expect(std.mem.indexOf(u8, url, "fe80::1%25eth0") != null);
}

test "buildBaseUrl handles empty host string" {
    // Arrange
    const host = "";
    const port = "443";

    // Act
    const url = try InClusterConfig.buildBaseUrl(testing.allocator, host, port);
    defer testing.allocator.free(url);

    // Assert
    try testing.expectEqualStrings("https://:443", url);
}

test "buildBaseUrl handles empty port string" {
    // Arrange
    const host = "10.0.0.1";
    const port = "";

    // Act
    const url = try InClusterConfig.buildBaseUrl(testing.allocator, host, port);
    defer testing.allocator.free(url);

    // Assert
    try testing.expectEqualStrings("https://10.0.0.1:", url);
}

test "buildBaseUrl returns OutOfMemory with failing allocator" {
    // Arrange
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });

    // Act
    const result = InClusterConfig.buildBaseUrl(failing.allocator(), "10.0.0.1", "443");

    // Assert
    try testing.expectError(error.OutOfMemory, result);
}
