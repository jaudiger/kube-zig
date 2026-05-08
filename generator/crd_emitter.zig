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
    /// CamelCase prefix derived from group, e.g. "StableExampleCom".
    group_prefix: []u8,
    version: []const u8,
    kind: []const u8,
    plural: []const u8,
    namespaced: bool,
    schema: ?std.json.Value,
};

/// Extract per-version CRD metadata into a caller-owned slice.
/// Returns null when the CRD is malformed or has no served versions.
/// The returned slice and each CrdMeta.group_prefix are allocated via `allocator`;
/// free them with deinitCrdMetaSlice when done.
pub fn extractCrdMeta(allocator: std.mem.Allocator, crd: std.json.Value) !?[]CrdMeta {
    const root = asObject(crd) orelse return null;
    const spec = asObject(root.get("spec") orelse return null) orelse return null;

    const group = asString(spec.get("group") orelse return null) orelse return null;
    const scope_val = asString(spec.get("scope") orelse return null) orelse return null;
    const namespaced = std.mem.eql(u8, scope_val, "Namespaced");

    const names_obj = asObject(spec.get("names") orelse return null) orelse return null;
    const kind = asString(names_obj.get("kind") orelse return null) orelse return null;
    const plural = asString(names_obj.get("plural") orelse return null) orelse return null;

    const versions_arr = asArray(spec.get("versions") orelse return null) orelse return null;

    var metas: std.ArrayList(CrdMeta) = .empty;
    errdefer {
        for (metas.items) |m| allocator.free(m.group_prefix);
        metas.deinit(allocator);
    }

    const group_prefix = try openapi.sanitizeGroupIdent(allocator, group);
    errdefer allocator.free(group_prefix);
    var prefix_consumed = false;

    for (versions_arr.items) |v| {
        const ver_obj = asObject(v) orelse continue;
        const served = asBool(ver_obj.get("served") orelse continue) orelse continue;
        if (!served) continue;

        const version = asString(ver_obj.get("name") orelse continue) orelse continue;

        const schema: ?std.json.Value = blk: {
            const schema_obj = asObject(ver_obj.get("schema") orelse break :blk null) orelse break :blk null;
            break :blk schema_obj.get("openAPIV3Schema");
        };

        const entry_prefix: []u8 = if (!prefix_consumed) blk: {
            prefix_consumed = true;
            break :blk group_prefix;
        } else try allocator.dupe(u8, group_prefix);

        try metas.append(allocator, .{
            .group = group,
            .group_prefix = entry_prefix,
            .version = version,
            .kind = kind,
            .plural = plural,
            .namespaced = namespaced,
            .schema = schema,
        });
    }

    if (!prefix_consumed) allocator.free(group_prefix);
    if (metas.items.len == 0) {
        metas.deinit(allocator);
        return null;
    }
    return try metas.toOwnedSlice(allocator);
}

/// Free a slice returned by extractCrdMeta.
pub fn deinitCrdMetaSlice(allocator: std.mem.Allocator, metas: []CrdMeta) void {
    for (metas) |m| allocator.free(m.group_prefix);
    allocator.free(metas);
}

/// Context passed through recursive struct generation to collect nested structs.
const GenContext = struct {
    allocator: std.mem.Allocator,
    nested: std.ArrayList(NestedStruct),
    seen_names: std.StringArrayHashMapUnmanaged(void),

    const NestedStruct = struct {
        name: []const u8,
        schema: std.json.Value,
        description: ?[]const u8,
    };

    fn init(allocator: std.mem.Allocator) GenContext {
        return .{
            .allocator = allocator,
            .nested = .empty,
            .seen_names = .empty,
        };
    }

    fn deinit(self: *GenContext) void {
        self.nested.deinit(self.allocator);
        for (self.seen_names.keys()) |key| {
            self.allocator.free(key);
        }
        self.seen_names.deinit(self.allocator);
    }

    fn addNested(self: *GenContext, name: []const u8, schema: std.json.Value, description: ?[]const u8) !void {
        const duped = try self.allocator.dupe(u8, name);
        const gop = try self.seen_names.getOrPut(self.allocator, duped);
        if (gop.found_existing) {
            self.allocator.free(duped);
            return;
        }
        try self.nested.append(self.allocator, .{
            .name = duped,
            .schema = schema,
            .description = description,
        });
    }
};

/// Generate all types for a single CRD JSON into the writer.
pub fn generateCrd(
    allocator: std.mem.Allocator,
    writer: *Writer,
    crd: std.json.Value,
    types_import: []const u8,
) !void {
    const metas = try extractCrdMeta(allocator, crd) orelse return error.InvalidCrd;
    defer deinitCrdMetaSlice(allocator, metas);
    const multi_version = metas.len > 1;

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
/// Prefixes with the sanitized group; appends a capitalized version suffix when multi_version.
fn buildTypeName(
    allocator: std.mem.Allocator,
    group_prefix: []const u8,
    kind: []const u8,
    version: []const u8,
    multi_version: bool,
) ![]u8 {
    var buf: [2048]u8 = undefined;
    var w = Writer.fixed(&buf);
    try w.writeAll(group_prefix);
    try openapi.writeCapitalized(&w, kind);
    if (multi_version) {
        try openapi.writeCapitalized(&w, version);
    }
    return allocator.dupe(u8, w.buffered());
}

/// Generate types for a single version of a CRD.
fn generateVersion(
    allocator: std.mem.Allocator,
    writer: *Writer,
    meta: CrdMeta,
    multi_version: bool,
) !void {
    const type_name = try buildTypeName(allocator, meta.group_prefix, meta.kind, meta.version, multi_version);
    defer allocator.free(type_name);

    const list_type_name = try std.fmt.allocPrint(allocator, "{s}List", .{type_name});
    defer allocator.free(list_type_name);

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

    try writer.writeAll("    apiVersion: ?[]const u8 = null,\n");
    try writer.writeAll("    kind: ?[]const u8 = null,\n");
    try writer.writeAll("    metadata: ?types.MetaV1ObjectMeta = null,\n");

    var ctx = GenContext.init(allocator);
    defer ctx.deinit();

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

        // Handle allOf: merge properties from all sub-schemas before emitting.
        if (nested_obj.get("allOf")) |all_of_val| {
            if (asArray(all_of_val)) |all_of_arr| {
                var merged: std.json.ObjectMap = .empty;
                defer merged.deinit(ctx.allocator);

                for (all_of_arr.items) |sub_schema| {
                    const sub_obj = asObject(sub_schema) orelse continue;
                    if (sub_obj.get("properties")) |props_val| {
                        if (asObject(props_val)) |props| {
                            var it = props.iterator();
                            while (it.next()) |entry| {
                                try merged.put(ctx.allocator, entry.key_ptr.*, entry.value_ptr.*);
                            }
                        }
                    }
                }

                if (merged.count() > 0) {
                    try writeFieldsFromProperties(writer, merged, nested.name, &ctx);
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

        if (skip_standard_fields and
            (std.mem.eql(u8, field_name, "apiVersion") or
                std.mem.eql(u8, field_name, "kind") or
                std.mem.eql(u8, field_name, "metadata")))
        {
            continue;
        }
        {
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
pub fn writeSchemaType(
    writer: *Writer,
    schema: std.json.Value,
    parent_name: []const u8,
    field_name: []const u8,
    ctx: *GenContext,
) anyerror!void {
    const obj = asObject(schema) orelse {
        try writer.writeAll("json.Value");
        return;
    };

    if (obj.get("x-kubernetes-preserve-unknown-fields")) |v| {
        if (asBool(v)) |b| {
            if (b) {
                try writer.writeAll("json.Value");
                return;
            }
        }
    }

    if (obj.get("x-kubernetes-int-or-string")) |v| {
        if (asBool(v)) |b| {
            if (b) {
                try writeIntOrStringType(writer);
                return;
            }
        }
    }

    if (obj.get("oneOf") != null or obj.get("anyOf") != null) {
        try writer.writeAll("json.Value");
        return;
    }

    if (obj.get("allOf")) |all_of_val| {
        if (asArray(all_of_val)) |_| {
            var nested_name_buf: [1024]u8 = undefined;
            var nw = Writer.fixed(&nested_name_buf);
            try nw.writeAll(parent_name);
            try openapi.writeCapitalized(&nw, field_name);
            const nested_name = nw.buffered();

            try ctx.addNested(nested_name, schema, null);
            try writer.writeAll(nested_name);
            return;
        }
    }

    if (obj.get("$ref") != null) {
        try writer.writeAll("json.Value");
        return;
    }

    const type_str: ?[]const u8 = if (obj.get("type")) |t| asString(t) else null;
    const effective_type: ?[]const u8 = if (type_str) |t| t else if (obj.get("items") != null) "array" else null;

    const et = effective_type orelse {
        try writer.writeAll("json.Value");
        return;
    };

    if (std.mem.eql(u8, et, "string")) {
        if (obj.get("format")) |fmt| {
            if (asString(fmt)) |fmt_str| {
                if (std.mem.eql(u8, fmt_str, "int-or-string")) {
                    try writeIntOrStringType(writer);
                    return;
                }
                if (std.mem.eql(u8, fmt_str, "byte")) {
                    try writer.writeAll("ByteString");
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
        try writeObjectSchemaType(writer, obj, parent_name, field_name, ctx);
        return;
    }

    try writer.writeAll("json.Value");
}

/// Map an OpenAPI object schema to a Zig type based on additionalProperties.
/// false: json.Value; schema value: json.ArrayHashMap of that type;
/// true or absent with no properties: json.ArrayHashMap(json.Value);
/// with properties: named nested struct.
fn writeObjectSchemaType(
    writer: *Writer,
    obj: std.json.ObjectMap,
    parent_name: []const u8,
    field_name: []const u8,
    ctx: *GenContext,
) !void {
    if (obj.get("additionalProperties")) |ap| {
        switch (ap) {
            .bool => |b| {
                if (!b) {
                    try writer.writeAll("json.Value");
                    return;
                }
                try writer.writeAll("json.ArrayHashMap(json.Value)");
                return;
            },
            else => {
                try writer.writeAll("json.ArrayHashMap(");
                try writeSchemaType(writer, ap, parent_name, field_name, ctx);
                try writer.writeAll(")");
                return;
            },
        }
    }

    if (obj.get("properties") != null) {
        var nested_name_buf: [1024]u8 = undefined;
        var nw = Writer.fixed(&nested_name_buf);
        try nw.writeAll(parent_name);
        try openapi.writeCapitalized(&nw, field_name);
        const nested_name = nw.buffered();

        const desc: ?[]const u8 = if (obj.get("description")) |d| asString(d) else null;
        try ctx.addNested(nested_name, .{ .object = obj }, desc);
        try writer.writeAll(nested_name);
        return;
    }

    // No additionalProperties and no properties: open object per OpenAPI default.
    try writer.writeAll("json.ArrayHashMap(json.Value)");
}

fn writeIntOrStringType(writer: *Writer) !void {
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

/// Write the ByteString type definition (top-level, once per file).
pub fn writeByteStringType(writer: *Writer) !void {
    try writer.writeAll(
        \\pub const ByteString = struct {
        \\    /// Raw base64-encoded bytes as they appear in JSON.
        \\    base64: []const u8,
        \\
        \\    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: json.ParseOptions) !@This() {
        \\        switch (try source.nextAlloc(allocator, options.allocate orelse .alloc_if_needed)) {
        \\            inline .string, .allocated_string => |s| return .{ .base64 = s },
        \\            else => return error.UnexpectedToken,
        \\        }
        \\    }
        \\
        \\    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        \\        try jw.write(self.base64);
        \\    }
        \\
        \\    /// Decode from base64. Caller owns the returned slice.
        \\    pub fn decode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        \\        const size = std.base64.standard.Decoder.calcSizeForSlice(self.base64) catch return error.InvalidBase64;
        \\        const buf = try allocator.alloc(u8, size);
        \\        errdefer allocator.free(buf);
        \\        std.base64.standard.Decoder.decode(buf, self.base64) catch return error.InvalidBase64;
        \\        return buf;
        \\    }
        \\};
        \\
    );
}

/// Check if any schema in the CRD uses IntOrString.
pub fn crdUsesIntOrString(crd: std.json.Value) bool {
    return schemaUsesIntOrString(crd);
}

/// Check if any schema in the CRD uses byte-format fields.
pub fn crdUsesByteString(crd: std.json.Value) bool {
    return schemaUsesByteString(crd);
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

fn schemaUsesByteString(val: std.json.Value) bool {
    const obj = asObject(val) orelse return false;

    if (obj.get("type")) |t| {
        if (asString(t)) |ts| {
            if (std.mem.eql(u8, ts, "string")) {
                if (obj.get("format")) |f| {
                    if (asString(f)) |fs| {
                        if (std.mem.eql(u8, fs, "byte")) return true;
                    }
                }
            }
        }
    }

    if (obj.get("properties")) |props_val| {
        if (asObject(props_val)) |props| {
            for (props.values()) |v| {
                if (schemaUsesByteString(v)) return true;
            }
        }
    }

    if (obj.get("items")) |items| {
        if (schemaUsesByteString(items)) return true;
    }

    if (obj.get("additionalProperties")) |additional| {
        if (schemaUsesByteString(additional)) return true;
    }

    if (obj.get("allOf")) |all_of_val| {
        if (asArray(all_of_val)) |arr| {
            for (arr.items) |item| {
                if (schemaUsesByteString(item)) return true;
            }
        }
    }

    for (obj.values()) |child| {
        switch (child) {
            .object => {
                if (schemaUsesByteString(child)) return true;
            },
            .array => |arr| {
                for (arr.items) |item| {
                    if (schemaUsesByteString(item)) return true;
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

    // Act
    const metas_opt = try extractCrdMeta(testing.allocator, parsed.value);
    defer if (metas_opt) |m| deinitCrdMetaSlice(testing.allocator, m);

    // Assert
    const metas = metas_opt.?;
    try testing.expectEqual(@as(usize, 1), metas.len);
    try testing.expectEqualStrings("stable.example.com", metas[0].group);
    try testing.expectEqualStrings("StableExampleCom", metas[0].group_prefix);
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

    // Act
    const metas_opt = try extractCrdMeta(testing.allocator, parsed.value);
    defer if (metas_opt) |m| deinitCrdMetaSlice(testing.allocator, m);

    // Assert
    try testing.expect(!metas_opt.?[0].namespaced);
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

    // Act
    const metas_opt = try extractCrdMeta(testing.allocator, parsed.value);
    defer if (metas_opt) |m| deinitCrdMetaSlice(testing.allocator, m);

    // Assert
    const metas = metas_opt.?;
    try testing.expectEqual(@as(usize, 2), metas.len);
    try testing.expectEqualStrings("v1", metas[0].version);
    try testing.expectEqualStrings("v1beta1", metas[1].version);
}

test "extractCrdMeta: more than 16 versions are all extracted" {
    // Arrange: build a CRD JSON with 20 served versions.
    var buf: [4096]u8 = undefined;
    var w = Writer.fixed(&buf);
    try w.writeAll(
        \\{"spec":{"group":"example.com","scope":"Namespaced",
        \\"names":{"kind":"Many","plural":"manys"},
        \\"versions":[
    );
    for (0..20) |i| {
        if (i > 0) try w.writeAll(",");
        try w.print(
            \\{{"name":"v{d}","served":true,"storage":false,"schema":{{"openAPIV3Schema":{{"type":"object"}}}}}}
        , .{i + 1});
    }
    try w.writeAll("]}}");
    const crd_json = w.buffered();

    const parsed = try json_helpers.parseJson(testing.allocator, crd_json);
    defer parsed.deinit();

    // Act
    const metas_opt = try extractCrdMeta(testing.allocator, parsed.value);
    defer if (metas_opt) |m| deinitCrdMetaSlice(testing.allocator, m);

    // Assert
    try testing.expectEqual(@as(usize, 20), metas_opt.?.len);
}

test "extractCrdMeta: returns null for invalid JSON" {
    // Act
    const parsed = try json_helpers.parseJson(testing.allocator, "{}");
    defer parsed.deinit();

    // Act / Assert
    const result = try extractCrdMeta(testing.allocator, parsed.value);
    try testing.expect(result == null);
}

// ---- buildTypeName tests ----

test "buildTypeName: single version includes group prefix but omits version suffix" {
    // Act
    const name = try buildTypeName(testing.allocator, "StableExampleCom", "CronTab", "v1", false);
    defer testing.allocator.free(name);

    // Assert
    try testing.expectEqualStrings("StableExampleComCronTab", name);
}

test "buildTypeName: multi version includes group prefix and version suffix" {
    // Act
    const name = try buildTypeName(testing.allocator, "StableExampleCom", "CronTab", "v1", true);
    defer testing.allocator.free(name);

    // Assert
    try testing.expectEqualStrings("StableExampleComCronTabV1", name);
}

test "buildTypeName: multi version with beta suffix" {
    // Act
    const name = try buildTypeName(testing.allocator, "ExampleCom", "CronTab", "v1beta1", true);
    defer testing.allocator.free(name);

    // Assert
    try testing.expectEqualStrings("ExampleComCronTabV1beta1", name);
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

test "writeSchemaType: open object emits ArrayHashMap" {
    // Arrange
    const with_true = try json_helpers.parseJson(testing.allocator,
        \\{"type":"object","additionalProperties":true}
    );
    defer with_true.deinit();
    const bare = try json_helpers.parseJson(testing.allocator,
        \\{"type":"object"}
    );
    defer bare.deinit();
    var buf: [256]u8 = undefined;
    var ctx = GenContext.init(testing.allocator);
    defer ctx.deinit();

    // Act / Assert
    var w1 = Writer.fixed(&buf);
    try writeSchemaType(&w1, with_true.value, "Test", "field", &ctx);
    try testing.expectEqualStrings("json.ArrayHashMap(json.Value)", w1.buffered());

    var w2 = Writer.fixed(&buf);
    try writeSchemaType(&w2, bare.value, "Test", "field", &ctx);
    try testing.expectEqualStrings("json.ArrayHashMap(json.Value)", w2.buffered());
}

test "writeSchemaType: additionalProperties false produces json.Value" {
    // Arrange
    const parsed = try json_helpers.parseJson(testing.allocator,
        \\{"type":"object","additionalProperties":false}
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

test "writeSchemaType: format byte emits ByteString" {
    // Arrange
    const parsed = try json_helpers.parseJson(testing.allocator,
        \\{"type":"string","format":"byte"}
    );
    defer parsed.deinit();
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);
    var ctx = GenContext.init(testing.allocator);
    defer ctx.deinit();

    // Act / Assert
    try writeSchemaType(&writer, parsed.value, "Test", "caBundle", &ctx);
    try testing.expectEqualStrings("ByteString", writer.buffered());
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

// ---- crdUsesByteString tests ----

test "crdUsesByteString: detects byte format field" {
    // Act / Assert
    const parsed = try json_helpers.parseJson(testing.allocator,
        \\{"spec":{"versions":[{"schema":{"openAPIV3Schema":{"type":"object","properties":{"cert":{"type":"string","format":"byte"}}}}}]}}
    );
    defer parsed.deinit();
    try testing.expect(crdUsesByteString(parsed.value));
}

test "crdUsesByteString: false when no byte format" {
    // Act / Assert
    const parsed = try json_helpers.parseJson(testing.allocator,
        \\{"spec":{"versions":[{"schema":{"openAPIV3Schema":{"type":"object","properties":{"name":{"type":"string"}}}}}]}}
    );
    defer parsed.deinit();
    try testing.expect(!crdUsesByteString(parsed.value));
}
