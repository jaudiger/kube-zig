const std = @import("std");
const kube_zig = @import("kube-zig");
const Client = kube_zig.Client;
const RateLimiter = kube_zig.RateLimiter;

const testing = std.testing;

// Client integration: default options
test "Client.init with defaults has rate limiter enabled" {
    // Arrange
    var client = try Client.init(testing.allocator, std.testing.io, "http://127.0.0.1:8001", .{});
    defer client.deinit(std.testing.io);

    // Act / Assert
    try testing.expect(client.rate_limiter != null);
}

// Client integration: disabled rate limiter
test "Client.init with disabled rate limiter sets rate_limiter to null" {
    // Arrange
    var client = try Client.init(testing.allocator, std.testing.io, "http://127.0.0.1:8001", .{
        .rate_limit = RateLimiter.Config.disabled,
    });
    defer client.deinit(std.testing.io);

    // Act / Assert
    try testing.expect(client.rate_limiter == null);
}

// Client integration: custom pool size
test "Client.init with custom pool size succeeds and has rate limiter" {
    // Arrange
    var client = try Client.init(testing.allocator, std.testing.io, "http://127.0.0.1:8001", .{
        .pool_size = 64,
    });
    defer client.deinit(std.testing.io);

    // Act / Assert
    try testing.expect(client.rate_limiter != null);
}

// Client integration: custom rate limiter config
test "Client.init with custom rate limit config creates non-null limiter" {
    // Arrange
    var client = try Client.init(testing.allocator, std.testing.io, "http://127.0.0.1:8001", .{
        .rate_limit = .{ .qps = 100.0, .burst = 50 },
    });
    defer client.deinit(std.testing.io);

    // Act / Assert
    try testing.expect(client.rate_limiter != null);
}
