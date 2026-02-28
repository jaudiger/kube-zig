const std = @import("std");
const openapi = @import("openapi.zig");

const Writer = std.Io.Writer;

pub fn writeFieldName(writer: *Writer, name: []const u8) !void {
    if (openapi.needsQuoting(name)) {
        try writer.print("@\"{s}\"", .{name});
    } else {
        try writer.writeAll(name);
    }
}

pub fn writeDocComment(writer: *Writer, desc: []const u8) !void {
    // Write first line only as a doc comment.
    const first_line = if (std.mem.indexOfScalar(u8, desc, '\n')) |idx| desc[0..idx] else desc;
    try writer.print("/// {s}\n", .{first_line});
}

pub fn writeFieldDocComment(writer: *Writer, desc: []const u8) !void {
    const first_line = if (std.mem.indexOfScalar(u8, desc, '\n')) |idx| desc[0..idx] else desc;
    try writer.print("    /// {s}\n", .{first_line});
}
