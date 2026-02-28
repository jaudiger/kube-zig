const std = @import("std");
const testing = std.testing;

const Writer = std.Io.Writer;

/// Segments extracted from a fully-qualified definition name.
pub const NameSegments = struct {
    group: []const u8,
    version: []const u8,
    name: []const u8,
};

/// Extract the last 3 dot-separated segments from an FQN.
/// e.g. "io.k8s.api.core.v1.Pod" becomes { .group = "core", .version = "v1", .name = "Pod" }
pub fn getNameSegments(fqn: []const u8) NameSegments {
    // Find last dot (separates name)
    const last_dot = std.mem.lastIndexOfScalar(u8, fqn, '.') orelse return .{
        .group = "",
        .version = "",
        .name = fqn,
    };
    const name = fqn[last_dot + 1 ..];
    const before_name = fqn[0..last_dot];

    // Find second-to-last dot (separates version)
    const version_dot = std.mem.lastIndexOfScalar(u8, before_name, '.') orelse return .{
        .group = "",
        .version = before_name,
        .name = name,
    };
    const version = before_name[version_dot + 1 ..];
    const before_version = before_name[0..version_dot];

    // Find third-to-last dot (separates group)
    const group_dot = std.mem.lastIndexOfScalar(u8, before_version, '.') orelse return .{
        .group = before_version,
        .version = version,
        .name = name,
    };
    const group = before_version[group_dot + 1 ..];

    return .{
        .group = group,
        .version = version,
        .name = name,
    };
}

/// Write a string with its first byte uppercased.
pub fn writeCapitalized(writer: *Writer, s: []const u8) !void {
    if (s.len == 0) return;
    try writer.writeByte(std.ascii.toUpper(s[0]));
    if (s.len > 1) {
        try writer.writeAll(s[1..]);
    }
}

/// Write the struct name for a fully-qualified definition name.
/// e.g. "io.k8s.api.core.v1.Pod" becomes "CoreV1Pod"
pub fn writeStructName(writer: *Writer, fqn: []const u8) !void {
    const segs = getNameSegments(fqn);
    try writeCapitalized(writer, segs.group);
    try writeCapitalized(writer, segs.version);
    try writeCapitalized(writer, segs.name);
}

/// Write the group-version key for a fully-qualified definition name.
/// e.g. group="core", version="v1" becomes "core_v1"
pub fn writeGroupVersionKey(writer: *Writer, group: []const u8, version: []const u8) !void {
    for (group) |c| {
        try writer.writeByte(std.ascii.toLower(c));
    }
    try writer.writeByte('_');
    for (version) |c| {
        try writer.writeByte(std.ascii.toLower(c));
    }
}

/// Compute the group-version key string for a fully-qualified definition name.
/// Returns allocated string. Caller owns memory.
pub fn groupVersionKey(allocator: std.mem.Allocator, fqn: []const u8) ![]const u8 {
    const segs = getNameSegments(fqn);
    const len = segs.group.len + 1 + segs.version.len;
    const result = try allocator.alloc(u8, len);
    var i: usize = 0;
    for (segs.group) |c| {
        result[i] = std.ascii.toLower(c);
        i += 1;
    }
    result[i] = '_';
    i += 1;
    for (segs.version) |c| {
        result[i] = std.ascii.toLower(c);
        i += 1;
    }
    return result;
}

/// Write a struct name reference, qualifying with the group module if it differs
/// from the current group.
/// Same group: writes bare "CoreV1Pod"
/// Different group: writes "meta_v1.MetaV1ObjectMeta"
pub fn writeQualifiedStructName(writer: *Writer, fqn: []const u8, current_group_key: []const u8) !void {
    const segs = getNameSegments(fqn);

    // Compute the target group key inline.
    var key_buf: [256]u8 = undefined;
    var key_writer = Writer.fixed(&key_buf);
    try writeGroupVersionKey(&key_writer, segs.group, segs.version);
    const target_key = key_writer.buffered();

    if (std.mem.eql(u8, target_key, current_group_key)) {
        // Same group: bare name.
        try writeStructName(writer, fqn);
    } else {
        // Different group: qualify with module name.
        try writer.writeAll(target_key);
        try writer.writeByte('.');
        try writeStructName(writer, fqn);
    }
}

/// "#/definitions/io.k8s.api.core.v1.Pod" becomes "io.k8s.api.core.v1.Pod"
pub fn refToFqn(ref: []const u8) []const u8 {
    const prefix = "#/definitions/";
    if (std.mem.startsWith(u8, ref, prefix)) {
        return ref[prefix.len..];
    }
    return ref;
}

/// Zig language keywords that must be escaped with @"..." syntax.
const zig_keywords = std.StaticStringMap(void).initComptime(.{
    .{ "addrspace", {} },
    .{ "align", {} },
    .{ "allowzero", {} },
    .{ "and", {} },
    .{ "anyframe", {} },
    .{ "anytype", {} },
    .{ "asm", {} },
    .{ "async", {} },
    .{ "await", {} },
    .{ "break", {} },
    .{ "callconv", {} },
    .{ "catch", {} },
    .{ "comptime", {} },
    .{ "const", {} },
    .{ "continue", {} },
    .{ "defer", {} },
    .{ "else", {} },
    .{ "enum", {} },
    .{ "errdefer", {} },
    .{ "error", {} },
    .{ "export", {} },
    .{ "extern", {} },
    .{ "fn", {} },
    .{ "for", {} },
    .{ "if", {} },
    .{ "inline", {} },
    .{ "linksection", {} },
    .{ "noalias", {} },
    .{ "nosuspend", {} },
    .{ "null", {} },
    .{ "opaque", {} },
    .{ "or", {} },
    .{ "orelse", {} },
    .{ "packed", {} },
    .{ "pub", {} },
    .{ "resume", {} },
    .{ "return", {} },
    .{ "struct", {} },
    .{ "suspend", {} },
    .{ "switch", {} },
    .{ "test", {} },
    .{ "threadlocal", {} },
    .{ "try", {} },
    .{ "type", {} },
    .{ "undefined", {} },
    .{ "union", {} },
    .{ "unreachable", {} },
    .{ "var", {} },
    .{ "volatile", {} },
    .{ "while", {} },
});

pub fn isZigKeyword(name: []const u8) bool {
    return zig_keywords.has(name);
}

/// Check if a field name starts with '$' or contains '-' (needs quoting).
/// Note: "type" is a Zig keyword but does not need quoting in struct field
/// position; zig fmt will strip the quoting.
pub fn needsQuoting(name: []const u8) bool {
    if (name.len == 0) return true;
    if (isZigKeyword(name) and !std.mem.eql(u8, name, "type")) return true;
    if (name[0] == '$' or name[0] == '-') return true;
    for (name) |c| {
        if (c == '-' or c == '.' or c == '/') return true;
    }
    return false;
}

// getNameSegments tests
test "getNameSegments: standard FQN returns last three dot-separated segments" {
    // Act
    const segs = getNameSegments("io.k8s.api.core.v1.Pod");

    // Assert
    try testing.expectEqualStrings("core", segs.group);
    try testing.expectEqualStrings("v1", segs.version);
    try testing.expectEqualStrings("Pod", segs.name);
}

test "getNameSegments: deeply nested FQN returns last three segments" {
    // Act
    const segs = getNameSegments("io.k8s.apimachinery.pkg.apis.meta.v1.ObjectMeta");

    // Assert
    try testing.expectEqualStrings("meta", segs.group);
    try testing.expectEqualStrings("v1", segs.version);
    try testing.expectEqualStrings("ObjectMeta", segs.name);
}

test "getNameSegments: three-segment FQN uses first segment as group" {
    // Act
    const segs = getNameSegments("core.v1.Pod");

    // Assert
    try testing.expectEqualStrings("core", segs.group);
    try testing.expectEqualStrings("v1", segs.version);
    try testing.expectEqualStrings("Pod", segs.name);
}

test "getNameSegments: two-segment input returns empty group" {
    // Act
    const segs = getNameSegments("v1.Pod");

    // Assert
    try testing.expectEqualStrings("", segs.group);
    try testing.expectEqualStrings("v1", segs.version);
    try testing.expectEqualStrings("Pod", segs.name);
}

test "getNameSegments: single segment with no dots returns it as name" {
    // Act
    const segs = getNameSegments("Pod");

    // Assert
    try testing.expectEqualStrings("", segs.group);
    try testing.expectEqualStrings("", segs.version);
    try testing.expectEqualStrings("Pod", segs.name);
}

test "getNameSegments: empty string returns all empty segments" {
    // Act
    const segs = getNameSegments("");

    // Assert
    try testing.expectEqualStrings("", segs.group);
    try testing.expectEqualStrings("", segs.version);
    try testing.expectEqualStrings("", segs.name);
}

test "getNameSegments: four-segment FQN extracts last three correctly" {
    // Act
    const segs = getNameSegments("io.k8s.apimachinery.pkg.api.resource.Quantity");

    // Assert
    try testing.expectEqualStrings("api", segs.group);
    try testing.expectEqualStrings("resource", segs.version);
    try testing.expectEqualStrings("Quantity", segs.name);
}

test "getNameSegments: trailing dot produces empty name" {
    // Act
    const segs = getNameSegments("a.b.c.");

    // Assert
    try testing.expectEqualStrings("b", segs.group);
    try testing.expectEqualStrings("c", segs.version);
    try testing.expectEqualStrings("", segs.name);
}

test "getNameSegments: leading dot produces empty first segment" {
    // Act
    const segs = getNameSegments(".v1.Pod");

    // Assert
    try testing.expectEqualStrings("", segs.group);
    try testing.expectEqualStrings("v1", segs.version);
    try testing.expectEqualStrings("Pod", segs.name);
}

test "getNameSegments: consecutive dots produce empty intermediate segments" {
    // Act
    const segs = getNameSegments("a..b");

    // Assert
    try testing.expectEqualStrings("a", segs.group);
    try testing.expectEqualStrings("", segs.version);
    try testing.expectEqualStrings("b", segs.name);
}

test "getNameSegments: single dot returns empty version and empty name" {
    // Act
    const segs = getNameSegments(".");

    // Assert
    try testing.expectEqualStrings("", segs.group);
    try testing.expectEqualStrings("", segs.version);
    try testing.expectEqualStrings("", segs.name);
}

// writeCapitalized tests
test "writeCapitalized: lowercase first char is uppercased" {
    // Arrange
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);

    // Act
    try writeCapitalized(&writer, "core");

    // Assert
    try testing.expectEqualStrings("Core", writer.buffered());
}

test "writeCapitalized: empty string writes nothing" {
    // Arrange
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);

    // Act
    try writeCapitalized(&writer, "");

    // Assert
    try testing.expectEqualStrings("", writer.buffered());
}

test "writeCapitalized: single character string is uppercased" {
    // Arrange
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);

    // Act
    try writeCapitalized(&writer, "x");

    // Assert
    try testing.expectEqualStrings("X", writer.buffered());
}

test "writeCapitalized: already uppercase first char is unchanged" {
    // Arrange
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);

    // Act
    try writeCapitalized(&writer, "Pod");

    // Assert
    try testing.expectEqualStrings("Pod", writer.buffered());
}

test "writeCapitalized: non-alpha first char is passed through" {
    // Arrange
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);

    // Act
    try writeCapitalized(&writer, "1abc");

    // Assert
    try testing.expectEqualStrings("1abc", writer.buffered());
}

test "writeCapitalized: only first char is affected, rest preserved" {
    // Arrange
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);

    // Act
    try writeCapitalized(&writer, "aBC");

    // Assert
    try testing.expectEqualStrings("ABC", writer.buffered());
}

// writeStructName tests
test "writeStructName: core v1 resource produces CoreV1Pod" {
    // Arrange
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);

    // Act
    try writeStructName(&writer, "io.k8s.api.core.v1.Pod");

    // Assert
    try testing.expectEqualStrings("CoreV1Pod", writer.buffered());
}

test "writeStructName: apps group produces AppsV1Deployment" {
    // Arrange
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);

    // Act
    try writeStructName(&writer, "io.k8s.api.apps.v1.Deployment");

    // Assert
    try testing.expectEqualStrings("AppsV1Deployment", writer.buffered());
}

test "writeStructName: deeply nested apimachinery FQN" {
    // Arrange
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);

    // Act
    try writeStructName(&writer, "io.k8s.apimachinery.pkg.apis.meta.v1.ObjectMeta");

    // Assert
    try testing.expectEqualStrings("MetaV1ObjectMeta", writer.buffered());
}

test "writeStructName: single segment produces just the capitalized name" {
    // Arrange
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);

    // Act
    try writeStructName(&writer, "Pod");

    // Assert
    try testing.expectEqualStrings("Pod", writer.buffered());
}

test "writeStructName: two segments produce capitalized version and name" {
    // Arrange
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);

    // Act
    try writeStructName(&writer, "v1.Pod");

    // Assert
    try testing.expectEqualStrings("V1Pod", writer.buffered());
}

test "writeStructName: empty string writes nothing" {
    // Arrange
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);

    // Act
    try writeStructName(&writer, "");

    // Assert
    try testing.expectEqualStrings("", writer.buffered());
}

// writeGroupVersionKey tests
test "writeGroupVersionKey: lowercases group and version with underscore separator" {
    // Arrange
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);

    // Act
    try writeGroupVersionKey(&writer, "core", "v1");

    // Assert
    try testing.expectEqualStrings("core_v1", writer.buffered());
}

test "writeGroupVersionKey: uppercase input is lowered" {
    // Arrange
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);

    // Act
    try writeGroupVersionKey(&writer, "APPS", "V1");

    // Assert
    try testing.expectEqualStrings("apps_v1", writer.buffered());
}

test "writeGroupVersionKey: empty group produces underscore prefix" {
    // Arrange
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);

    // Act
    try writeGroupVersionKey(&writer, "", "v1");

    // Assert
    try testing.expectEqualStrings("_v1", writer.buffered());
}

test "writeGroupVersionKey: empty version produces underscore suffix" {
    // Arrange
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);

    // Act
    try writeGroupVersionKey(&writer, "core", "");

    // Assert
    try testing.expectEqualStrings("core_", writer.buffered());
}

test "writeGroupVersionKey: both empty produces just underscore" {
    // Arrange
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);

    // Act
    try writeGroupVersionKey(&writer, "", "");

    // Assert
    try testing.expectEqualStrings("_", writer.buffered());
}

test "writeGroupVersionKey: mixed case input is fully lowered" {
    // Arrange
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);

    // Act
    try writeGroupVersionKey(&writer, "Meta", "V1beta1");

    // Assert
    try testing.expectEqualStrings("meta_v1beta1", writer.buffered());
}

// groupVersionKey tests
test "groupVersionKey: standard FQN allocates correct string" {
    // Arrange
    const allocator = testing.allocator;

    // Act
    const key = try groupVersionKey(allocator, "io.k8s.api.core.v1.Pod");
    defer allocator.free(key);

    // Assert
    try testing.expectEqualStrings("core_v1", key);
}

test "groupVersionKey: apimachinery FQN allocates meta_v1" {
    // Arrange
    const allocator = testing.allocator;

    // Act
    const key = try groupVersionKey(allocator, "io.k8s.apimachinery.pkg.apis.meta.v1.ObjectMeta");
    defer allocator.free(key);

    // Assert
    try testing.expectEqualStrings("meta_v1", key);
}

test "groupVersionKey: single segment FQN produces underscore-only key" {
    // Arrange
    const allocator = testing.allocator;

    // Act
    const key = try groupVersionKey(allocator, "Pod");
    defer allocator.free(key);

    // Assert
    try testing.expectEqualStrings("_", key);
}

test "groupVersionKey: empty string FQN produces underscore-only key" {
    // Arrange
    const allocator = testing.allocator;

    // Act
    const key = try groupVersionKey(allocator, "");
    defer allocator.free(key);

    // Assert
    try testing.expectEqualStrings("_", key);
}

test "groupVersionKey: OOM on allocation returns OutOfMemory" {
    // Arrange
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });

    // Act / Assert
    try testing.expectError(error.OutOfMemory, groupVersionKey(failing.allocator(), "io.k8s.api.core.v1.Pod"));
}

test "groupVersionKey: two-segment FQN produces underscore-prefixed version" {
    // Arrange
    const allocator = testing.allocator;

    // Act
    const key = try groupVersionKey(allocator, "v1.Pod");
    defer allocator.free(key);

    // Assert
    try testing.expectEqualStrings("_v1", key);
}

// writeQualifiedStructName tests
test "writeQualifiedStructName: same group emits bare struct name" {
    // Arrange
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);

    // Act
    try writeQualifiedStructName(&writer, "io.k8s.api.core.v1.Pod", "core_v1");

    // Assert
    try testing.expectEqualStrings("CoreV1Pod", writer.buffered());
}

test "writeQualifiedStructName: different group emits module-qualified name" {
    // Arrange
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);

    // Act
    try writeQualifiedStructName(&writer, "io.k8s.apimachinery.pkg.apis.meta.v1.ObjectMeta", "core_v1");

    // Assert
    try testing.expectEqualStrings("meta_v1.MetaV1ObjectMeta", writer.buffered());
}

test "writeQualifiedStructName: cross-group apps from core is qualified" {
    // Arrange
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);

    // Act
    try writeQualifiedStructName(&writer, "io.k8s.api.apps.v1.Deployment", "core_v1");

    // Assert
    try testing.expectEqualStrings("apps_v1.AppsV1Deployment", writer.buffered());
}

test "writeQualifiedStructName: same group apps emits bare name" {
    // Arrange
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);

    // Act
    try writeQualifiedStructName(&writer, "io.k8s.api.apps.v1.Deployment", "apps_v1");

    // Assert
    try testing.expectEqualStrings("AppsV1Deployment", writer.buffered());
}

// refToFqn tests
test "refToFqn: strips #/definitions/ prefix" {
    // Act
    const result = refToFqn("#/definitions/io.k8s.api.core.v1.Pod");

    // Assert
    try testing.expectEqualStrings("io.k8s.api.core.v1.Pod", result);
}

test "refToFqn: returns input unchanged when no prefix present" {
    // Act
    const result = refToFqn("io.k8s.api.core.v1.Pod");

    // Assert
    try testing.expectEqualStrings("io.k8s.api.core.v1.Pod", result);
}

test "refToFqn: empty string returns empty string" {
    // Act
    const result = refToFqn("");

    // Assert
    try testing.expectEqualStrings("", result);
}

test "refToFqn: prefix alone returns empty string" {
    // Act
    const result = refToFqn("#/definitions/");

    // Assert
    try testing.expectEqualStrings("", result);
}

test "refToFqn: partial prefix is not stripped" {
    // Act
    const result = refToFqn("#/definitions");

    // Assert
    try testing.expectEqualStrings("#/definitions", result);
}

test "refToFqn: different prefix is not stripped" {
    // Act
    const result = refToFqn("#/components/io.k8s.api.core.v1.Pod");

    // Assert
    try testing.expectEqualStrings("#/components/io.k8s.api.core.v1.Pod", result);
}

// isZigKeyword tests
test "isZigKeyword: recognizes common keywords" {
    // Act / Assert
    try testing.expect(isZigKeyword("type"));
    try testing.expect(isZigKeyword("const"));
    try testing.expect(isZigKeyword("return"));
    try testing.expect(isZigKeyword("continue"));
    try testing.expect(isZigKeyword("fn"));
    try testing.expect(isZigKeyword("if"));
    try testing.expect(isZigKeyword("else"));
    try testing.expect(isZigKeyword("for"));
    try testing.expect(isZigKeyword("while"));
    try testing.expect(isZigKeyword("defer"));
    try testing.expect(isZigKeyword("try"));
    try testing.expect(isZigKeyword("null"));
    try testing.expect(isZigKeyword("undefined"));
    try testing.expect(isZigKeyword("error"));
}

test "isZigKeyword: rejects non-keywords" {
    // Act / Assert
    try testing.expect(!isZigKeyword("name"));
    try testing.expect(!isZigKeyword("pod"));
    try testing.expect(!isZigKeyword("apiVersion"));
}

test "isZigKeyword: empty string is not a keyword" {
    // Act / Assert
    try testing.expect(!isZigKeyword(""));
}

test "isZigKeyword: keyword substring is not a keyword" {
    // Act / Assert
    try testing.expect(!isZigKeyword("returns"));
    try testing.expect(!isZigKeyword("constant"));
    try testing.expect(!isZigKeyword("iffy"));
}

test "isZigKeyword: uppercase variant of keyword is not matched" {
    // Act / Assert
    try testing.expect(!isZigKeyword("CONST"));
    try testing.expect(!isZigKeyword("Return"));
    try testing.expect(!isZigKeyword("TYPE"));
}

// needsQuoting tests
test "needsQuoting: Zig keywords except type need quoting" {
    // Act / Assert
    try testing.expect(needsQuoting("continue"));
    try testing.expect(needsQuoting("return"));
    try testing.expect(needsQuoting("const"));
    try testing.expect(needsQuoting("fn"));
    try testing.expect(needsQuoting("defer"));
    try testing.expect(needsQuoting("error"));
}

test "needsQuoting: type keyword does not need quoting" {
    // Act / Assert
    try testing.expect(!needsQuoting("type"));
}

test "needsQuoting: dollar sign prefix needs quoting" {
    // Act / Assert
    try testing.expect(needsQuoting("$ref"));
    try testing.expect(needsQuoting("$"));
}

test "needsQuoting: dash prefix needs quoting" {
    // Act / Assert
    try testing.expect(needsQuoting("-starting"));
    try testing.expect(needsQuoting("-"));
}

test "needsQuoting: embedded dash needs quoting" {
    // Act / Assert
    try testing.expect(needsQuoting("x-k8s"));
    try testing.expect(needsQuoting("some-field"));
}

test "needsQuoting: embedded dot needs quoting" {
    // Act / Assert
    try testing.expect(needsQuoting("some.dotted"));
    try testing.expect(needsQuoting("a.b.c"));
}

test "needsQuoting: embedded slash needs quoting" {
    // Act / Assert
    try testing.expect(needsQuoting("a/b"));
    try testing.expect(needsQuoting("path/to/thing"));
}

test "needsQuoting: empty string needs quoting" {
    // Act / Assert
    try testing.expect(needsQuoting(""));
}

test "needsQuoting: normal identifiers do not need quoting" {
    // Act / Assert
    try testing.expect(!needsQuoting("name"));
    try testing.expect(!needsQuoting("apiVersion"));
    try testing.expect(!needsQuoting("containerPort"));
    try testing.expect(!needsQuoting("metadata"));
    try testing.expect(!needsQuoting("x"));
}

test "needsQuoting: single normal character does not need quoting" {
    // Act / Assert
    try testing.expect(!needsQuoting("a"));
    try testing.expect(!needsQuoting("Z"));
    try testing.expect(!needsQuoting("0"));
}
