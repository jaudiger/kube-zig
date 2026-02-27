// Auto-generated from Kubernetes OpenAPI spec.
// Do not edit manually. Regenerate with: zig build generate

const std = @import("std");
const json = std.json;

/// IntOrString is a type that can hold an int32 or a string.  When used in JSON or YAML marshalling and unmarshalling, it produces or consumes the inner type.  This allows you to have, for example, a JSON field that can accept a name or number.
pub const UtilIntstrIntOrString = union(enum) {
    int: i64,
    string: []const u8,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: json.ParseOptions) !@This() {
        switch (try source.peekNextTokenType()) {
            .number => {
                switch (try source.next()) {
                    inline .number, .allocated_number => |s| {
                        return .{ .int = std.fmt.parseInt(i64, s, 10) catch return error.UnexpectedToken };
                    },
                    else => return error.UnexpectedToken,
                }
            },
            .string => {
                switch (try source.nextAlloc(allocator, options.allocate orelse .alloc_if_needed)) {
                    inline .string, .allocated_string => |s| return .{ .string = s },
                    else => return error.UnexpectedToken,
                }
            },
            else => return error.UnexpectedToken,
        }
    }

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        switch (self) {
            .int => |v| try jw.write(v),
            .string => |v| try jw.write(v),
        }
    }
};
