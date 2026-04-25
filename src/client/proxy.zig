//! Configuration for connecting to a Kubernetes API server via `kubectl proxy`.
//!
//! Reads optional environment variables `KUBE_ZIG_PROXY_URL` and
//! `KUBE_ZIG_NAMESPACE` to configure the proxy base URL and target
//! namespace, falling back to `http://127.0.0.1:8001` and `default`.

const std = @import("std");
const testing = std.testing;

/// Configuration for connecting to a Kubernetes API server via `kubectl proxy`.
/// Reads optional environment variables for the proxy URL and namespace:
/// - `KUBE_ZIG_PROXY_URL`: base URL of the proxy (default: `http://127.0.0.1:8001`)
/// - `KUBE_ZIG_NAMESPACE`: target namespace (default: `default`)
pub const ProxyConfig = struct {
    /// Base URL of the kubectl proxy (from `KUBE_ZIG_PROXY_URL` or default `http://127.0.0.1:8001`).
    base_url: []const u8,
    /// Target namespace (from `KUBE_ZIG_NAMESPACE` or default `default`).
    namespace: []const u8,

    const default_url = "http://127.0.0.1:8001";
    const default_namespace = "default";

    /// Read proxy configuration from the provided environment map,
    /// falling back to defaults when the variables are absent.
    pub fn init(environ_map: *const std.process.Environ.Map) ProxyConfig {
        return .{
            .base_url = environ_map.get("KUBE_ZIG_PROXY_URL") orelse default_url,
            .namespace = environ_map.get("KUBE_ZIG_NAMESPACE") orelse default_namespace,
        };
    }
};

test "default_url constant is a valid HTTP URL with localhost" {
    // Act
    const url = ProxyConfig.default_url;

    // Assert
    try testing.expect(std.mem.startsWith(u8, url, "http://"));
    try testing.expect(std.mem.find(u8, url, "127.0.0.1") != null);
}

test "default_namespace constant equals 'default'" {
    // Act
    const ns = ProxyConfig.default_namespace;

    // Assert
    try testing.expectEqualStrings("default", ns);
}
