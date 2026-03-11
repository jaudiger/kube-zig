const std = @import("std");

/// Parse a JSON slice into a std.json.Value tree.
pub fn parseJson(allocator: std.mem.Allocator, input: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, input, .{});
}

/// Safe accessor: returns the object map if val is a JSON object, null otherwise.
pub fn asObject(val: std.json.Value) ?std.json.ObjectMap {
    return switch (val) {
        .object => |obj| obj,
        else => null,
    };
}

/// Safe accessor: returns the string if val is a JSON string, null otherwise.
pub fn asString(val: std.json.Value) ?[]const u8 {
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

/// Safe accessor: returns the array if val is a JSON array, null otherwise.
pub fn asArray(val: std.json.Value) ?std.json.Array {
    return switch (val) {
        .array => |a| a,
        else => null,
    };
}

/// Safe accessor: returns the bool if val is a JSON boolean, null otherwise.
pub fn asBool(val: std.json.Value) ?bool {
    return switch (val) {
        .bool => |b| b,
        else => null,
    };
}
