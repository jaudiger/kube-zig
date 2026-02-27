//! Event filter predicates for informers.
//!
//! Provides composable predicate functions that gate which add, update,
//! and delete events are forwarded through an `EventHandler`. Built-in
//! predicates include generation-changed, resource-version-changed, and
//! label-selector matching. Combinators `allUpdate`, `anyUpdate`, and
//! `not*` allow composing predicates with boolean logic.

const std = @import("std");
const informer_mod = @import("informer.zig");
const EventHandler = informer_mod.EventHandler;
const testing = std.testing;

/// Predicate for add events. Returns true if the event should be forwarded.
pub fn AddPredicate(comptime T: type) type {
    return *const fn (obj: *const T, is_initial_list: bool) bool;
}

/// Predicate for update events. Returns true if the event should be forwarded.
pub fn UpdatePredicate(comptime T: type) type {
    return *const fn (old: *const T, new: *const T) bool;
}

/// Predicate for delete events. Returns true if the event should be forwarded.
pub fn DeletePredicate(comptime T: type) type {
    return *const fn (obj: *const T) bool;
}

/// Per-event predicate configuration.
pub fn PredicateConfig(comptime T: type) type {
    return struct {
        /// If set, add events are only forwarded when this returns true.
        /// If null, all add events are forwarded.
        on_add: ?AddPredicate(T) = null,
        /// If set, update events are only forwarded when this returns true.
        /// If null, all update events are forwarded.
        on_update: ?UpdatePredicate(T) = null,
        /// If set, delete events are only forwarded when this returns true.
        /// If null, all delete events are forwarded.
        on_delete: ?DeletePredicate(T) = null,
    };
}

/// Wrap an existing `EventHandler(T)` with predicate filters.
///
/// Returns a new `EventHandler(T)` that only forwards events to `inner`
/// when the corresponding predicate returns true (or is null, meaning pass-through).
///
/// The returned handler holds a pointer to the `FilteredState` struct;
/// the caller must keep the state alive for the handler's lifetime. In
/// practice, the state should be heap-allocated or stored alongside the
/// controller.
///
/// Usage:
/// ```zig
/// var filter_state = predicates.FilteredState(k8s.CoreV1Pod).init(
///     queue.rawEventHandler(k8s.CoreV1Pod),
///     .{ .on_update = predicates.generationChanged(k8s.CoreV1Pod) },
/// );
/// try informer.addEventHandler(filter_state.handler());
/// ```
pub fn FilteredState(comptime T: type) type {
    return struct {
        inner: EventHandler(T),
        config: PredicateConfig(T),

        const Self = @This();

        /// Create a new filtered state wrapping the given inner handler.
        pub fn init(inner: EventHandler(T), config: PredicateConfig(T)) Self {
            return .{ .inner = inner, .config = config };
        }

        /// Returns an `EventHandler(T)` that dispatches through the predicates.
        pub fn handler(self: *Self) EventHandler(T) {
            return EventHandler(T).fromTypedCtx(Self, self, .{
                .on_add = onAddFiltered,
                .on_update = onUpdateFiltered,
                .on_delete = onDeleteFiltered,
            });
        }

        fn onAddFiltered(self: *Self, obj: *const T, is_initial_list: bool) void {
            if (self.config.on_add) |pred| {
                if (!pred(obj, is_initial_list)) return;
            }
            self.inner.onAdd(obj, is_initial_list);
        }

        fn onUpdateFiltered(self: *Self, old: *const T, new: *const T) void {
            if (self.config.on_update) |pred| {
                if (!pred(old, new)) return;
            }
            self.inner.onUpdate(old, new);
        }

        fn onDeleteFiltered(self: *Self, obj: *const T) void {
            if (self.config.on_delete) |pred| {
                if (!pred(obj)) return;
            }
            self.inner.onDelete(obj);
        }
    };
}

// Built-in predicates
/// Returns an `UpdatePredicate(T)` that only passes when
/// `.metadata.generation` changed between old and new.
///
/// This is the standard way to prevent infinite reconcile loops when
/// a controller updates `.status` (which doesn't bump generation).
///
/// If either object has no metadata or no generation field, the event
/// is passed through (safe default: better to reconcile than to miss).
pub fn generationChanged(comptime T: type) UpdatePredicate(T) {
    return struct {
        fn pred(old: *const T, new: *const T) bool {
            const old_gen = getGeneration(T, old.*);
            const new_gen = getGeneration(T, new.*);
            if (old_gen == null or new_gen == null) return true;
            return old_gen.? != new_gen.?;
        }
    }.pred;
}

/// Returns an `UpdatePredicate(T)` that only passes when
/// `.metadata.resourceVersion` changed between old and new.
///
/// This filters out duplicate update events where the API server
/// resends the same object version.
pub fn resourceVersionChanged(comptime T: type) UpdatePredicate(T) {
    return struct {
        fn pred(old: *const T, new: *const T) bool {
            const old_rv = getResourceVersion(T, old.*);
            const new_rv = getResourceVersion(T, new.*);
            if (old_rv == null or new_rv == null) return true;
            return !std.mem.eql(u8, old_rv.?, new_rv.?);
        }
    }.pred;
}

/// Returns an `AddPredicate(T)` that only passes when the object
/// has a label matching the given key-value pair.
///
/// Usage:
/// ```zig
/// .on_add = predicates.labelSelectorMatch(k8s.CoreV1Pod, "app", "nginx"),
/// ```
pub fn labelSelectorMatch(comptime T: type, comptime key: []const u8, comptime value: []const u8) AddPredicate(T) {
    return struct {
        fn pred(obj: *const T, _: bool) bool {
            return hasMatchingLabel(T, obj.*, key, value);
        }
    }.pred;
}

/// Returns an `UpdatePredicate(T)` that only passes when the *new*
/// object has a label matching the given key-value pair.
pub fn labelSelectorMatchUpdate(comptime T: type, comptime key: []const u8, comptime value: []const u8) UpdatePredicate(T) {
    return struct {
        fn pred(_: *const T, new: *const T) bool {
            return hasMatchingLabel(T, new.*, key, value);
        }
    }.pred;
}

/// Invert an update predicate: pass when the inner predicate would reject.
pub fn notUpdate(comptime T: type, comptime pred: UpdatePredicate(T)) UpdatePredicate(T) {
    return struct {
        fn inverted(old: *const T, new: *const T) bool {
            return !pred(old, new);
        }
    }.inverted;
}

/// Invert an add predicate: pass when the inner predicate would reject.
pub fn notAdd(comptime T: type, comptime pred: AddPredicate(T)) AddPredicate(T) {
    return struct {
        fn inverted(obj: *const T, is_initial_list: bool) bool {
            return !pred(obj, is_initial_list);
        }
    }.inverted;
}

/// Invert a delete predicate: pass when the inner predicate would reject.
pub fn notDelete(comptime T: type, comptime pred: DeletePredicate(T)) DeletePredicate(T) {
    return struct {
        fn inverted(obj: *const T) bool {
            return !pred(obj);
        }
    }.inverted;
}

/// Combine two update predicates with AND logic.
pub fn allUpdate(comptime T: type, comptime a: UpdatePredicate(T), comptime b: UpdatePredicate(T)) UpdatePredicate(T) {
    return struct {
        fn pred(old: *const T, new: *const T) bool {
            return a(old, new) and b(old, new);
        }
    }.pred;
}

/// Combine two update predicates with OR logic.
pub fn anyUpdate(comptime T: type, comptime a: UpdatePredicate(T), comptime b: UpdatePredicate(T)) UpdatePredicate(T) {
    return struct {
        fn pred(old: *const T, new: *const T) bool {
            return a(old, new) or b(old, new);
        }
    }.pred;
}

// Private helpers
fn getGeneration(comptime T: type, obj: T) ?i64 {
    if (!@hasField(T, "metadata")) return null;
    const meta = obj.metadata orelse return null;
    if (!@hasField(@TypeOf(meta), "generation")) return null;
    return meta.generation;
}

fn getResourceVersion(comptime T: type, obj: T) ?[]const u8 {
    if (!@hasField(T, "metadata")) return null;
    const meta = obj.metadata orelse return null;
    if (!@hasField(@TypeOf(meta), "resourceVersion")) return null;
    return meta.resourceVersion;
}

fn hasMatchingLabel(comptime T: type, obj: T, key: []const u8, value: []const u8) bool {
    if (!@hasField(T, "metadata")) return false;
    const meta = obj.metadata orelse return false;
    if (!@hasField(@TypeOf(meta), "labels")) return false;
    const labels = meta.labels orelse return false;
    const v = labels.map.get(key) orelse return false;
    return std.mem.eql(u8, v, value);
}

const test_types = @import("../test_types.zig");
const TestMeta = test_types.TestMeta;
const TestResource = test_types.TestResource;

// generationChanged tests
test "generationChanged: false when generation is the same" {
    // Arrange
    const pred = generationChanged(TestResource);
    const old = TestResource{ .metadata = .{ .generation = 1 } };
    const new = TestResource{ .metadata = .{ .generation = 1 } };

    // Act / Assert
    try testing.expect(!pred(&old, &new));
}

test "generationChanged: true when generation differs" {
    // Arrange
    const pred = generationChanged(TestResource);
    const old = TestResource{ .metadata = .{ .generation = 1 } };
    const new = TestResource{ .metadata = .{ .generation = 2 } };

    // Act / Assert
    try testing.expect(pred(&old, &new));
}

test "generationChanged: true when old generation is null" {
    // Arrange
    const pred = generationChanged(TestResource);
    const old = TestResource{ .metadata = .{ .generation = null } };
    const new = TestResource{ .metadata = .{ .generation = 2 } };

    // Act / Assert
    try testing.expect(pred(&old, &new));
}

test "generationChanged: true when new generation is null" {
    // Arrange
    const pred = generationChanged(TestResource);
    const old = TestResource{ .metadata = .{ .generation = 1 } };
    const new = TestResource{ .metadata = .{ .generation = null } };

    // Act / Assert
    try testing.expect(pred(&old, &new));
}

test "generationChanged: true when metadata is null on either side" {
    // Arrange
    const pred = generationChanged(TestResource);
    const old = TestResource{ .metadata = null };
    const new = TestResource{ .metadata = .{ .generation = 1 } };

    // Act
    try testing.expect(pred(&old, &new));

    // Assert
    const old2 = TestResource{ .metadata = .{ .generation = 1 } };
    const new2 = TestResource{ .metadata = null };

    try testing.expect(pred(&old2, &new2));
}

// resourceVersionChanged tests
test "resourceVersionChanged: false when resourceVersion is the same" {
    // Arrange
    const pred = resourceVersionChanged(TestResource);
    const old = TestResource{ .metadata = .{ .resourceVersion = "100" } };
    const new = TestResource{ .metadata = .{ .resourceVersion = "100" } };

    // Act / Assert
    try testing.expect(!pred(&old, &new));
}

test "resourceVersionChanged: true when resourceVersion differs" {
    // Arrange
    const pred = resourceVersionChanged(TestResource);
    const old = TestResource{ .metadata = .{ .resourceVersion = "100" } };
    const new = TestResource{ .metadata = .{ .resourceVersion = "101" } };

    // Act / Assert
    try testing.expect(pred(&old, &new));
}

test "resourceVersionChanged: true when either resourceVersion is null" {
    // Arrange
    const pred = resourceVersionChanged(TestResource);
    const old = TestResource{ .metadata = .{ .resourceVersion = null } };
    const new = TestResource{ .metadata = .{ .resourceVersion = "100" } };

    // Act
    try testing.expect(pred(&old, &new));

    // Assert
    const old2 = TestResource{ .metadata = .{ .resourceVersion = "100" } };
    const new2 = TestResource{ .metadata = .{ .resourceVersion = null } };

    try testing.expect(pred(&old2, &new2));
}

// labelSelectorMatch tests
test "labelSelectorMatch: true when label matches" {
    // Arrange
    var labels_map = std.json.ArrayHashMap([]const u8){};
    defer labels_map.map.deinit(testing.allocator);
    try labels_map.map.put(testing.allocator, "app", "nginx");

    // Act
    const pred = labelSelectorMatch(TestResource, "app", "nginx");
    const obj = TestResource{ .metadata = .{ .labels = labels_map } };

    // Assert
    try testing.expect(pred(&obj, false));
}

test "labelSelectorMatch: false when label key exists but value differs" {
    // Arrange
    var labels_map = std.json.ArrayHashMap([]const u8){};
    defer labels_map.map.deinit(testing.allocator);
    try labels_map.map.put(testing.allocator, "app", "redis");

    // Act
    const pred = labelSelectorMatch(TestResource, "app", "nginx");
    const obj = TestResource{ .metadata = .{ .labels = labels_map } };

    // Assert
    try testing.expect(!pred(&obj, false));
}

test "labelSelectorMatch: false when label key doesn't exist" {
    // Arrange
    var labels_map = std.json.ArrayHashMap([]const u8){};
    defer labels_map.map.deinit(testing.allocator);
    try labels_map.map.put(testing.allocator, "env", "prod");

    // Act
    const pred = labelSelectorMatch(TestResource, "app", "nginx");
    const obj = TestResource{ .metadata = .{ .labels = labels_map } };

    // Assert
    try testing.expect(!pred(&obj, false));
}

test "labelSelectorMatch: false when labels is null" {
    // Arrange
    const pred = labelSelectorMatch(TestResource, "app", "nginx");
    const obj = TestResource{ .metadata = .{ .labels = null } };

    // Act / Assert
    try testing.expect(!pred(&obj, false));
}

test "labelSelectorMatch: false when metadata is null" {
    // Arrange
    const pred = labelSelectorMatch(TestResource, "app", "nginx");
    const obj = TestResource{ .metadata = null };

    // Act / Assert
    try testing.expect(!pred(&obj, false));
}

// labelSelectorMatchUpdate tests
test "labelSelectorMatchUpdate: true when new object label matches" {
    // Arrange
    var labels_map = std.json.ArrayHashMap([]const u8){};
    defer labels_map.map.deinit(testing.allocator);
    try labels_map.map.put(testing.allocator, "app", "nginx");

    // Act
    const pred = labelSelectorMatchUpdate(TestResource, "app", "nginx");
    const old = TestResource{};
    const new = TestResource{ .metadata = .{ .labels = labels_map } };

    // Assert
    try testing.expect(pred(&old, &new));
}

test "labelSelectorMatchUpdate: false when new object label doesn't match" {
    // Arrange
    const pred = labelSelectorMatchUpdate(TestResource, "app", "nginx");
    const old = TestResource{};
    const new = TestResource{ .metadata = .{ .labels = null } };

    // Act / Assert
    try testing.expect(!pred(&old, &new));
}

// notUpdate / notAdd / notDelete tests
test "notUpdate: inverts true to false" {
    // Arrange
    const pred = notUpdate(TestResource, alwaysTrueUpdate);
    const obj = TestResource{};

    // Act / Assert
    try testing.expect(!pred(&obj, &obj));
}

test "notUpdate: inverts false to true" {
    // Arrange
    const pred = notUpdate(TestResource, alwaysFalseUpdate);
    const obj = TestResource{};

    // Act / Assert
    try testing.expect(pred(&obj, &obj));
}

test "notAdd: inverts result" {
    // Arrange
    const pred = notAdd(TestResource, alwaysTrueAdd);
    const obj = TestResource{};

    // Act / Assert
    try testing.expect(!pred(&obj, false));
}

test "notDelete: inverts result" {
    // Arrange
    const pred = notDelete(TestResource, alwaysTrueDelete);
    const obj = TestResource{};

    // Act / Assert
    try testing.expect(!pred(&obj));
}

// allUpdate / anyUpdate tests
fn alwaysTrueUpdate(_: *const TestResource, _: *const TestResource) bool {
    return true;
}

fn alwaysFalseUpdate(_: *const TestResource, _: *const TestResource) bool {
    return false;
}

fn alwaysTrueAdd(_: *const TestResource, _: bool) bool {
    return true;
}

fn alwaysFalseAdd(_: *const TestResource, _: bool) bool {
    return false;
}

fn alwaysTrueDelete(_: *const TestResource) bool {
    return true;
}

test "allUpdate: true only when both are true" {
    // Arrange
    const pred = allUpdate(TestResource, alwaysTrueUpdate, alwaysTrueUpdate);
    const obj = TestResource{};

    // Act / Assert
    try testing.expect(pred(&obj, &obj));
}

test "allUpdate: false when first is false" {
    // Arrange
    const pred = allUpdate(TestResource, alwaysFalseUpdate, alwaysTrueUpdate);
    const obj = TestResource{};

    // Act / Assert
    try testing.expect(!pred(&obj, &obj));
}

test "allUpdate: false when second is false" {
    // Arrange
    const pred = allUpdate(TestResource, alwaysTrueUpdate, alwaysFalseUpdate);
    const obj = TestResource{};

    // Act / Assert
    try testing.expect(!pred(&obj, &obj));
}

test "anyUpdate: true when first is true" {
    // Arrange
    const pred = anyUpdate(TestResource, alwaysTrueUpdate, alwaysFalseUpdate);
    const obj = TestResource{};

    // Act / Assert
    try testing.expect(pred(&obj, &obj));
}

test "anyUpdate: true when second is true" {
    // Arrange
    const pred = anyUpdate(TestResource, alwaysFalseUpdate, alwaysTrueUpdate);
    const obj = TestResource{};

    // Act / Assert
    try testing.expect(pred(&obj, &obj));
}

test "anyUpdate: false when both are false" {
    // Arrange
    const pred = anyUpdate(TestResource, alwaysFalseUpdate, alwaysFalseUpdate);
    const obj = TestResource{};

    // Act / Assert
    try testing.expect(!pred(&obj, &obj));
}

// FilteredState + handler integration tests
const Counter = struct {
    add_count: u32 = 0,
    update_count: u32 = 0,
    delete_count: u32 = 0,

    fn onAdd(self: *Counter, _: *const TestResource, _: bool) void {
        self.add_count += 1;
    }

    fn onUpdate(self: *Counter, _: *const TestResource, _: *const TestResource) void {
        self.update_count += 1;
    }

    fn onDelete(self: *Counter, _: *const TestResource) void {
        self.delete_count += 1;
    }
};

test "FilteredState: generationChanged filters same-generation updates" {
    // Arrange
    var counter = Counter{};
    const inner = EventHandler(TestResource).fromTypedCtx(Counter, &counter, .{
        .on_add = Counter.onAdd,
        .on_update = Counter.onUpdate,
        .on_delete = Counter.onDelete,
    });
    var state = FilteredState(TestResource).init(inner, .{
        .on_update = generationChanged(TestResource),
    });
    const h = state.handler();

    // Act
    const old1 = TestResource{ .metadata = .{ .generation = 1 } };
    const new1 = TestResource{ .metadata = .{ .generation = 1 } };
    h.onUpdate(&old1, &new1);

    // Assert
    try testing.expectEqual(@as(u32, 0), counter.update_count);

    const old2 = TestResource{ .metadata = .{ .generation = 1 } };
    const new2 = TestResource{ .metadata = .{ .generation = 2 } };
    h.onUpdate(&old2, &new2);

    try testing.expectEqual(@as(u32, 1), counter.update_count);
}

test "FilteredState: delete passes through when on_delete is null" {
    // Arrange
    var counter = Counter{};
    const inner = EventHandler(TestResource).fromTypedCtx(Counter, &counter, .{
        .on_delete = Counter.onDelete,
    });
    var state = FilteredState(TestResource).init(inner, .{
        .on_update = generationChanged(TestResource),
        // on_delete is null, so it passes through
    });
    const h = state.handler();
    const obj = TestResource{};

    // Act
    h.onDelete(&obj);

    // Assert
    try testing.expectEqual(@as(u32, 1), counter.delete_count);
}

test "FilteredState: add events filtered when predicate returns false" {
    // Arrange
    var counter = Counter{};
    const inner = EventHandler(TestResource).fromTypedCtx(Counter, &counter, .{
        .on_add = Counter.onAdd,
    });
    var state = FilteredState(TestResource).init(inner, .{
        .on_add = alwaysFalseAdd,
    });
    const h = state.handler();
    const obj = TestResource{};

    // Act
    h.onAdd(&obj, false);

    // Assert
    try testing.expectEqual(@as(u32, 0), counter.add_count);
}

test "FilteredState: add events pass when predicate returns true" {
    // Arrange
    var counter = Counter{};
    const inner = EventHandler(TestResource).fromTypedCtx(Counter, &counter, .{
        .on_add = Counter.onAdd,
    });
    var state = FilteredState(TestResource).init(inner, .{
        .on_add = alwaysTrueAdd,
    });
    const h = state.handler();
    const obj = TestResource{};

    // Act
    h.onAdd(&obj, false);

    // Assert
    try testing.expectEqual(@as(u32, 1), counter.add_count);
}
