//! Comptime validators for Kubernetes resource type shapes.
//!
//! Centralizes field-presence checks used across utility modules to
//! ensure types have the expected structure (metadata, spec, status,
//! etc.) before operating on them. Invalid types produce clear
//! compile errors with the missing field name and caller context.

const testing = @import("std").testing;

/// Validates that the given type has a `metadata` field.
/// Produces a compile error if the field is absent.
pub fn validateHasMetadata(comptime T: type) void {
    if (!@hasField(T, "metadata")) {
        @compileError("type '" ++ @typeName(T) ++ "' has no 'metadata' field");
    }
}

/// Validates that the given type has the specified field.
/// Produces a compile error including the caller context if the field is absent.
pub fn validateHasField(comptime T: type, comptime field_name: []const u8, comptime context: []const u8) void {
    if (!@hasField(T, field_name)) {
        @compileError(context ++ " requires type '" ++ @typeName(T) ++ "' to have a '" ++ field_name ++ "' field");
    }
}

test "validateHasMetadata accepts type with metadata field" {
    // Arrange
    const WithMeta = struct { metadata: ?u8 = null };

    // Act / Assert
    comptime validateHasMetadata(WithMeta);
}

test "validateHasField accepts type with matching field" {
    // Arrange
    const WithSpec = struct { spec: ?u8 = null };

    // Act / Assert
    comptime validateHasField(WithSpec, "spec", "specEqual");
}

test "type without metadata field detected" {
    // Act / Assert
    const NoMetadata = struct { spec: ?i32 = null };
    try testing.expect(!@hasField(NoMetadata, "metadata"));
}

test "type without target field detected" {
    // Act / Assert
    const NoSpec = struct { metadata: ?i32 = null };
    try testing.expect(!@hasField(NoSpec, "spec"));
}
