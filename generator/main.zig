const std = @import("std");
const emitter = @import("emitter.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Parse CLI arguments: <spec_path> <output_dir>
    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args_it.deinit();
    _ = args_it.skip(); // program name

    const spec_path = args_it.next() orelse
        std.process.fatal("Usage: k8s-codegen <swagger.json> <output_dir>\n", .{});
    const output_dir = args_it.next() orelse
        std.process.fatal("Usage: k8s-codegen <swagger.json> <output_dir>\n", .{});

    std.debug.print("Reading OpenAPI spec: {s}\n", .{spec_path});

    // Read the swagger.json spec (up to 64 MB).
    const spec_data = std.Io.Dir.cwd().readFileAlloc(io, spec_path, allocator, .limited(64 * 1024 * 1024)) catch |err| {
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

    // Ensure output directory exists. Ignore errors because the directory
    // may already exist; the subsequent file creation will surface a clear
    // error if the path is truly inaccessible.
    std.Io.Dir.cwd().createDirPath(io, output_dir) catch {};

    // Run the emitter to generate per-group files + root types.zig.
    emitter.generate(allocator, io, output_dir, definitions, paths) catch |err| {
        std.process.fatal("Code generation failed: {}\n", .{err});
    };

    std.debug.print("Generated types in: {s}/\n", .{output_dir});
}
