const std = @import("std");
const openapi = @import("openapi.zig");
const json_helpers = @import("json_helpers.zig");
const emit_helpers = @import("emit_helpers.zig");
const testing = std.testing;

const Writer = std.Io.Writer;

const asObject = json_helpers.asObject;
const asString = json_helpers.asString;
const asArray = json_helpers.asArray;
const asBool = json_helpers.asBool;
const writeFieldName = emit_helpers.writeFieldName;
const writeDocComment = emit_helpers.writeDocComment;
const writeFieldDocComment = emit_helpers.writeFieldDocComment;

/// Metadata extracted from a CRD for a single version of a custom resource.
pub const CrdMeta = struct {
    group: []const u8,
    version: []const u8,
    kind: []const u8,
    plural: []const u8,
    namespaced: bool,
    schema: ?std.json.Value,
};

/// Extract CRD metadata for each served version from a parsed CRD JSON object.
pub fn extractCrdMeta(crd: std.json.Value) ?[]const CrdMeta {
    const root = asObject(crd) orelse return null;
    const spec = asObject(root.get("spec") orelse return null) orelse return null;

    const group = asString(spec.get("group") orelse return null) orelse return null;
    const scope_val = asString(spec.get("scope") orelse return null) orelse return null;
    const namespaced = std.mem.eql(u8, scope_val, "Namespaced");

    const names_obj = asObject(spec.get("names") orelse return null) orelse return null;
    const kind = asString(names_obj.get("kind") orelse return null) orelse return null;
    const plural = asString(names_obj.get("plural") orelse return null) orelse return null;

    const versions_arr = asArray(spec.get("versions") orelse return null) orelse return null;

    // Count served versions.
    var count: usize = 0;
    for (versions_arr.items) |v| {
        const ver_obj = asObject(v) orelse continue;
        const served = asBool(ver_obj.get("served") orelse continue) orelse continue;
        if (served) count += 1;
    }
    if (count == 0) return null;

    // We can't allocate here without an allocator, so we return a slice from the array items.
    // Instead, use a static buffer approach. CRDs rarely have more than a few versions.
    const Static = struct {
        var buf: [16]CrdMeta = undefined;
    };

    var i: usize = 0;
    for (versions_arr.items) |v| {
        const ver_obj = asObject(v) orelse continue;
        const served = asBool(ver_obj.get("served") orelse continue) orelse continue;
        if (!served) continue;
        if (i >= 16) break;

        const version = asString(ver_obj.get("name") orelse continue) orelse continue;

        // Extract schema: .schema.openAPIV3Schema
        const schema: ?std.json.Value = blk: {
            const schema_obj = asObject(ver_obj.get("schema") orelse break :blk null) orelse break :blk null;
            break :blk schema_obj.get("openAPIV3Schema");
        };

        Static.buf[i] = .{
            .group = group,
            .version = version,
            .kind = kind,
            .plural = plural,
            .namespaced = namespaced,
            .schema = schema,
        };
        i += 1;
    }

    return Static.buf[0..i];
}

/// Context passed through recursive struct generation to collect nested structs.
const GenContext = struct {
    allocator: std.mem.Allocator,
    nested: std.ArrayList(NestedStruct),
    seen_names: std.StringArrayHashMap(void),

    const NestedStruct = struct {
        name: []const u8,
        schema: std.json.Value,
        description: ?[]const u8,
    };

    fn init(allocator: std.mem.Allocator) GenContext {
        return .{
            .allocator = allocator,
            .nested = .{},
            .seen_names = std.StringArrayHashMap(void).init(allocator),
        };
    }

    fn deinit(self: *GenContext) void {
        // The nested items' names and seen_names keys share the same allocations,
        // so only free via seen_names to avoid double-free.
        self.nested.deinit(self.allocator);
        for (self.seen_names.keys()) |key| {
            self.allocator.free(key);
        }
        self.seen_names.deinit();
    }

    fn addNested(self: *GenContext, name: []const u8, schema: std.json.Value, description: ?[]const u8) !void {
        const duped = try self.allocator.dupe(u8, name);
        const gop = try self.seen_names.getOrPut(duped);
        if (gop.found_existing) {
            self.allocator.free(duped);
            return; // Already queued
        }
        try self.nested.append(self.allocator, .{
            .name = duped,
            .schema = schema,
            .description = description,
        });
    }
};

/// Generate all types for a single CRD JSON into the writer.
/// If multi_version is true, version suffixes are added to type names.
pub fn generateCrd(
    allocator: std.mem.Allocator,
    writer: *Writer,
    crd: std.json.Value,
    types_import: []const u8,
) !void {
    const metas = extractCrdMeta(crd) orelse return error.InvalidCrd;
    const multi_version = metas.len > 1;

    // Write CRD source comment.
    const root = asObject(crd) orelse return error.InvalidCrd;
    const metadata_obj = asObject(root.get("metadata") orelse return error.InvalidCrd) orelse return error.InvalidCrd;
    const crd_name = asString(metadata_obj.get("name") orelse return error.InvalidCrd) orelse return error.InvalidCrd;
    try writer.print("// Auto-generated from CRD: {s}\n", .{crd_name});
    try writer.writeAll("// Do not edit manually. Regenerate with: zig build generate-crd\n\n");
    try writer.writeAll("const std = @import(\"std\");\n");
    try writer.writeAll("const json = std.json;\n");
    try writer.print("const types = @import(\"{s}\");\n\n", .{types_import});

    for (metas) |meta| {
        try generateVersion(allocator, writer, meta, multi_version);
    }
}

/// Build the type name for a CRD version.
/// If multi_version, appends a capitalized version suffix (e.g., "CronTabV1").
fn buildTypeName(buf: []u8, kind: []const u8, version: []const u8, multi_version: bool) []const u8 {
    var w = Writer.fixed(buf);
    openapi.writeCapitalized(&w, kind) catch return "";
    if (multi_version) {
        openapi.writeCapitalized(&w, version) catch return "";
    }
    return w.buffered();
}

/// Generate types for a single version of a CRD.
fn generateVersion(
    allocator: std.mem.Allocator,
    writer: *Writer,
    meta: CrdMeta,
    multi_version: bool,
) !void {
    var name_buf: [512]u8 = undefined;
    const type_name = buildTypeName(&name_buf, meta.kind, meta.version, multi_version);
    var list_name_buf: [512]u8 = undefined;
    const list_type_name = blk: {
        var w = Writer.fixed(&list_name_buf);
        try w.writeAll(type_name);
        try w.writeAll("List");
        break :blk w.buffered();
    };

    // Write list type.
    try writer.print("/// List of {s} resources.\n", .{type_name});
    try writer.print("pub const {s} = struct {{\n", .{list_type_name});
    try writer.writeAll("    apiVersion: ?[]const u8 = null,\n");
    try writer.writeAll("    kind: ?[]const u8 = null,\n");
    try writer.writeAll("    metadata: ?types.MetaV1ListMeta = null,\n");
    try writer.print("    items: []const {s} = &.{{}},\n", .{type_name});
    try writer.writeAll("};\n\n");

    // Write root resource type.
    try writer.print("/// {s} custom resource ({s}/{s}).\n", .{ type_name, meta.group, meta.version });
    try writer.print("pub const {s} = struct {{\n", .{type_name});

    // Write resource_meta.
    try writer.writeAll("    pub const resource_meta = .{\n");
    try writer.print("        .group = \"{s}\",\n", .{meta.group});
    try writer.print("        .version = \"{s}\",\n", .{meta.version});
    try writer.print("        .kind = \"{s}\",\n", .{meta.kind});
    try writer.print("        .resource = \"{s}\",\n", .{meta.plural});
    if (meta.namespaced) {
        try writer.writeAll("        .namespaced = true,\n");
    } else {
        try writer.writeAll("        .namespaced = false,\n");
    }
    try writer.print("        .list_kind = {s},\n", .{list_type_name});
    try writer.writeAll("    };\n\n");

    // Always emit apiVersion, kind, metadata.
    try writer.writeAll("    apiVersion: ?[]const u8 = null,\n");
    try writer.writeAll("    kind: ?[]const u8 = null,\n");
    try writer.writeAll("    metadata: ?types.MetaV1ObjectMeta = null,\n");

    // Collect nested structs as we write the root fields.
    var ctx = GenContext.init(allocator);
    defer ctx.deinit();

    // Write fields from schema properties (excluding apiVersion, kind, metadata).
    if (meta.schema) |schema_val| {
        const schema_obj = asObject(schema_val) orelse null;
        if (schema_obj) |so| {
            if (so.get("properties")) |props_val| {
                const props = asObject(props_val) orelse null;
                if (props) |p| {
                    try writeRootFieldsFromProperties(writer, p, type_name, &ctx);
                }
            }
        }
    } else {
        // No schema: add catch-all spec field.
        try writer.writeAll("    spec: ?json.Value = null,\n");
    }

    try writer.writeAll("};\n\n");

    // Write all collected nested structs (breadth-first).
    var processed: usize = 0;
    while (processed < ctx.nested.items.len) {
        const nested = ctx.nested.items[processed];
        processed += 1;

        if (nested.description) |desc| {
            try writeDocComment(writer, desc);
        }
        try writer.print("pub const {s} = struct {{\n", .{nested.name});

        const nested_obj = asObject(nested.schema) orelse {
            try writer.writeAll("};\n\n");
            continue;
        };

        // Handle allOf: merge properties from all sub-schemas.
        if (nested_obj.get("allOf")) |all_of_val| {
            if (asArray(all_of_val)) |all_of_arr| {
                for (all_of_arr.items) |sub_schema| {
                    const sub_obj = asObject(sub_schema) orelse continue;
                    if (sub_obj.get("properties")) |props_val| {
                        if (asObject(props_val)) |props| {
                            try writeFieldsFromProperties(writer, props, nested.name, &ctx);
                        }
                    }
                }
            }
        } else if (nested_obj.get("properties")) |props_val| {
            if (asObject(props_val)) |props| {
                try writeFieldsFromProperties(writer, props, nested.name, &ctx);
            }
        }

        try writer.writeAll("};\n\n");
    }
}

/// Write struct fields from an OpenAPI properties map.
/// When skip_standard_fields is true, skips apiVersion, kind, metadata
/// (these are handled separately on the root type).
fn writeFieldsFromProperties(
    writer: *Writer,
    props: std.json.ObjectMap,
    parent_name: []const u8,
    ctx: *GenContext,
) !void {
    writeFieldsFromPropertiesInner(writer, props, parent_name, ctx, false) catch |err| return err;
}

fn writeRootFieldsFromProperties(
    writer: *Writer,
    props: std.json.ObjectMap,
    parent_name: []const u8,
    ctx: *GenContext,
) !void {
    writeFieldsFromPropertiesInner(writer, props, parent_name, ctx, true) catch |err| return err;
}

fn writeFieldsFromPropertiesInner(
    writer: *Writer,
    props: std.json.ObjectMap,
    parent_name: []const u8,
    ctx: *GenContext,
    skip_standard_fields: bool,
) !void {
    // Sort properties for deterministic output.
    const keys = props.keys();
    const sorted_indices = try ctx.allocator.alloc(usize, keys.len);
    defer ctx.allocator.free(sorted_indices);
    for (sorted_indices, 0..) |*idx, i| {
        idx.* = i;
    }
    std.sort.pdq(usize, sorted_indices, keys, struct {
        fn lessThan(ks: []const []const u8, a: usize, b: usize) bool {
            return std.mem.order(u8, ks[a], ks[b]) == .lt;
        }
    }.lessThan);

    const values = props.values();
    for (sorted_indices) |idx| {
        const field_name = keys[idx];
        const prop_schema = values[idx];

        // Skip standard K8s fields on the root type (they are emitted separately).
        if (skip_standard_fields and
            (std.mem.eql(u8, field_name, "apiVersion") or
                std.mem.eql(u8, field_name, "kind") or
                std.mem.eql(u8, field_name, "metadata")))
        {
            continue;
        }
        {
            // Write field doc comment.
            if (asObject(prop_schema)) |prop_obj| {
                if (prop_obj.get("description")) |desc| {
                    if (asString(desc)) |s| try writeFieldDocComment(writer, s);
                }
            }

            try writer.writeAll("    ");
            try writeFieldName(writer, field_name);
            try writer.writeAll(": ?");
            try writeSchemaType(writer, prop_schema, parent_name, field_name, ctx);
            try writer.writeAll(" = null,\n");
        }
    }
}

/// Write a Zig type expression for an OpenAPI v3 schema.
/// For nested objects, creates a named sub-struct and registers it in the context.
pub fn writeSchemaType(
    writer: *Writer,
    schema: std.json.Value,
    parent_name: []const u8,
    field_name: []const u8,
    ctx: *GenContext,
) !void {
    const obj = asObject(schema) orelse {
        try writer.writeAll("json.Value");
        return;
    };

    // x-kubernetes-preserve-unknown-fields: emit json.Value
    if (obj.get("x-kubernetes-preserve-unknown-fields")) |v| {
        if (asBool(v)) |b| {
            if (b) {
                try writer.writeAll("json.Value");
                return;
            }
        }
    }

    // x-kubernetes-int-or-string: emit IntOrString
    if (obj.get("x-kubernetes-int-or-string")) |v| {
        if (asBool(v)) |b| {
            if (b) {
                try writeIntOrStringType(writer);
                return;
            }
        }
    }

    // oneOf / anyOf: fall back to json.Value
    if (obj.get("oneOf") != null or obj.get("anyOf") != null) {
        try writer.writeAll("json.Value");
        return;
    }

    // allOf: merge all schemas' properties into a single struct
    if (obj.get("allOf")) |all_of_val| {
        if (asArray(all_of_val)) |_| {
            // Build a merged struct name
            var nested_name_buf: [1024]u8 = undefined;
            var nw = Writer.fixed(&nested_name_buf);
            try nw.writeAll(parent_name);
            try openapi.writeCapitalized(&nw, field_name);
            const nested_name = nw.buffered();

            // Register the allOf schema as a nested struct.
            // When emitting the nested struct, we merge all allOf sub-schemas' properties.
            try ctx.addNested(nested_name, schema, null);
            try writer.writeAll(nested_name);
            return;
        }
    }

    // $ref: emit json.Value (CRD schemas shouldn't have $ref, but handle gracefully)
    if (obj.get("$ref") != null) {
        try writer.writeAll("json.Value");
        return;
    }

    // Determine the type.
    const type_str: ?[]const u8 = if (obj.get("type")) |t| asString(t) else null;

    // If items is present but no type, treat as array.
    const effective_type: ?[]const u8 = if (type_str) |t| t else if (obj.get("items") != null) "array" else null;

    const et = effective_type orelse {
        try writer.writeAll("json.Value");
        return;
    };

    if (std.mem.eql(u8, et, "string")) {
        // Check format for special handling.
        if (obj.get("format")) |fmt| {
            if (asString(fmt)) |fmt_str| {
                if (std.mem.eql(u8, fmt_str, "int-or-string")) {
                    try writeIntOrStringType(writer);
                    return;
                }
            }
        }
        try writer.writeAll("[]const u8");
        return;
    }

    if (std.mem.eql(u8, et, "boolean")) {
        try writer.writeAll("bool");
        return;
    }

    if (std.mem.eql(u8, et, "integer")) {
        if (obj.get("format")) |fmt| {
            if (asString(fmt)) |fmt_str| {
                if (std.mem.eql(u8, fmt_str, "int32")) {
                    try writer.writeAll("i32");
                    return;
                }
                if (std.mem.eql(u8, fmt_str, "int64")) {
                    try writer.writeAll("i64");
                    return;
                }
            }
        }
        try writer.writeAll("i64");
        return;
    }

    if (std.mem.eql(u8, et, "number")) {
        if (obj.get("format")) |fmt| {
            if (asString(fmt)) |fmt_str| {
                if (std.mem.eql(u8, fmt_str, "float")) {
                    try writer.writeAll("f32");
                    return;
                }
            }
        }
        try writer.writeAll("f64");
        return;
    }

    if (std.mem.eql(u8, et, "array")) {
        try writer.writeAll("[]const ");
        if (obj.get("items")) |items| {
            try writeSchemaType(writer, items, parent_name, field_name, ctx);
        } else {
            try writer.writeAll("json.Value");
        }
        return;
    }

    if (std.mem.eql(u8, et, "object")) {
        // Object with additionalProperties: emit map type.
        if (obj.get("additionalProperties")) |additional| {
            try writer.writeAll("json.ArrayHashMap(");
            try writeSchemaType(writer, additional, parent_name, field_name, ctx);
            try writer.writeAll(")");
            return;
        }

        // Object with properties: emit named nested struct.
        if (obj.get("properties") != null) {
            var nested_name_buf: [1024]u8 = undefined;
            var nw = Writer.fixed(&nested_name_buf);
            try nw.writeAll(parent_name);
            try openapi.writeCapitalized(&nw, field_name);
            const nested_name = nw.buffered();

            // Get description.
            const desc: ?[]const u8 = if (obj.get("description")) |d| asString(d) else null;
            try ctx.addNested(nested_name, schema, desc);
            try writer.writeAll(nested_name);
            return;
        }

        // Object with neither: opaque json.Value.
        try writer.writeAll("json.Value");
        return;
    }

    // Unknown type.
    try writer.writeAll("json.Value");
}

/// Write the IntOrString type inline reference.
fn writeIntOrStringType(writer: *Writer) !void {
    // Emit a struct with custom JSON parsing, same pattern as the existing generator.
    // We use a dedicated top-level type name to avoid duplication.
    // For CRDs, we inline the union definition.
    try writer.writeAll("IntOrString");
}

/// Write the IntOrString union type definition (top-level, once per file).
pub fn writeIntOrStringUnion(writer: *Writer) !void {
    try writer.writeAll(
        \\pub const IntOrString = union(enum) {
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

/// Check if any schema in the CRD uses IntOrString.
pub fn crdUsesIntOrString(crd: std.json.Value) bool {
    return schemaUsesIntOrString(crd);
}

fn schemaUsesIntOrString(val: std.json.Value) bool {
    const obj = asObject(val) orelse return false;

    if (obj.get("x-kubernetes-int-or-string")) |v| {
        if (asBool(v)) |b| {
            if (b) return true;
        }
    }

    if (obj.get("format")) |fmt| {
        if (asString(fmt)) |fmt_str| {
            if (std.mem.eql(u8, fmt_str, "int-or-string")) return true;
        }
    }

    if (obj.get("properties")) |props_val| {
        if (asObject(props_val)) |props| {
            for (props.values()) |prop_schema| {
                if (schemaUsesIntOrString(prop_schema)) return true;
            }
        }
    }

    if (obj.get("items")) |items| {
        if (schemaUsesIntOrString(items)) return true;
    }

    if (obj.get("additionalProperties")) |additional| {
        if (schemaUsesIntOrString(additional)) return true;
    }

    if (obj.get("allOf")) |all_of_val| {
        if (asArray(all_of_val)) |arr| {
            for (arr.items) |item| {
                if (schemaUsesIntOrString(item)) return true;
            }
        }
    }

    // Recurse into all object values to handle arbitrary nesting (e.g., CRD spec.versions[].schema).
    for (obj.values()) |child| {
        switch (child) {
            .object => {
                if (schemaUsesIntOrString(child)) return true;
            },
            .array => |arr| {
                for (arr.items) |item| {
                    if (schemaUsesIntOrString(item)) return true;
                }
            },
            else => {},
        }
    }

    return false;
}

// ---- extractCrdMeta tests ----

test "extractCrdMeta: extracts metadata from valid CRD" {
    // Arrange
    const crd_json =
        \\{
        \\  "apiVersion": "apiextensions.k8s.io/v1",
        \\  "kind": "CustomResourceDefinition",
        \\  "metadata": { "name": "crontabs.stable.example.com" },
        \\  "spec": {
        \\    "group": "stable.example.com",
        \\    "scope": "Namespaced",
        \\    "names": { "kind": "CronTab", "plural": "crontabs" },
        \\    "versions": [{
        \\      "name": "v1",
        \\      "served": true,
        \\      "storage": true,
        \\      "schema": {
        \\        "openAPIV3Schema": {
        \\          "type": "object",
        \\          "properties": {
        \\            "spec": { "type": "object" }
        \\          }
        \\        }
        \\      }
        \\    }]
        \\  }
        \\}
    ;
    const parsed = try json_helpers.parseJson(testing.allocator, crd_json);
    defer parsed.deinit();

    // Act / Assert
    const metas = extractCrdMeta(parsed.value).?;
    try testing.expectEqual(@as(usize, 1), metas.len);
    try testing.expectEqualStrings("stable.example.com", metas[0].group);
    try testing.expectEqualStrings("v1", metas[0].version);
    try testing.expectEqualStrings("CronTab", metas[0].kind);
    try testing.expectEqualStrings("crontabs", metas[0].plural);
    try testing.expect(metas[0].namespaced);
    try testing.expect(metas[0].schema != null);
}

test "extractCrdMeta: cluster-scoped CRD sets namespaced to false" {
    // Arrange
    const crd_json =
        \\{
        \\  "spec": {
        \\    "group": "example.com",
        \\    "scope": "Cluster",
        \\    "names": { "kind": "MyCluster", "plural": "myclusters" },
        \\    "versions": [{ "name": "v1", "served": true, "storage": true, "schema": { "openAPIV3Schema": { "type": "object" } } }]
        \\  }
        \\}
    ;
    const parsed = try json_helpers.parseJson(testing.allocator, crd_json);
    defer parsed.deinit();

    // Act / Assert
    const metas = extractCrdMeta(parsed.value).?;
    try testing.expect(!metas[0].namespaced);
}

test "extractCrdMeta: multiple served versions" {
    // Arrange
    const crd_json =
        \\{
        \\  "spec": {
        \\    "group": "example.com",
        \\    "scope": "Namespaced",
        \\    "names": { "kind": "Foo", "plural": "foos" },
        \\    "versions": [
        \\      { "name": "v1", "served": true, "storage": true, "schema": { "openAPIV3Schema": { "type": "object" } } },
        \\      { "name": "v1beta1", "served": true, "storage": false, "schema": { "openAPIV3Schema": { "type": "object" } } },
        \\      { "name": "v1alpha1", "served": false, "storage": false, "schema": { "openAPIV3Schema": { "type": "object" } } }
        \\    ]
        \\  }
        \\}
    ;
    const parsed = try json_helpers.parseJson(testing.allocator, crd_json);
    defer parsed.deinit();

    // Act / Assert
    const metas = extractCrdMeta(parsed.value).?;
    try testing.expectEqual(@as(usize, 2), metas.len);
    try testing.expectEqualStrings("v1", metas[0].version);
    try testing.expectEqualStrings("v1beta1", metas[1].version);
}

test "extractCrdMeta: returns null for invalid JSON" {
    // Act / Assert
    const parsed = try json_helpers.parseJson(testing.allocator, "{}");
    defer parsed.deinit();
    try testing.expect(extractCrdMeta(parsed.value) == null);
}

// ---- writeSchemaType tests ----

test "writeSchemaType: string type" {
    // Arrange
    const parsed = try json_helpers.parseJson(testing.allocator,
        \\{"type":"string"}
    );
    defer parsed.deinit();
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);
    var ctx = GenContext.init(testing.allocator);
    defer ctx.deinit();

    // Act / Assert
    try writeSchemaType(&writer, parsed.value, "Test", "field", &ctx);
    try testing.expectEqualStrings("[]const u8", writer.buffered());
}

test "writeSchemaType: boolean type" {
    // Arrange
    const parsed = try json_helpers.parseJson(testing.allocator,
        \\{"type":"boolean"}
    );
    defer parsed.deinit();
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);
    var ctx = GenContext.init(testing.allocator);
    defer ctx.deinit();

    // Act / Assert
    try writeSchemaType(&writer, parsed.value, "Test", "field", &ctx);
    try testing.expectEqualStrings("bool", writer.buffered());
}

test "writeSchemaType: integer defaults to i64" {
    // Arrange
    const parsed = try json_helpers.parseJson(testing.allocator,
        \\{"type":"integer"}
    );
    defer parsed.deinit();
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);
    var ctx = GenContext.init(testing.allocator);
    defer ctx.deinit();

    // Act / Assert
    try writeSchemaType(&writer, parsed.value, "Test", "field", &ctx);
    try testing.expectEqualStrings("i64", writer.buffered());
}

test "writeSchemaType: integer int32 format" {
    // Arrange
    const parsed = try json_helpers.parseJson(testing.allocator,
        \\{"type":"integer","format":"int32"}
    );
    defer parsed.deinit();
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);
    var ctx = GenContext.init(testing.allocator);
    defer ctx.deinit();

    // Act / Assert
    try writeSchemaType(&writer, parsed.value, "Test", "field", &ctx);
    try testing.expectEqualStrings("i32", writer.buffered());
}

test "writeSchemaType: integer int64 format" {
    // Arrange
    const parsed = try json_helpers.parseJson(testing.allocator,
        \\{"type":"integer","format":"int64"}
    );
    defer parsed.deinit();
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);
    var ctx = GenContext.init(testing.allocator);
    defer ctx.deinit();

    // Act / Assert
    try writeSchemaType(&writer, parsed.value, "Test", "field", &ctx);
    try testing.expectEqualStrings("i64", writer.buffered());
}

test "writeSchemaType: number defaults to f64" {
    // Arrange
    const parsed = try json_helpers.parseJson(testing.allocator,
        \\{"type":"number"}
    );
    defer parsed.deinit();
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);
    var ctx = GenContext.init(testing.allocator);
    defer ctx.deinit();

    // Act / Assert
    try writeSchemaType(&writer, parsed.value, "Test", "field", &ctx);
    try testing.expectEqualStrings("f64", writer.buffered());
}

test "writeSchemaType: number float format" {
    // Arrange
    const parsed = try json_helpers.parseJson(testing.allocator,
        \\{"type":"number","format":"float"}
    );
    defer parsed.deinit();
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);
    var ctx = GenContext.init(testing.allocator);
    defer ctx.deinit();

    // Act / Assert
    try writeSchemaType(&writer, parsed.value, "Test", "field", &ctx);
    try testing.expectEqualStrings("f32", writer.buffered());
}

test "writeSchemaType: array of strings" {
    // Arrange
    const parsed = try json_helpers.parseJson(testing.allocator,
        \\{"type":"array","items":{"type":"string"}}
    );
    defer parsed.deinit();
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);
    var ctx = GenContext.init(testing.allocator);
    defer ctx.deinit();

    // Act / Assert
    try writeSchemaType(&writer, parsed.value, "Test", "field", &ctx);
    try testing.expectEqualStrings("[]const []const u8", writer.buffered());
}

test "writeSchemaType: array without items" {
    // Arrange
    const parsed = try json_helpers.parseJson(testing.allocator,
        \\{"type":"array"}
    );
    defer parsed.deinit();
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);
    var ctx = GenContext.init(testing.allocator);
    defer ctx.deinit();

    // Act / Assert
    try writeSchemaType(&writer, parsed.value, "Test", "field", &ctx);
    try testing.expectEqualStrings("[]const json.Value", writer.buffered());
}

test "writeSchemaType: object with additionalProperties string" {
    // Arrange
    const parsed = try json_helpers.parseJson(testing.allocator,
        \\{"type":"object","additionalProperties":{"type":"string"}}
    );
    defer parsed.deinit();
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);
    var ctx = GenContext.init(testing.allocator);
    defer ctx.deinit();

    // Act / Assert
    try writeSchemaType(&writer, parsed.value, "Test", "field", &ctx);
    try testing.expectEqualStrings("json.ArrayHashMap([]const u8)", writer.buffered());
}

test "writeSchemaType: object with properties creates nested struct" {
    // Arrange
    const parsed = try json_helpers.parseJson(testing.allocator,
        \\{"type":"object","properties":{"name":{"type":"string"}}}
    );
    defer parsed.deinit();
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);
    var ctx = GenContext.init(testing.allocator);
    defer ctx.deinit();

    // Act / Assert
    try writeSchemaType(&writer, parsed.value, "CronTab", "spec", &ctx);
    try testing.expectEqualStrings("CronTabSpec", writer.buffered());
    try testing.expectEqual(@as(usize, 1), ctx.nested.items.len);
    try testing.expectEqualStrings("CronTabSpec", ctx.nested.items[0].name);
}

test "writeSchemaType: bare object without properties" {
    // Arrange
    const parsed = try json_helpers.parseJson(testing.allocator,
        \\{"type":"object"}
    );
    defer parsed.deinit();
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);
    var ctx = GenContext.init(testing.allocator);
    defer ctx.deinit();

    // Act / Assert
    try writeSchemaType(&writer, parsed.value, "Test", "field", &ctx);
    try testing.expectEqualStrings("json.Value", writer.buffered());
}

test "writeSchemaType: x-kubernetes-preserve-unknown-fields" {
    // Arrange
    const parsed = try json_helpers.parseJson(testing.allocator,
        \\{"type":"object","x-kubernetes-preserve-unknown-fields":true}
    );
    defer parsed.deinit();
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);
    var ctx = GenContext.init(testing.allocator);
    defer ctx.deinit();

    // Act / Assert
    try writeSchemaType(&writer, parsed.value, "Test", "field", &ctx);
    try testing.expectEqualStrings("json.Value", writer.buffered());
}

test "writeSchemaType: x-kubernetes-int-or-string" {
    // Arrange
    const parsed = try json_helpers.parseJson(testing.allocator,
        \\{"x-kubernetes-int-or-string":true}
    );
    defer parsed.deinit();
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);
    var ctx = GenContext.init(testing.allocator);
    defer ctx.deinit();

    // Act / Assert
    try writeSchemaType(&writer, parsed.value, "Test", "field", &ctx);
    try testing.expectEqualStrings("IntOrString", writer.buffered());
}

test "writeSchemaType: empty schema falls back to json.Value" {
    // Arrange
    const parsed = try json_helpers.parseJson(testing.allocator, "{}");
    defer parsed.deinit();
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);
    var ctx = GenContext.init(testing.allocator);
    defer ctx.deinit();

    // Act / Assert
    try writeSchemaType(&writer, parsed.value, "Test", "field", &ctx);
    try testing.expectEqualStrings("json.Value", writer.buffered());
}

test "writeSchemaType: oneOf falls back to json.Value" {
    // Arrange
    const parsed = try json_helpers.parseJson(testing.allocator,
        \\{"oneOf":[{"type":"string"},{"type":"integer"}]}
    );
    defer parsed.deinit();
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);
    var ctx = GenContext.init(testing.allocator);
    defer ctx.deinit();

    // Act / Assert
    try writeSchemaType(&writer, parsed.value, "Test", "field", &ctx);
    try testing.expectEqualStrings("json.Value", writer.buffered());
}

test "writeSchemaType: anyOf falls back to json.Value" {
    // Arrange
    const parsed = try json_helpers.parseJson(testing.allocator,
        \\{"anyOf":[{"type":"string"},{"type":"integer"}]}
    );
    defer parsed.deinit();
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);
    var ctx = GenContext.init(testing.allocator);
    defer ctx.deinit();

    // Act / Assert
    try writeSchemaType(&writer, parsed.value, "Test", "field", &ctx);
    try testing.expectEqualStrings("json.Value", writer.buffered());
}

test "writeSchemaType: $ref falls back to json.Value" {
    // Arrange
    const parsed = try json_helpers.parseJson(testing.allocator,
        \\{"$ref":"#/definitions/something"}
    );
    defer parsed.deinit();
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);
    var ctx = GenContext.init(testing.allocator);
    defer ctx.deinit();

    // Act / Assert
    try writeSchemaType(&writer, parsed.value, "Test", "field", &ctx);
    try testing.expectEqualStrings("json.Value", writer.buffered());
}

test "writeSchemaType: items without type treated as array" {
    // Arrange
    const parsed = try json_helpers.parseJson(testing.allocator,
        \\{"items":{"type":"string"}}
    );
    defer parsed.deinit();
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);
    var ctx = GenContext.init(testing.allocator);
    defer ctx.deinit();

    // Act / Assert
    try writeSchemaType(&writer, parsed.value, "Test", "field", &ctx);
    try testing.expectEqualStrings("[]const []const u8", writer.buffered());
}

// ---- writeFieldName tests ----

test "writeFieldName: normal name" {
    // Act / Assert
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);
    try writeFieldName(&writer, "name");
    try testing.expectEqualStrings("name", writer.buffered());
}

test "writeFieldName: keyword needs quoting" {
    // Act / Assert
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);
    try writeFieldName(&writer, "continue");
    try testing.expectEqualStrings("@\"continue\"", writer.buffered());
}

test "writeFieldName: dash in name needs quoting" {
    // Act / Assert
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);
    try writeFieldName(&writer, "x-field");
    try testing.expectEqualStrings("@\"x-field\"", writer.buffered());
}

// ---- writeDocComment tests ----

test "writeDocComment: single line" {
    // Act / Assert
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);
    try writeDocComment(&writer, "A resource.");
    try testing.expectEqualStrings("/// A resource.\n", writer.buffered());
}

test "writeDocComment: multiline takes first line only" {
    // Act / Assert
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);
    try writeDocComment(&writer, "First.\nSecond.");
    try testing.expectEqualStrings("/// First.\n", writer.buffered());
}

// ---- buildTypeName tests ----

test "buildTypeName: single version omits version suffix" {
    // Act / Assert
    var buf: [256]u8 = undefined;
    const name = buildTypeName(&buf, "CronTab", "v1", false);
    try testing.expectEqualStrings("CronTab", name);
}

test "buildTypeName: multi version includes version suffix" {
    // Act / Assert
    var buf: [256]u8 = undefined;
    const name = buildTypeName(&buf, "CronTab", "v1", true);
    try testing.expectEqualStrings("CronTabV1", name);
}

test "buildTypeName: multi version with beta" {
    // Act / Assert
    var buf: [256]u8 = undefined;
    const name = buildTypeName(&buf, "CronTab", "v1beta1", true);
    try testing.expectEqualStrings("CronTabV1beta1", name);
}

// ---- crdUsesIntOrString tests ----

test "crdUsesIntOrString: detects x-kubernetes-int-or-string" {
    // Act / Assert
    const parsed = try json_helpers.parseJson(testing.allocator,
        \\{"spec":{"versions":[{"schema":{"openAPIV3Schema":{"type":"object","properties":{"port":{"x-kubernetes-int-or-string":true}}}}}]}}
    );
    defer parsed.deinit();
    try testing.expect(crdUsesIntOrString(parsed.value));
}

test "crdUsesIntOrString: false when not used" {
    // Act / Assert
    const parsed = try json_helpers.parseJson(testing.allocator,
        \\{"spec":{"versions":[{"schema":{"openAPIV3Schema":{"type":"object","properties":{"name":{"type":"string"}}}}}]}}
    );
    defer parsed.deinit();
    try testing.expect(!crdUsesIntOrString(parsed.value));
}
