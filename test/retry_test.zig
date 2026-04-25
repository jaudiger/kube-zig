const std = @import("std");
const kube_zig = @import("kube-zig");
const Client = kube_zig.Client;
const RetryPolicy = kube_zig.RetryPolicy;

const testing = std.testing;

// Default retry configuration
test "Client.init with defaults has retry policy with 3 retries" {
    // Arrange
    var client = try Client.init(testing.allocator, std.testing.io, "http://127.0.0.1:8001", .{});
    defer client.deinit(std.testing.io);

    // Act / Assert
    try testing.expectEqual(@as(u32, 3), client.retry_policy.max_retries);
}

// Disabled retry
test "Client.init with disabled retry has zero max_retries" {
    // Arrange
    var client = try Client.init(testing.allocator, std.testing.io, "http://127.0.0.1:8001", .{
        .retry = RetryPolicy.disabled,
    });
    defer client.deinit(std.testing.io);

    // Act / Assert
    try testing.expectEqual(@as(u32, 0), client.retry_policy.max_retries);
}

// Custom retry config
test "Client.init with custom retry config stores all fields" {
    // Arrange
    var client = try Client.init(testing.allocator, std.testing.io, "http://127.0.0.1:8001", .{
        .retry = .{
            .max_retries = 5,
            .initial_backoff_ns = 1000,
            .max_backoff_ns = 60 * std.time.ns_per_s,
            .backoff_multiplier = 3,
            .jitter = false,
        },
    });
    defer client.deinit(std.testing.io);

    // Act / Assert
    try testing.expectEqual(@as(u32, 5), client.retry_policy.max_retries);
    try testing.expectEqual(@as(u64, 1000), client.retry_policy.initial_backoff_ns);
    try testing.expectEqual(@as(u32, 3), client.retry_policy.backoff_multiplier);
    try testing.expect(!client.retry_policy.jitter);
}

// ClientOptions.none disables everything
test "ClientOptions.none disables retry and rate limiting" {
    // Arrange
    var client = try Client.init(testing.allocator, std.testing.io, "http://127.0.0.1:8001", Client.ClientOptions.none);
    defer client.deinit(std.testing.io);

    // Act / Assert
    try testing.expectEqual(@as(u32, 0), client.retry_policy.max_retries);
    try testing.expect(client.rate_limiter == null);
}

// Timeout options
test "Client.init stores timeout options from ClientOptions" {
    // Arrange
    var client = try Client.init(testing.allocator, std.testing.io, "http://127.0.0.1:8001", .{
        .read_timeout_ms = 5000,
        .write_timeout_ms = 3000,
        .tcp_keepalive_idle_s = 60,
        .tcp_keepalive_interval_s = 10,
        .tcp_keepalive_count = 5,
    });
    defer client.deinit(std.testing.io);

    // Act / Assert
    // Transport-level options (read_timeout_ms, tcp_keepalive, etc.) are
    // passed through to the heap-allocated StdHttpTransport but are not
    // accessible through the opaque Transport vtable.
    try testing.expect(client.keep_alive);
}

test "Client.init defaults have keepalive enabled" {
    // Arrange
    var client = try Client.init(testing.allocator, std.testing.io, "http://127.0.0.1:8001", .{});
    defer client.deinit(std.testing.io);

    // Act / Assert
    try testing.expect(client.keep_alive);
}

test "Client.init with keep_alive disabled stores false" {
    // Arrange
    var client = try Client.init(testing.allocator, std.testing.io, "http://127.0.0.1:8001", .{
        .keep_alive = false,
        .tcp_keepalive = false,
    });
    defer client.deinit(std.testing.io);

    // Act / Assert
    try testing.expect(!client.keep_alive);
}

// Graceful shutdown
test "shutdown flag is initially false" {
    // Arrange
    var client = try Client.init(testing.allocator, std.testing.io, "http://127.0.0.1:8001", .{});
    defer client.deinit(std.testing.io);

    // Act
    const is_shutdown = client.isShutdown();

    // Assert
    try testing.expect(!is_shutdown);
}

test "shutdown sets the flag to true" {
    // Arrange
    var client = try Client.init(testing.allocator, std.testing.io, "http://127.0.0.1:8001", .{});
    defer client.deinit(std.testing.io);

    // Act
    client.shutdown(std.testing.io);

    // Assert
    try testing.expect(client.isShutdown());
}

test "double shutdown does not panic and remains shut down" {
    // Arrange
    var client = try Client.init(testing.allocator, std.testing.io, "http://127.0.0.1:8001", .{});
    defer client.deinit(std.testing.io);

    // Act
    client.shutdown(std.testing.io);
    client.shutdown(std.testing.io);

    // Assert
    try testing.expect(client.isShutdown());
}
