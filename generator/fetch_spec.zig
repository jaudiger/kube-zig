const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    // Parse CLI arguments: <k8s-version> <output-path>
    const args = try std.process.argsAlloc(allocator);

    if (args.len < 3) {
        std.process.fatal("Usage: fetch-spec <k8s-version> <output-path>\n", .{});
    }

    const raw_version = args[1];
    const output_path = args[2];

    // Resolve "latest" to an actual tag via the GitHub API.
    const version = if (std.mem.eql(u8, raw_version, "latest"))
        resolveLatestVersion(allocator) catch |err| {
            std.process.fatal("Failed to resolve latest version: {}\n", .{err});
        }
    else
        raw_version;

    std.debug.print("Downloading Kubernetes {s} OpenAPI spec...\n", .{version});

    // Construct the raw GitHub URL for the spec file.
    const url = std.fmt.allocPrint(
        allocator,
        "https://raw.githubusercontent.com/kubernetes/kubernetes/{s}/api/openapi-spec/swagger.json",
        .{version},
    ) catch |err| {
        std.process.fatal("Failed to format URL: {}\n", .{err});
    };

    // Download the spec.
    const body = fetch(allocator, url) catch |err| {
        std.process.fatal("Failed to download spec from {s}: {}\n", .{ url, err });
    };

    // Ensure the parent directory exists. Ignore errors because the
    // directory may already exist; the subsequent writeFile will surface
    // a clear error if the path is truly inaccessible.
    if (std.fs.path.dirname(output_path)) |dir| {
        std.fs.cwd().makePath(dir) catch {};
    }

    // Write the response body to the output file.
    std.fs.cwd().writeFile(.{
        .sub_path = output_path,
        .data = body,
    }) catch |err| {
        std.process.fatal("Failed to write {s}: {}\n", .{ output_path, err });
    };

    std.debug.print("Wrote {d} bytes to {s}\n", .{ body.len, output_path });
}

/// Queries the GitHub API to resolve the latest Kubernetes release tag.
fn resolveLatestVersion(allocator: std.mem.Allocator) ![]const u8 {
    std.debug.print("Resolving latest Kubernetes version...\n", .{});

    const body = try fetch(allocator, "https://api.github.com/repos/kubernetes/kubernetes/releases/latest");

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidTagName,
    };

    const tag = obj.get("tag_name") orelse return error.NoTagName;

    const tag_str = switch (tag) {
        .string => |s| s,
        else => return error.InvalidTagName,
    };

    // Copy since the parsed value owns the memory.
    const result = try allocator.dupe(u8, tag_str);
    std.debug.print("Resolved latest version: {s}\n", .{result});
    return result;
}

/// Performs an HTTP GET request and returns the (decompressed) response body.
fn fetch(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(url);

    var req = try client.request(.GET, uri, .{});
    defer req.deinit();

    try req.sendBodiless();

    var redirect_buf: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);

    if (response.head.status != .ok) {
        std.debug.print("HTTP {d} for {s}\n", .{ @intFromEnum(response.head.status), url });
        return error.HttpError;
    }

    // Allocate a decompression window when the server returns compressed
    // content (gzip/deflate). The client advertises Accept-Encoding: gzip
    // by default, so raw.githubusercontent.com typically responds with
    // Content-Encoding: gzip.
    const decompress_buf: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try allocator.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try allocator.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer if (decompress_buf.len > 0) allocator.free(decompress_buf);

    var transfer_buf: [8192]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buf, &decompress, decompress_buf);
    return try reader.allocRemaining(allocator, std.Io.Limit.limited(64 * 1024 * 1024));
}
