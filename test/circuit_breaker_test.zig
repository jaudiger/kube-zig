const std = @import("std");
const kube_zig = @import("kube-zig");
const Client = kube_zig.Client;
const CircuitBreaker = kube_zig.CircuitBreaker;
const MockTransport = kube_zig.MockTransport;
const RetryPolicy = kube_zig.RetryPolicy;

const testing = std.testing;

// Client with circuit breaker disabled
test "Client with circuit breaker disabled has null circuit_breaker" {
    // Arrange
    var client = try Client.init(testing.allocator, "http://127.0.0.1:8001", .{
        .circuit_breaker = CircuitBreaker.Config.disabled,
    });
    defer client.deinit();

    // Act / Assert
    try testing.expect(client.circuit_breaker == null);
}

test "ClientOptions.none disables circuit breaker" {
    // Arrange
    var client = try Client.init(testing.allocator, "http://127.0.0.1:8001", Client.ClientOptions.none);
    defer client.deinit();

    // Act / Assert
    try testing.expect(client.circuit_breaker == null);
}

test "Client with default options has circuit breaker enabled" {
    // Arrange
    var client = try Client.init(testing.allocator, "http://127.0.0.1:8001", .{});
    defer client.deinit();

    // Act / Assert
    try testing.expect(client.circuit_breaker != null);
}

// retryLoop records transport failures
test "retryLoop records transport failures for circuit breaker" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    // Act
    var c = mock.client();
    defer c.deinit();
    c.circuit_breaker = try CircuitBreaker.init(.{ .failure_threshold = 5 });
    c.retry_policy = RetryPolicy.disabled;

    // Assert
    const r = c.get(struct {}, "/api/v1/pods", c.context());
    try testing.expectError(error.HttpRequestFailed, r);

    try testing.expect(c.circuit_breaker != null);
    if (c.circuit_breaker) |*cb| {
        try testing.expectEqual(@as(u32, 1), cb.consecutive_failures);
    }
}

// retryLoop records 5xx gateway errors as failures
test "retryLoop records 502/503/504 as circuit breaker failures" {
    // Arrange
    const failure_statuses = [_]std.http.Status{ .bad_gateway, .service_unavailable, .gateway_timeout };

    for (failure_statuses) |status| {
        var mock = MockTransport.init(testing.allocator);
        defer mock.deinit();

        var c = mock.client();
        defer c.deinit();
        c.circuit_breaker = try CircuitBreaker.init(.{ .failure_threshold = 5 });
        c.retry_policy = RetryPolicy.disabled;

        // Act
        mock.respondWith(status, "error");

        const result = try c.get(struct {}, "/api/v1/pods", c.context());
        defer result.deinit();

        // Assert
        if (c.circuit_breaker) |*cb| {
            try testing.expectEqual(@as(u32, 1), cb.consecutive_failures);
        }
    }
}

// retryLoop records 4xx/429 as success
test "retryLoop records 404 and 429 as circuit breaker success" {
    // Arrange
    const success_statuses = [_]std.http.Status{ .not_found, .too_many_requests };

    for (success_statuses) |status| {
        var mock = MockTransport.init(testing.allocator);
        defer mock.deinit();

        var c = mock.client();
        defer c.deinit();
        c.circuit_breaker = try CircuitBreaker.init(.{ .failure_threshold = 5 });
        c.retry_policy = RetryPolicy.disabled;

        // Pre-load failures to verify they get reset
        if (c.circuit_breaker) |*cb| {
            cb.recordFailure();
            cb.recordFailure();
        }

        // Act
        mock.respondWith(status, "response");

        const result = try c.get(struct {}, "/api/v1/pods", c.context());
        defer result.deinit();

        // Assert
        if (c.circuit_breaker) |*cb| {
            try testing.expectEqual(@as(u32, 0), cb.consecutive_failures);
        }
    }
}

// CircuitBreakerOpen propagated from retryLoop
test "CircuitBreakerOpen propagated from retryLoop without transport call" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    // Act
    var c = mock.client();
    defer c.deinit();
    c.circuit_breaker = try CircuitBreaker.init(.{
        .failure_threshold = 1,
        .recovery_timeout_ns = 60 * std.time.ns_per_s,
    });
    c.retry_policy = RetryPolicy.disabled;

    // Assert
    // Trip the circuit manually.
    if (c.circuit_breaker) |*cb| cb.recordFailure();

    const r = c.get(struct {}, "/api/v1/pods", c.context());
    try testing.expectError(error.CircuitBreakerOpen, r);

    try testing.expectEqual(@as(usize, 0), mock.requestCount());
}
