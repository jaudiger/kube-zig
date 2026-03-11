const std = @import("std");

/// Detect std.json.ArrayHashMap(V) at comptime.
/// These wrap a StringArrayHashMapUnmanaged and expose jsonParse/jsonStringify.
pub fn isJsonArrayHashMap(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .@"struct") return false;
    return @hasField(T, "map") and @hasDecl(T, "jsonStringify");
}
