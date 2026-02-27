const std = @import("std");

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
