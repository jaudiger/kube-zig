//! Kubernetes resource identity types shared across cache and controller layers.

const std = @import("std");

/// Identifies a Kubernetes resource by namespace and name.
pub const ObjectKey = struct {
    namespace: []const u8, // "" for cluster-scoped resources
    name: []const u8,

    /// Extract an ObjectKey from a Kubernetes resource type T.
    /// Returns null if the object lacks the required metadata fields.
    pub fn fromResource(comptime T: type, obj: T) ?ObjectKey {
        if (!@hasField(T, "metadata")) return null;
        const meta = obj.metadata orelse return null;
        const MetaType = @TypeOf(meta);
        const name = if (@hasField(MetaType, "name")) (meta.name orelse return null) else return null;
        const namespace = if (@hasField(MetaType, "namespace")) (meta.namespace orelse "") else "";
        return .{ .namespace = namespace, .name = name };
    }

    /// Return true if both keys have the same namespace and name.
    pub fn eql(a: ObjectKey, b: ObjectKey) bool {
        return std.mem.eql(u8, a.namespace, b.namespace) and std.mem.eql(u8, a.name, b.name);
    }

    /// Compute a hash of the namespace and name for use in hash maps.
    pub fn hash(self: ObjectKey) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(self.namespace);
        h.update(&[_]u8{0xff}); // separator
        h.update(self.name);
        return h.final();
    }
};

/// HashMap context adapter for `ObjectKey`.
pub const ObjectKeyContext = struct {
    /// Compute hash for use in `std.HashMapUnmanaged`.
    pub fn hash(_: ObjectKeyContext, key: ObjectKey) u64 {
        return key.hash();
    }

    /// Test equality for use in `std.HashMapUnmanaged`.
    pub fn eql(_: ObjectKeyContext, a: ObjectKey, b: ObjectKey) bool {
        return a.eql(b);
    }
};
