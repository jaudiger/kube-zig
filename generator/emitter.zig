const std = @import("std");
const openapi = @import("openapi.zig");
const json_helpers = @import("json_helpers.zig");
const emit_helpers = @import("emit_helpers.zig");
const testing = std.testing;

const Writer = std.Io.Writer;

const asObject = json_helpers.asObject;
const asString = json_helpers.asString;
const asArray = json_helpers.asArray;
const writeFieldName = emit_helpers.writeFieldName;
const writeDocComment = emit_helpers.writeDocComment;
const writeFieldDocComment = emit_helpers.writeFieldDocComment;

/// Entry: a fully-qualified name paired with its schema value.
const DefEntry = struct {
    fqn: []const u8,
    schema: std.json.Value,
};

/// Metadata extracted from OpenAPI paths for a Kubernetes resource type.
const GeneratorResourceMeta = struct {
    group: []const u8,
    version: []const u8,
    kind: []const u8,
    resource: []const u8,
    namespaced: bool,
    list_fqn: []const u8,
};

/// Sort context for sorting a StringArrayHashMap by its string keys.
const StringKeySortCtx = struct {
    keys: []const []const u8,

    pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
        return std.mem.order(u8, ctx.keys[a_index], ctx.keys[b_index]) == .lt;
    }
};

/// Main entry point: generate per-group-version files and a root re-export file.
pub fn generate(allocator: std.mem.Allocator, output_dir: []const u8, definitions: std.json.ObjectMap, paths: ?std.json.ObjectMap) !void {
    // 0. Extract resource metadata from paths (if available).
    var resource_metas = std.StringArrayHashMap(GeneratorResourceMeta).init(allocator);
    defer resource_metas.deinit();

    if (paths) |p| {
        try extractResourceMetas(allocator, p, &resource_metas);
        std.debug.print("Extracted {d} resource metadata entries from paths.\n", .{resource_metas.count()});
    }

    // 1. Group all definitions by group-version key.
    var groups = std.StringArrayHashMap(std.ArrayList(DefEntry)).init(allocator);
    defer {
        for (groups.values()) |*list| {
            list.deinit(allocator);
        }
        for (groups.keys()) |key| {
            allocator.free(key);
        }
        groups.deinit();
    }

    var def_it = definitions.iterator();
    while (def_it.next()) |entry| {
        const fqn = entry.key_ptr.*;
        const schema = entry.value_ptr.*;
        const key = try openapi.groupVersionKey(allocator, fqn);

        const gop = try groups.getOrPut(key);
        if (gop.found_existing) {
            // Key was duplicate; free the new allocation.
            allocator.free(key);
        } else {
            gop.value_ptr.* = .{};
        }
        try gop.value_ptr.append(allocator, .{ .fqn = fqn, .schema = schema });
    }

    // 2. Sort group keys and definitions within each group for deterministic output.
    groups.sort(StringKeySortCtx{ .keys = groups.keys() });
    for (groups.values()) |*entries| {
        std.sort.pdq(DefEntry, entries.items, {}, struct {
            pub fn lessThan(_: void, a: DefEntry, b: DefEntry) bool {
                return std.mem.order(u8, a.fqn, b.fqn) == .lt;
            }
        }.lessThan);
    }

    // Open the output directory.
    var dir = try std.fs.cwd().openDir(output_dir, .{});
    defer dir.close();

    // 3. Generate each per-group file.
    const group_keys = groups.keys();
    const group_values = groups.values();
    for (group_keys, group_values) |group_key, entries| {
        // Collect cross-group dependencies.
        var deps = std.StringArrayHashMap(void).init(allocator);
        defer {
            for (deps.keys()) |dep_key| {
                allocator.free(dep_key);
            }
            deps.deinit();
        }

        for (entries.items) |def_entry| {
            try collectDeps(allocator, def_entry.schema, definitions, group_key, &deps);
        }

        // Sort dep keys for deterministic imports.
        deps.sort(StringKeySortCtx{ .keys = deps.keys() });

        // Build filename: "{group_key}.zig"
        const filename = try std.fmt.allocPrint(allocator, "{s}.zig", .{group_key});
        defer allocator.free(filename);

        const file = try dir.createFile(filename, .{});
        defer file.close();

        var write_buf: [8192]u8 = undefined;
        var file_writer = file.writer(&write_buf);
        const writer = &file_writer.interface;

        // Write header.
        try writer.writeAll(
            \\// Auto-generated from Kubernetes OpenAPI spec.
            \\// Do not edit manually. Regenerate with: zig build generate
            \\
            \\const std = @import("std");
            \\const json = std.json;
            \\
        );

        // Write cross-group imports.
        for (deps.keys()) |dep_key| {
            try writer.print("const {s} = @import(\"{s}.zig\");\n", .{ dep_key, dep_key });
        }
        try writer.writeByte('\n');

        // Write all structs in this group.
        for (entries.items, 0..) |def_entry, i| {
            const meta = resource_metas.get(def_entry.fqn);
            try writeStruct(writer, def_entry.fqn, def_entry.schema, definitions, group_key, meta);
            // Add blank line between structs, but not after the last one.
            if (i + 1 < entries.items.len) {
                try writer.writeByte('\n');
            }
        }

        try writer.flush();
    }

    // 4. Generate root types.zig re-export file.
    {
        const file = try dir.createFile("types.zig", .{});
        defer file.close();

        var write_buf: [8192]u8 = undefined;
        var file_writer = file.writer(&write_buf);
        const writer = &file_writer.interface;

        try writer.writeAll(
            \\// Auto-generated from Kubernetes OpenAPI spec.
            \\// Do not edit manually. Regenerate with: zig build generate
            \\//
            \\// Root re-export file. All types are available as e.g. @import("types.zig").CoreV1Pod
            \\
            \\
        );

        // Import each group module.
        for (group_keys) |group_key| {
            try writer.print("const {s} = @import(\"{s}.zig\");\n", .{ group_key, group_key });
        }
        try writer.writeByte('\n');

        // Re-export std and json for backward compatibility.
        try writer.writeAll(
            \\const std = @import("std");
            \\const json = std.json;
            \\
            \\
        );

        // Re-export every type.
        for (group_keys, group_values) |group_key, entries| {
            for (entries.items) |def_entry| {
                try writer.writeAll("pub const ");
                try openapi.writeStructName(writer, def_entry.fqn);
                try writer.print(" = {s}.", .{group_key});
                try openapi.writeStructName(writer, def_entry.fqn);
                try writer.writeAll(";\n");
            }
        }

        try writer.flush();
    }
}

/// Extract resource metadata from OpenAPI paths section.
///
/// Algorithm:
/// 1. For each path, look at HTTP methods for `x-kubernetes-group-version-kind`.
/// 2. Skip subresource paths (segments after `{name}`).
/// 3. For resource paths (ending with `{name}`): extract resource FQN from GET 200 $ref,
///    resource name from path segment, namespaced from `{namespace}` presence.
/// 4. For collection paths (no `{name}`): extract list FQN from GET 200 $ref.
/// 5. Match pairs by (group, version, kind) to build GeneratorResourceMeta map.
fn extractResourceMetas(
    allocator: std.mem.Allocator,
    paths: std.json.ObjectMap,
    resource_metas: *std.StringArrayHashMap(GeneratorResourceMeta),
) !void {
    // Intermediate structures: keyed by "group/version/kind" tuple string.
    const PathInfo = struct {
        resource_fqn: ?[]const u8 = null,
        list_fqn: ?[]const u8 = null,
        resource_name: ?[]const u8 = null,
        namespaced: bool = false,
        group: []const u8 = "",
        version: []const u8 = "",
        kind: []const u8 = "",
    };

    var info_map = std.StringArrayHashMap(PathInfo).init(allocator);
    defer {
        for (info_map.keys()) |key| {
            allocator.free(key);
        }
        info_map.deinit();
    }

    var path_it = paths.iterator();
    while (path_it.next()) |path_entry| {
        const path = path_entry.key_ptr.*;
        const path_obj = asObject(path_entry.value_ptr.*) orelse continue;

        // Skip subresource paths: anything with segments after {name}.
        if (isSubresourcePath(path)) continue;

        // Skip watch paths: they return WatchEvent, not the actual resource type.
        if (std.mem.indexOf(u8, path, "/watch/") != null) continue;
        if (std.mem.endsWith(u8, path, "/watch")) continue;

        const is_resource_path = std.mem.endsWith(u8, path, "{name}");

        // Find x-kubernetes-group-version-kind from any method on this path.
        const method_names = [_][]const u8{ "get", "post", "put", "delete", "patch" };
        var group: []const u8 = "";
        var version: ?[]const u8 = null;
        var kind: ?[]const u8 = null;

        for (method_names) |method_name| {
            const method_val = path_obj.get(method_name) orelse continue;
            const method_obj = asObject(method_val) orelse continue;
            const gvk = method_obj.get("x-kubernetes-group-version-kind") orelse continue;
            const gvk_obj = asObject(gvk) orelse continue;

            group = if (gvk_obj.get("group")) |g| (asString(g) orelse continue) else "";
            version = if (gvk_obj.get("version")) |v| (asString(v) orelse continue) else null;
            kind = if (gvk_obj.get("kind")) |k| (asString(k) orelse continue) else null;
            break;
        }

        const ver = version orelse continue;
        const knd = kind orelse continue;

        // Build tuple key: "group/version/kind"
        const tuple_key = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ group, ver, knd });

        const gop = try info_map.getOrPut(tuple_key);
        if (gop.found_existing) {
            allocator.free(tuple_key);
        } else {
            gop.value_ptr.* = .{
                .group = group,
                .version = ver,
                .kind = knd,
            };
        }

        // Extract response $ref from the GET method specifically.
        const get_method = path_obj.get("get");
        const is_namespaced_path = std.mem.indexOf(u8, path, "{namespace}") != null;

        if (is_resource_path) {
            if (get_method) |gm| {
                if (getResponseRef(gm)) |fqn| {
                    // Prefer namespaced paths; only set if not already set from a namespaced path.
                    if (gop.value_ptr.resource_fqn == null or is_namespaced_path) {
                        gop.value_ptr.resource_fqn = fqn;
                    }
                }
            }
            if (gop.value_ptr.resource_name == null or is_namespaced_path) {
                gop.value_ptr.resource_name = extractResourceSegment(path);
            }
            if (is_namespaced_path) {
                gop.value_ptr.namespaced = true;
            }
        } else {
            // Collection path.
            if (get_method) |gm| {
                if (getResponseRef(gm)) |fqn| {
                    if (gop.value_ptr.list_fqn == null or is_namespaced_path) {
                        gop.value_ptr.list_fqn = fqn;
                    }
                }
            }
            if (is_namespaced_path) {
                gop.value_ptr.namespaced = true;
            }
        }
    }

    // Build the final resource_metas map from matched pairs.
    for (info_map.values()) |info| {
        const resource_fqn = info.resource_fqn orelse continue;
        const list_fqn = info.list_fqn orelse continue;
        const resource_name = info.resource_name orelse continue;

        try resource_metas.put(resource_fqn, .{
            .group = info.group,
            .version = info.version,
            .kind = info.kind,
            .resource = resource_name,
            .namespaced = info.namespaced,
            .list_fqn = list_fqn,
        });
    }
}

/// Check if a path is a subresource path (has segments after {name}).
fn isSubresourcePath(path: []const u8) bool {
    const name_param = "{name}";
    if (std.mem.indexOf(u8, path, name_param)) |idx| {
        const after = idx + name_param.len;
        if (after < path.len) {
            // There's content after {name}, and it starts with /
            return path[after] == '/';
        }
    }
    return false;
}

/// Extract the $ref FQN from a method's 200 response schema.
fn getResponseRef(method_obj: std.json.Value) ?[]const u8 {
    const obj = asObject(method_obj) orelse return null;
    const responses = asObject(obj.get("responses") orelse return null) orelse return null;
    const ok_response = asObject(responses.get("200") orelse return null) orelse return null;
    const schema_obj = asObject(ok_response.get("schema") orelse return null) orelse return null;
    const ref = schema_obj.get("$ref") orelse return null;
    return openapi.refToFqn(asString(ref) orelse return null);
}

/// Extract the resource segment from a path ending with {name}.
/// e.g. "/api/v1/namespaces/{namespace}/pods/{name}" becomes "pods"
fn extractResourceSegment(path: []const u8) ?[]const u8 {
    // Find {name} and go backwards to find the segment before it.
    const name_param = "/{name}";
    const idx = std.mem.lastIndexOf(u8, path, name_param) orelse return null;
    const before = path[0..idx];
    // Find the last / before {name} to get the resource segment.
    const last_slash = std.mem.lastIndexOfScalar(u8, before, '/') orelse return null;
    return before[last_slash + 1 ..];
}

/// Recursively collect cross-group dependency keys from a schema's $ref fields.
fn collectDeps(
    allocator: std.mem.Allocator,
    schema: std.json.Value,
    definitions: std.json.ObjectMap,
    current_group_key: []const u8,
    deps: *std.StringArrayHashMap(void),
) !void {
    const obj = asObject(schema) orelse return;

    if (obj.get("properties")) |props| {
        const props_obj = asObject(props) orelse return;
        var it = props_obj.iterator();
        while (it.next()) |entry| {
            try collectDepsFromType(allocator, entry.value_ptr.*, definitions, current_group_key, deps);
        }
    }
}

fn collectDepsFromType(
    allocator: std.mem.Allocator,
    schema: std.json.Value,
    definitions: std.json.ObjectMap,
    current_group_key: []const u8,
    deps: *std.StringArrayHashMap(void),
) !void {
    const obj = asObject(schema) orelse return;

    if (obj.get("$ref")) |ref_val| {
        const fqn = openapi.refToFqn(asString(ref_val) orelse return);
        if (definitions.get(fqn) != null) {
            const key = try openapi.groupVersionKey(allocator, fqn);
            if (std.mem.eql(u8, key, current_group_key)) {
                allocator.free(key);
            } else {
                const gop = try deps.getOrPut(key);
                if (gop.found_existing) {
                    allocator.free(key);
                }
            }
        }
        return;
    }

    if (obj.get("type")) |t| {
        const type_str = asString(t) orelse return;
        if (std.mem.eql(u8, type_str, "array")) {
            if (obj.get("items")) |items| {
                try collectDepsFromType(allocator, items, definitions, current_group_key, deps);
            }
        }
        if (std.mem.eql(u8, type_str, "object")) {
            if (obj.get("additionalProperties")) |additional| {
                try collectDepsFromType(allocator, additional, definitions, current_group_key, deps);
            }
        }
    }
}

/// Check if a field name appears in the schema's "required" array.
fn isFieldRequired(field_name: []const u8, required_arr: ?[]const std.json.Value) bool {
    const arr = required_arr orelse return false;
    for (arr) |item| {
        const s = asString(item) orelse continue;
        if (std.mem.eql(u8, s, field_name)) return true;
    }
    return false;
}

fn writeStruct(writer: *Writer, fqn: []const u8, schema: std.json.Value, definitions: std.json.ObjectMap, current_group_key: []const u8, resource_meta: ?GeneratorResourceMeta) !void {
    const obj = asObject(schema) orelse return error.UnexpectedJsonType;

    // Write doc comment from description if present.
    if (obj.get("description")) |desc| {
        if (asString(desc)) |s| try writeDocComment(writer, s);
    }

    try writer.writeAll("pub const ");
    try openapi.writeStructName(writer, fqn);

    if (obj.get("properties")) |props| {
        try writer.writeAll(" = struct {\n");

        // Write resource metadata if this is a resource type.
        if (resource_meta) |meta| {
            try writer.writeAll("    pub const resource_meta = .{\n");
            try writer.print("        .group = \"{s}\",\n", .{meta.group});
            try writer.print("        .version = \"{s}\",\n", .{meta.version});
            try writer.print("        .kind = \"{s}\",\n", .{meta.kind});
            try writer.print("        .resource = \"{s}\",\n", .{meta.resource});
            if (meta.namespaced) {
                try writer.writeAll("        .namespaced = true,\n");
            } else {
                try writer.writeAll("        .namespaced = false,\n");
            }
            // Write list_kind as a type reference (same-file, bare name).
            try writer.writeAll("        .list_kind = ");
            try openapi.writeStructName(writer, meta.list_fqn);
            try writer.writeAll(",\n");
            try writer.writeAll("    };\n\n");
        }

        // Extract the "required" array from the schema, if present.
        const required_arr: ?[]const std.json.Value = blk: {
            const r = obj.get("required") orelse break :blk null;
            const arr = asArray(r) orelse break :blk null;
            break :blk arr.items;
        };

        const props_obj = asObject(props) orelse return error.UnexpectedJsonType;
        var it = props_obj.iterator();
        while (it.next()) |entry| {
            const field_name = entry.key_ptr.*;
            const prop_schema = entry.value_ptr.*;

            // Write field doc comment.
            if (asObject(prop_schema)) |prop_obj| {
                if (prop_obj.get("description")) |desc| {
                    if (asString(desc)) |s| try writeFieldDocComment(writer, s);
                }
            }

            const is_required = isFieldRequired(field_name, required_arr);

            try writer.writeAll("    ");
            try writeFieldName(writer, field_name);
            if (is_required) {
                // Required field: name: Type,
                try writer.writeAll(": ");
                try writeType(writer, prop_schema, definitions, current_group_key);
                try writer.writeAll(",\n");
            } else {
                // Optional field: name: ?Type = null,
                try writer.writeAll(": ?");
                try writeType(writer, prop_schema, definitions, current_group_key);
                try writer.writeAll(" = null,\n");
            }
        }

        try writer.writeAll("};\n");
    } else if (obj.get("type")) |type_val| {
        // Definition without properties: emit a type alias based on the OpenAPI type.
        const type_str = asString(type_val) orelse return error.UnexpectedJsonType;
        if (std.mem.eql(u8, type_str, "string")) {
            const format = if (obj.get("format")) |f| (asString(f) orelse "") else "";
            if (std.mem.eql(u8, format, "int-or-string")) {
                try writeIntOrStringUnion(writer);
            } else {
                // Covers Quantity, Time, MicroTime, etc.
                try writer.writeAll(" = []const u8;\n");
            }
        } else {
            // "object" without properties (FieldsV1, Patch, RawExtension, marker types, etc.)
            try writer.writeAll(" = std.json.Value;\n");
        }
    } else {
        // No type at all (JSON, JSONSchemaPropsOrArray, JSONSchemaPropsOrBool, etc.)
        try writer.writeAll(" = std.json.Value;\n");
    }
}

fn writeType(writer: *Writer, schema: std.json.Value, definitions: std.json.ObjectMap, current_group_key: []const u8) !void {
    const obj = asObject(schema) orelse return error.UnexpectedJsonType;

    // Handle $ref first.
    if (obj.get("$ref")) |ref_val| {
        const fqn = openapi.refToFqn(asString(ref_val) orelse return error.UnexpectedJsonType);
        if (definitions.get(fqn) != null) {
            try openapi.writeQualifiedStructName(writer, fqn, current_group_key);
        } else {
            try writer.writeAll("json.Value");
        }
        return;
    }

    // Handle "type" field.
    const type_str = if (obj.get("type")) |t| (asString(t) orelse return error.UnexpectedJsonType) else {
        try writer.writeAll("json.Value");
        return;
    };

    if (std.mem.eql(u8, type_str, "string")) {
        try writer.writeAll("[]const u8");
        return;
    }

    if (std.mem.eql(u8, type_str, "boolean")) {
        try writer.writeAll("bool");
        return;
    }

    if (std.mem.eql(u8, type_str, "number")) {
        try writer.writeAll("f64");
        return;
    }

    if (std.mem.eql(u8, type_str, "integer")) {
        if (obj.get("format")) |fmt| {
            if (asString(fmt)) |fmt_str| {
                if (std.mem.eql(u8, fmt_str, "int32")) {
                    try writer.writeAll("i32");
                    return;
                }
            }
        }
        try writer.writeAll("i64");
        return;
    }

    if (std.mem.eql(u8, type_str, "array")) {
        try writer.writeAll("[]const ");
        if (obj.get("items")) |items| {
            try writeType(writer, items, definitions, current_group_key);
        } else {
            try writer.writeAll("json.Value");
        }
        return;
    }

    if (std.mem.eql(u8, type_str, "object")) {
        if (obj.get("additionalProperties")) |additional| {
            // Typed map: json.ArrayHashMap(ValueType)
            try writer.writeAll("json.ArrayHashMap(");
            try writeType(writer, additional, definitions, current_group_key);
            try writer.writeAll(")");
            return;
        }
    }

    // "object" without additionalProperties is opaque; use json.Value.
    try writer.writeAll("json.Value");
}

/// Emit a tagged union for Kubernetes IntOrString with custom JSON support.
fn writeIntOrStringUnion(writer: *Writer) !void {
    try writer.writeAll(
        \\ = union(enum) {
        \\    int: i64,
        \\    string: []const u8,
        \\
        \\    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: json.ParseOptions) !@This() {
        \\        switch (try source.peekNextTokenType()) {
        \\            .number => {
        \\                switch (try source.next()) {
        \\                    inline .number, .allocated_number => |s| {
        \\                        return .{ .int = std.fmt.parseInt(i64, s, 10) catch return error.UnexpectedToken };
        \\                    },
        \\                    else => return error.UnexpectedToken,
        \\                }
        \\            },
        \\            .string => {
        \\                switch (try source.nextAlloc(allocator, options.allocate orelse .alloc_if_needed)) {
        \\                    inline .string, .allocated_string => |s| return .{ .string = s },
        \\                    else => return error.UnexpectedToken,
        \\                }
        \\            },
        \\            else => return error.UnexpectedToken,
        \\        }
        \\    }
        \\
        \\    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        \\        switch (self) {
        \\            .int => |v| try jw.write(v),
        \\            .string => |v| try jw.write(v),
        \\        }
        \\    }
        \\};
        \\
    );
}

// ---- isSubresourcePath tests ----

test "isSubresourcePath: pod status is subresource" {
    // Act
    const result = isSubresourcePath("/api/v1/namespaces/{namespace}/pods/{name}/status");

    // Assert
    try testing.expect(result);
}

test "isSubresourcePath: pod log is subresource" {
    // Act
    const result = isSubresourcePath("/api/v1/namespaces/{namespace}/pods/{name}/log");

    // Assert
    try testing.expect(result);
}

test "isSubresourcePath: deployment scale is subresource" {
    // Act
    const result = isSubresourcePath("/apis/apps/v1/namespaces/{namespace}/deployments/{name}/scale");

    // Assert
    try testing.expect(result);
}

test "isSubresourcePath: resource path is not subresource" {
    // Act
    const result = isSubresourcePath("/api/v1/namespaces/{namespace}/pods/{name}");

    // Assert
    try testing.expect(!result);
}

test "isSubresourcePath: collection path is not subresource" {
    // Act
    const result = isSubresourcePath("/api/v1/namespaces/{namespace}/pods");

    // Assert
    try testing.expect(!result);
}

test "isSubresourcePath: cluster path is not subresource" {
    // Act
    const result = isSubresourcePath("/api/v1/nodes");

    // Assert
    try testing.expect(!result);
}

test "isSubresourcePath: path without {name} is not subresource" {
    // Act
    const result = isSubresourcePath("/api/v1/namespaces/{namespace}/configmaps");

    // Assert
    try testing.expect(!result);
}

test "isSubresourcePath: empty string is not subresource" {
    // Act
    const result = isSubresourcePath("");

    // Assert
    try testing.expect(!result);
}

// ---- extractResourceSegment tests ----

test "extractResourceSegment: namespaced pods" {
    // Act
    const seg = extractResourceSegment("/api/v1/namespaces/{namespace}/pods/{name}");

    // Assert
    try testing.expectEqualStrings("pods", seg.?);
}

test "extractResourceSegment: namespaced deployments" {
    // Act
    const seg = extractResourceSegment("/apis/apps/v1/namespaces/{namespace}/deployments/{name}");

    // Assert
    try testing.expectEqualStrings("deployments", seg.?);
}

test "extractResourceSegment: cluster-scoped nodes" {
    // Act
    const seg = extractResourceSegment("/api/v1/nodes/{name}");

    // Assert
    try testing.expectEqualStrings("nodes", seg.?);
}

test "extractResourceSegment: collection path returns null" {
    // Act
    const seg = extractResourceSegment("/api/v1/namespaces/{namespace}/pods");

    // Assert
    try testing.expectEqual(null, seg);
}

test "extractResourceSegment: namespaces collection returns null" {
    // Act
    const seg = extractResourceSegment("/api/v1/namespaces");

    // Assert
    try testing.expectEqual(null, seg);
}

test "extractResourceSegment: empty string returns null" {
    // Act
    const seg = extractResourceSegment("");

    // Assert
    try testing.expectEqual(null, seg);
}

// ---- getResponseRef tests ----

fn parseJson(allocator: std.mem.Allocator, input: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, input, .{});
}

test "getResponseRef: extracts ref from 200 response" {
    // Arrange
    const parsed = try parseJson(testing.allocator,
        \\{"responses":{"200":{"schema":{"$ref":"#/definitions/io.k8s.api.core.v1.Pod"}}}}
    );
    defer parsed.deinit();

    // Act
    const ref = getResponseRef(parsed.value);

    // Assert
    try testing.expectEqualStrings("io.k8s.api.core.v1.Pod", ref.?);
}

test "getResponseRef: empty object returns null" {
    // Arrange
    const parsed = try parseJson(testing.allocator, "{}");
    defer parsed.deinit();

    // Act
    const result = getResponseRef(parsed.value);

    // Assert
    try testing.expectEqual(null, result);
}

test "getResponseRef: no 200 response returns null" {
    // Arrange
    const parsed = try parseJson(testing.allocator,
        \\{"responses":{"201":{}}}
    );
    defer parsed.deinit();

    // Act
    const result = getResponseRef(parsed.value);

    // Assert
    try testing.expectEqual(null, result);
}

test "getResponseRef: 200 without schema returns null" {
    // Arrange
    const parsed = try parseJson(testing.allocator,
        \\{"responses":{"200":{}}}
    );
    defer parsed.deinit();

    // Act
    const result = getResponseRef(parsed.value);

    // Assert
    try testing.expectEqual(null, result);
}

test "getResponseRef: schema without ref returns null" {
    // Arrange
    const parsed = try parseJson(testing.allocator,
        \\{"responses":{"200":{"schema":{"type":"string"}}}}
    );
    defer parsed.deinit();

    // Act
    const result = getResponseRef(parsed.value);

    // Assert
    try testing.expectEqual(null, result);
}

// ---- writeFieldName tests ----

test "writeFieldName: normal name" {
    // Arrange
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);

    // Act
    try writeFieldName(&writer, "name");

    // Assert
    try testing.expectEqualStrings("name", writer.buffered());
}

test "writeFieldName: keyword needs quoting" {
    // Arrange
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);

    // Act
    try writeFieldName(&writer, "continue");

    // Assert
    try testing.expectEqualStrings("@\"continue\"", writer.buffered());
}

test "writeFieldName: dollar ref needs quoting" {
    // Arrange
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);

    // Act
    try writeFieldName(&writer, "$ref");

    // Assert
    try testing.expectEqualStrings("@\"$ref\"", writer.buffered());
}

test "writeFieldName: type does not need quoting" {
    // Arrange
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);

    // Act
    try writeFieldName(&writer, "type");

    // Assert
    try testing.expectEqualStrings("type", writer.buffered());
}

test "writeFieldName: name with dash needs quoting" {
    // Arrange
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);

    // Act
    try writeFieldName(&writer, "x-k8s-field");

    // Assert
    try testing.expectEqualStrings("@\"x-k8s-field\"", writer.buffered());
}

// ---- writeDocComment tests ----

test "writeDocComment: single line" {
    // Arrange
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);

    // Act
    try writeDocComment(&writer, "A pod.");

    // Assert
    try testing.expectEqualStrings("/// A pod.\n", writer.buffered());
}

test "writeDocComment: multiline takes first line only" {
    // Arrange
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);

    // Act
    try writeDocComment(&writer, "First.\nSecond.");

    // Assert
    try testing.expectEqualStrings("/// First.\n", writer.buffered());
}

// ---- writeFieldDocComment tests ----

test "writeFieldDocComment: single line" {
    // Arrange
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);

    // Act
    try writeFieldDocComment(&writer, "The name.");

    // Assert
    try testing.expectEqualStrings("    /// The name.\n", writer.buffered());
}

test "writeFieldDocComment: multiline takes first line only" {
    // Arrange
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);

    // Act
    try writeFieldDocComment(&writer, "Line one.\nLine two.");

    // Assert
    try testing.expectEqualStrings("    /// Line one.\n", writer.buffered());
}

// ---- writeType tests ----

test "writeType: string" {
    // Arrange
    const parsed = try parseJson(testing.allocator,
        \\{"type":"string"}
    );
    defer parsed.deinit();
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);

    // Act
    try writeType(&writer, parsed.value, std.json.ObjectMap.init(testing.allocator), "core_v1");

    // Assert
    try testing.expectEqualStrings("[]const u8", writer.buffered());
}

test "writeType: boolean" {
    // Arrange
    const parsed = try parseJson(testing.allocator,
        \\{"type":"boolean"}
    );
    defer parsed.deinit();
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);

    // Act
    try writeType(&writer, parsed.value, std.json.ObjectMap.init(testing.allocator), "core_v1");

    // Assert
    try testing.expectEqualStrings("bool", writer.buffered());
}

test "writeType: number" {
    // Arrange
    const parsed = try parseJson(testing.allocator,
        \\{"type":"number"}
    );
    defer parsed.deinit();
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);

    // Act
    try writeType(&writer, parsed.value, std.json.ObjectMap.init(testing.allocator), "core_v1");

    // Assert
    try testing.expectEqualStrings("f64", writer.buffered());
}

test "writeType: integer defaults to i64" {
    // Arrange
    const parsed = try parseJson(testing.allocator,
        \\{"type":"integer"}
    );
    defer parsed.deinit();
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);

    // Act
    try writeType(&writer, parsed.value, std.json.ObjectMap.init(testing.allocator), "core_v1");

    // Assert
    try testing.expectEqualStrings("i64", writer.buffered());
}

test "writeType: integer int32" {
    // Arrange
    const parsed = try parseJson(testing.allocator,
        \\{"type":"integer","format":"int32"}
    );
    defer parsed.deinit();
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);

    // Act
    try writeType(&writer, parsed.value, std.json.ObjectMap.init(testing.allocator), "core_v1");

    // Assert
    try testing.expectEqualStrings("i32", writer.buffered());
}

test "writeType: array of strings" {
    // Arrange
    const parsed = try parseJson(testing.allocator,
        \\{"type":"array","items":{"type":"string"}}
    );
    defer parsed.deinit();
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);

    // Act
    try writeType(&writer, parsed.value, std.json.ObjectMap.init(testing.allocator), "core_v1");

    // Assert
    try testing.expectEqualStrings("[]const []const u8", writer.buffered());
}

test "writeType: array without items" {
    // Arrange
    const parsed = try parseJson(testing.allocator,
        \\{"type":"array"}
    );
    defer parsed.deinit();
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);

    // Act
    try writeType(&writer, parsed.value, std.json.ObjectMap.init(testing.allocator), "core_v1");

    // Assert
    try testing.expectEqualStrings("[]const json.Value", writer.buffered());
}

test "writeType: object with additionalProperties string" {
    // Arrange
    const parsed = try parseJson(testing.allocator,
        \\{"type":"object","additionalProperties":{"type":"string"}}
    );
    defer parsed.deinit();
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);

    // Act
    try writeType(&writer, parsed.value, std.json.ObjectMap.init(testing.allocator), "core_v1");

    // Assert
    try testing.expectEqualStrings("json.ArrayHashMap([]const u8)", writer.buffered());
}

test "writeType: bare object" {
    // Arrange
    const parsed = try parseJson(testing.allocator,
        \\{"type":"object"}
    );
    defer parsed.deinit();
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);

    // Act
    try writeType(&writer, parsed.value, std.json.ObjectMap.init(testing.allocator), "core_v1");

    // Assert
    try testing.expectEqualStrings("json.Value", writer.buffered());
}

test "writeType: empty schema" {
    // Arrange
    const parsed = try parseJson(testing.allocator, "{}");
    defer parsed.deinit();
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);

    // Act
    try writeType(&writer, parsed.value, std.json.ObjectMap.init(testing.allocator), "core_v1");

    // Assert
    try testing.expectEqualStrings("json.Value", writer.buffered());
}

test "writeType: ref to existing definition in same group" {
    // Arrange
    const parsed = try parseJson(testing.allocator,
        \\{"$ref":"#/definitions/io.k8s.api.core.v1.PodSpec"}
    );
    defer parsed.deinit();
    const def_schema = try parseJson(testing.allocator,
        \\{"type":"object"}
    );
    defer def_schema.deinit();
    var definitions = std.json.ObjectMap.init(testing.allocator);
    defer definitions.deinit();
    try definitions.put("io.k8s.api.core.v1.PodSpec", def_schema.value);
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);

    // Act
    try writeType(&writer, parsed.value, definitions, "core_v1");

    // Assert
    try testing.expectEqualStrings("CoreV1PodSpec", writer.buffered());
}

test "writeType: ref to missing definition falls back to json.Value" {
    // Arrange
    const parsed = try parseJson(testing.allocator,
        \\{"$ref":"#/definitions/io.unknown.Foo"}
    );
    defer parsed.deinit();
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);

    // Act
    try writeType(&writer, parsed.value, std.json.ObjectMap.init(testing.allocator), "core_v1");

    // Assert
    try testing.expectEqualStrings("json.Value", writer.buffered());
}

test "writeType: ref to existing definition in different group qualifies with module" {
    // Arrange
    const parsed = try parseJson(testing.allocator,
        \\{"$ref":"#/definitions/io.k8s.apimachinery.pkg.apis.meta.v1.ObjectMeta"}
    );
    defer parsed.deinit();
    const def_schema = try parseJson(testing.allocator,
        \\{"type":"object"}
    );
    defer def_schema.deinit();
    var definitions = std.json.ObjectMap.init(testing.allocator);
    defer definitions.deinit();
    try definitions.put("io.k8s.apimachinery.pkg.apis.meta.v1.ObjectMeta", def_schema.value);
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);

    // Act
    try writeType(&writer, parsed.value, definitions, "core_v1");

    // Assert
    try testing.expectEqualStrings("meta_v1.MetaV1ObjectMeta", writer.buffered());
}

test "writeType: integer with non-int32 format defaults to i64" {
    // Arrange
    const parsed = try parseJson(testing.allocator,
        \\{"type":"integer","format":"int64"}
    );
    defer parsed.deinit();
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);

    // Act
    try writeType(&writer, parsed.value, std.json.ObjectMap.init(testing.allocator), "core_v1");

    // Assert
    try testing.expectEqualStrings("i64", writer.buffered());
}

test "writeType: object with additionalProperties containing ref" {
    // Arrange
    const parsed = try parseJson(testing.allocator,
        \\{"type":"object","additionalProperties":{"$ref":"#/definitions/io.k8s.api.core.v1.Container"}}
    );
    defer parsed.deinit();
    const def_schema = try parseJson(testing.allocator,
        \\{"type":"object"}
    );
    defer def_schema.deinit();
    var definitions = std.json.ObjectMap.init(testing.allocator);
    defer definitions.deinit();
    try definitions.put("io.k8s.api.core.v1.Container", def_schema.value);
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);

    // Act
    try writeType(&writer, parsed.value, definitions, "core_v1");

    // Assert
    try testing.expectEqualStrings("json.ArrayHashMap(CoreV1Container)", writer.buffered());
}

test "writeType: array of refs" {
    // Arrange
    const parsed = try parseJson(testing.allocator,
        \\{"type":"array","items":{"$ref":"#/definitions/io.k8s.api.core.v1.Container"}}
    );
    defer parsed.deinit();
    const def_schema = try parseJson(testing.allocator,
        \\{"type":"object"}
    );
    defer def_schema.deinit();
    var definitions = std.json.ObjectMap.init(testing.allocator);
    defer definitions.deinit();
    try definitions.put("io.k8s.api.core.v1.Container", def_schema.value);
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);

    // Act
    try writeType(&writer, parsed.value, definitions, "core_v1");

    // Assert
    try testing.expectEqualStrings("[]const CoreV1Container", writer.buffered());
}
