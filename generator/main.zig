const std = @import("std");
const emitter = @import("emitter.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    // Parse CLI arguments: <spec_path> <output_dir>
    const args = try std.process.argsAlloc(allocator);

    if (args.len < 3) {
        std.process.fatal("Usage: k8s-codegen <swagger.json> <output_dir>\n", .{});
    }

    const spec_path = args[1];
    const output_dir = args[2];

    std.debug.print("Reading OpenAPI spec: {s}\n", .{spec_path});

    // Read the swagger.json spec (up to 64 MB).
    const spec_data = std.fs.cwd().readFileAlloc(allocator, spec_path, 64 * 1024 * 1024) catch |err| {
        std.process.fatal("Failed to read {s}: {}\n", .{ spec_path, err });
    };

    std.debug.print("Parsing JSON ({d} bytes)...\n", .{spec_data.len});

    // Parse the full JSON tree.
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, spec_data, .{}) catch |err| {
        std.process.fatal("JSON parse error: {}\n", .{err});
    };
    defer parsed.deinit();

    const root = parsed.value.object;

    // Extract the "definitions" map.
    const definitions = if (root.get("definitions")) |d|
        d.object
    else {
        std.process.fatal("No 'definitions' key found in spec.\n", .{});
    };

    // Extract the "paths" map (for resource metadata).
    const paths = if (root.get("paths")) |p| p.object else blk: {
        std.debug.print("Warning: No 'paths' key found in spec, skipping resource metadata.\n", .{});
        break :blk null;
    };

    std.debug.print("Found {d} definitions. Generating types...\n", .{definitions.count()});

    // Ensure output directory exists.
    std.fs.cwd().makePath(output_dir) catch {};

    // Run the emitter to generate per-group files + root types.zig.
    emitter.generate(allocator, output_dir, definitions, paths) catch |err| {
        std.process.fatal("Code generation failed: {}\n", .{err});
    };

    std.debug.print("Generated types in: {s}/\n", .{output_dir});
}
