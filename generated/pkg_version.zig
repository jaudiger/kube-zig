// Auto-generated from Kubernetes OpenAPI spec.
// Do not edit manually. Regenerate with: zig build generate

const std = @import("std");
const json = std.json;

/// Info contains versioning information. how we'll want to distribute that information.
pub const PkgVersionInfo = struct {
    buildDate: []const u8,
    compiler: []const u8,
    /// EmulationMajor is the major version of the emulation version
    emulationMajor: ?[]const u8 = null,
    /// EmulationMinor is the minor version of the emulation version
    emulationMinor: ?[]const u8 = null,
    gitCommit: []const u8,
    gitTreeState: []const u8,
    gitVersion: []const u8,
    goVersion: []const u8,
    /// Major is the major version of the binary version
    major: []const u8,
    /// MinCompatibilityMajor is the major version of the minimum compatibility version
    minCompatibilityMajor: ?[]const u8 = null,
    /// MinCompatibilityMinor is the minor version of the minimum compatibility version
    minCompatibilityMinor: ?[]const u8 = null,
    /// Minor is the minor version of the binary version
    minor: []const u8,
    platform: []const u8,
};
