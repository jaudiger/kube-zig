const std = @import("std");
const http = std.http;
const kube_zig = @import("kube-zig");
const Client = kube_zig.Client;
const MockTransport = kube_zig.MockTransport;

const testing = std.testing;

// Default field values
test "Client.init leaves all auth fields null" {
    // Arrange
    var client = try Client.init(testing.allocator, "http://127.0.0.1:8001", .{});
    defer client.deinit();

    // Act / Assert
    try testing.expect(client.auth.token_path == null);
    try testing.expect(client.auth.token_buf == null);
}

// statusToError mapping
test "statusToError maps specific 4xx codes to named errors" {
    // Act / Assert
    try testing.expectEqual(error.HttpBadRequest, Client.statusToError(.bad_request));
    try testing.expectEqual(error.HttpUnauthorized, Client.statusToError(.unauthorized));
    try testing.expectEqual(error.HttpForbidden, Client.statusToError(.forbidden));
    try testing.expectEqual(error.HttpNotFound, Client.statusToError(.not_found));
    try testing.expectEqual(error.HttpConflict, Client.statusToError(.conflict));
    try testing.expectEqual(error.HttpUnprocessableEntity, Client.statusToError(.unprocessable_entity));
    try testing.expectEqual(error.HttpTooManyRequests, Client.statusToError(.too_many_requests));
}

test "statusToError maps 5xx codes to server errors" {
    // Act / Assert
    try testing.expectEqual(error.HttpServerError, Client.statusToError(.internal_server_error));
    try testing.expectEqual(error.HttpBadGateway, Client.statusToError(.bad_gateway));
    try testing.expectEqual(error.HttpServiceUnavailable, Client.statusToError(.service_unavailable));
    try testing.expectEqual(error.HttpGatewayTimeout, Client.statusToError(.gateway_timeout));
    try testing.expectEqual(error.HttpServerError, Client.statusToError(.not_implemented));
}

test "statusToError maps unknown 4xx to HttpUnexpectedStatus" {
    // Act / Assert
    try testing.expectEqual(error.HttpUnexpectedStatus, Client.statusToError(.teapot));
}

// Error set membership
test "Canceled is in ApiRequestError error set" {
    // Act
    const err: Client.ApiRequestError = error.Canceled;

    // Assert
    try testing.expectEqual(error.Canceled, err);
}

// clearUnauthorized timing
test "401 response leaves unauthorized flag set" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    mock.respondWith(.unauthorized, "{\"message\":\"Unauthorized\"}");

    var c = mock.client();
    defer c.deinit();
    const ctx = c.context();

    // Act
    const result = try c.get(struct {}, "/api/v1/pods", ctx);
    defer result.deinit();

    // Assert
    try testing.expect(c.auth.shouldForceRefresh());
}

test "successful response clears unauthorized flag" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    mock.respondWith(.ok, "{}");

    var c = mock.client();
    defer c.deinit();
    const ctx = c.context();

    c.auth.markUnauthorized();

    // Act
    const result = try c.get(struct {}, "/api/v1/pods", ctx);
    defer result.deinit();

    // Assert
    try testing.expect(!c.auth.shouldForceRefresh());
}

test "non-401 error response preserves unauthorized flag" {
    // Arrange
    var mock = MockTransport.init(testing.allocator);
    defer mock.deinit();

    mock.respondWith(.internal_server_error, "{\"message\":\"Internal Server Error\"}");

    var c = mock.client();
    defer c.deinit();
    const ctx = c.context();

    c.auth.markUnauthorized();

    // Act
    const result = try c.get(struct {}, "/api/v1/pods", ctx);
    defer result.deinit();

    // Assert
    try testing.expect(c.auth.shouldForceRefresh());
}
