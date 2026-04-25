const std = @import("std");
const crd_emitter = @import("crd_emitter.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Parse CLI arguments.
    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args_it.deinit();
    _ = args_it.skip(); // program name

    // Parse --types-import option and collect positional args.
    var types_import: []const u8 = "types.zig";
    var positional: std.ArrayList([]const u8) = .empty;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--types-import")) {
            const value = args_it.next() orelse
                std.process.fatal("--types-import requires a value\n", .{});
            types_import = value;
        } else {
            try positional.append(allocator, arg);
        }
    }

    if (positional.items.len < 2) {
        std.process.fatal(
            \\Usage: crd-codegen [options] <output_file> <crd1.json> [crd2.json ...]
            \\
            \\Options:
            \\  --types-import <path>   Import path for K8s types module (default: "types.zig")
            \\
        , .{});
    }

    const output_path = positional.items[0];
    const crd_files = positional.items[1..];

    std.debug.print("CRD Code Generator\n", .{});
    std.debug.print("Output: {s}\n", .{output_path});
    std.debug.print("Types import: {s}\n", .{types_import});
    std.debug.print("Input CRDs: {d} file(s)\n\n", .{crd_files.len});

    // Open output file.
    const output_file = std.Io.Dir.cwd().createFile(io, output_path, .{}) catch |err| {
        std.process.fatal("Failed to create output file {s}: {}\n", .{ output_path, err });
    };
    defer output_file.close(io);

    var write_buf: [8192]u8 = undefined;
    var file_writer = output_file.writer(io, &write_buf);
    const writer = &file_writer.interface;

    // Track whether we need IntOrString and whether any CRD was written.
    var needs_int_or_string = false;
    var first_crd = true;

    // First pass: check if any CRD uses IntOrString.
    for (crd_files) |crd_path| {
        const crd_data = std.Io.Dir.cwd().readFileAlloc(io, crd_path, allocator, .limited(16 * 1024 * 1024)) catch |err| {
            std.process.fatal("Failed to read {s}: {}\n", .{ crd_path, err });
        };

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, crd_data, .{}) catch |err| {
            std.process.fatal("JSON parse error in {s}: {}\n", .{ crd_path, err });
        };

        if (crd_emitter.crdUsesIntOrString(parsed.value)) {
            needs_int_or_string = true;
            break;
        }
    }

    // Process each CRD file.
    for (crd_files) |crd_path| {
        std.debug.print("Processing: {s}\n", .{crd_path});

        const crd_data = std.Io.Dir.cwd().readFileAlloc(io, crd_path, allocator, .limited(16 * 1024 * 1024)) catch |err| {
            std.process.fatal("Failed to read {s}: {}\n", .{ crd_path, err });
        };

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, crd_data, .{}) catch |err| {
            std.process.fatal("JSON parse error in {s}: {}\n", .{ crd_path, err });
        };

        if (first_crd) {
            // The first CRD's generateCrd call writes the file header.
            first_crd = false;
        } else {
            // Separator between CRDs.
            try writer.writeAll("\n");
        }

        crd_emitter.generateCrd(allocator, writer, parsed.value, types_import) catch |err| {
            std.process.fatal("Code generation failed for {s}: {}\n", .{ crd_path, err });
        };
    }

    // Write IntOrString union if needed.
    if (needs_int_or_string) {
        try crd_emitter.writeIntOrStringUnion(writer);
    }

    try writer.flush();

    std.debug.print("\nGenerated: {s}\n", .{output_path});
}
