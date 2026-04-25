//! Informer combining a reflector, store, and event dispatch.
//!
//! `Informer(T)` maintains a local in-memory cache of Kubernetes resources
//! by running a list+watch loop via a `Reflector` and routing change events
//! to registered `EventHandler` callbacks. Supports graceful shutdown via
//! `stop()` and query access to the cache through `getStore()`.

const std = @import("std");
const client_mod = @import("../client/Client.zig");
const Client = client_mod.Client;
const Context = client_mod.Context;
const CancelSource = client_mod.CancelSource;
const store_mod = @import("store.zig");
const ObjectKey = @import("../object_key.zig").ObjectKey;
const watch_mod = @import("../api/watch.zig");
const reflector_mod = @import("reflector.zig");
const ReflectorEvent = reflector_mod.ReflectorEvent;
const InformerMetrics = @import("../util/metrics.zig").InformerMetrics;
const logging_mod = @import("../util/logging.zig");
const Logger = logging_mod.Logger;
const LogField = logging_mod.Field;

/// Type-erased event handler for Informer callbacks.
///
/// Use `EventHandler(T).fromFns(...)` to create a handler from plain function pointers,
/// or `EventHandler(T).fromTypedCtx(...)` to create one with a typed context pointer.
pub fn EventHandler(comptime T: type) type {
    return struct {
        const Self = @This();

        ctx: ?*anyopaque,
        on_add_fn: ?*const fn (ctx: ?*anyopaque, io: std.Io, obj: *const T, is_initial_list: bool) void,
        on_update_fn: ?*const fn (ctx: ?*anyopaque, io: std.Io, old: *const T, new: *const T) void,
        on_delete_fn: ?*const fn (ctx: ?*anyopaque, io: std.Io, obj: *const T) void,

        /// Create a handler from a typed context pointer.
        /// Each callback receives the context as its first argument.
        pub fn fromTypedCtx(comptime Ctx: type, ctx: *Ctx, comptime fns: struct {
            on_add: ?*const fn (c: *Ctx, io: std.Io, obj: *const T, is_initial_list: bool) void = null,
            on_update: ?*const fn (c: *Ctx, io: std.Io, old: *const T, new: *const T) void = null,
            on_delete: ?*const fn (c: *Ctx, io: std.Io, obj: *const T) void = null,
        }) Self {
            const Wrapper = struct {
                fn onAdd(raw: ?*anyopaque, io: std.Io, obj: *const T, is_init: bool) void {
                    if (fns.on_add) |f| f(@ptrCast(@alignCast(raw.?)), io, obj, is_init);
                }
                fn onUpdate(raw: ?*anyopaque, io: std.Io, old: *const T, new: *const T) void {
                    if (fns.on_update) |f| f(@ptrCast(@alignCast(raw.?)), io, old, new);
                }
                fn onDelete(raw: ?*anyopaque, io: std.Io, obj: *const T) void {
                    if (fns.on_delete) |f| f(@ptrCast(@alignCast(raw.?)), io, obj);
                }
            };
            return .{
                .ctx = @ptrCast(ctx),
                .on_add_fn = if (fns.on_add != null) Wrapper.onAdd else null,
                .on_update_fn = if (fns.on_update != null) Wrapper.onUpdate else null,
                .on_delete_fn = if (fns.on_delete != null) Wrapper.onDelete else null,
            };
        }

        /// Create a handler from plain function pointers (no context).
        pub fn fromFns(comptime fns: struct {
            on_add: ?*const fn (io: std.Io, obj: *const T, is_initial_list: bool) void = null,
            on_update: ?*const fn (io: std.Io, old: *const T, new: *const T) void = null,
            on_delete: ?*const fn (io: std.Io, obj: *const T) void = null,
        }) Self {
            // Wrap plain functions to match the ctx-based signature.
            const Wrapper = struct {
                fn onAdd(_: ?*anyopaque, io: std.Io, obj: *const T, is_init: bool) void {
                    if (fns.on_add) |f| f(io, obj, is_init);
                }
                fn onUpdate(_: ?*anyopaque, io: std.Io, old: *const T, new: *const T) void {
                    if (fns.on_update) |f| f(io, old, new);
                }
                fn onDelete(_: ?*anyopaque, io: std.Io, obj: *const T) void {
                    if (fns.on_delete) |f| f(io, obj);
                }
            };
            return .{
                .ctx = null,
                .on_add_fn = if (fns.on_add != null) Wrapper.onAdd else null,
                .on_update_fn = if (fns.on_update != null) Wrapper.onUpdate else null,
                .on_delete_fn = if (fns.on_delete != null) Wrapper.onDelete else null,
            };
        }

        /// Invoke the on-add callback if registered.
        pub fn onAdd(self: Self, io: std.Io, obj: *const T, is_initial_list: bool) void {
            if (self.on_add_fn) |f| f(self.ctx, io, obj, is_initial_list);
        }

        /// Invoke the on-update callback if registered.
        pub fn onUpdate(self: Self, io: std.Io, old: *const T, new: *const T) void {
            if (self.on_update_fn) |f| f(self.ctx, io, old, new);
        }

        /// Invoke the on-delete callback if registered.
        pub fn onDelete(self: Self, io: std.Io, obj: *const T) void {
            if (self.on_delete_fn) |f| f(self.ctx, io, obj);
        }
    };
}

/// Type-safe Informer that maintains a local in-memory cache of Kubernetes
/// resources, kept in sync via list+watch.
///
/// Usage:
/// ```zig
/// var informer = Informer(k8s.CoreV1Pod).init(allocator, &client, client.context(), "default", .{});
/// defer informer.deinit();
/// try informer.addEventHandler(EventHandler(k8s.CoreV1Pod).fromFns(.{
///     .on_add = myOnAdd,
///     .on_update = myOnUpdate,
///     .on_delete = myOnDelete,
/// }));
/// try informer.run(); // blocks until stop() or shutdown
/// ```
pub fn Informer(comptime T: type) type {
    const meta = T.resource_meta;
    const StoreT = store_mod.Store(T);
    const ReflectorT = reflector_mod.Reflector(T);
    const HandlerT = EventHandler(T);

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        store: StoreT,
        reflector: ReflectorT,
        handlers: std.ArrayList(HandlerT),
        parent_ctx: Context,
        cancel: CancelSource,
        sync_failed: std.atomic.Value(bool),
        running: std.atomic.Value(bool),
        metrics: InformerMetrics,
        logger: Logger,

        /// Staging buffer for initial list pages (atomic swap pattern).
        staging: std.ArrayList(StoreT.ReplaceItem),

        pub const Options = struct {
            label_selector: ?[]const u8 = null,
            field_selector: ?[]const u8 = null,
            page_size: i64 = 500,
            watch_timeout_seconds: i64 = 290,
            metrics: InformerMetrics = InformerMetrics.noop,
            logger: Logger = Logger.noop,
        };

        /// Create a new informer for the given resource type and namespace.
        pub fn init(
            allocator: std.mem.Allocator,
            client: *Client,
            ctx: Context,
            namespace: if (meta.namespaced) []const u8 else ?[]const u8,
            opts: Options,
        ) Self {
            const scoped_logger = opts.logger.withScope("informer");
            var store = StoreT.init(allocator);
            store.logger = scoped_logger.withScope("store");
            return .{
                .allocator = allocator,
                .store = store,
                .reflector = ReflectorT.init(allocator, client, ctx, namespace, .{
                    .label_selector = opts.label_selector,
                    .field_selector = opts.field_selector,
                    .page_size = opts.page_size,
                    .watch_timeout_seconds = opts.watch_timeout_seconds,
                    .metrics = opts.metrics,
                    .logger = opts.logger,
                }),
                .handlers = .empty,
                .parent_ctx = ctx,
                .cancel = CancelSource.init(),
                .sync_failed = std.atomic.Value(bool).init(false),
                .running = std.atomic.Value(bool).init(false),
                .metrics = opts.metrics,
                .logger = scoped_logger,
                .staging = .empty,
            };
        }

        /// Release all resources including the store, reflector, and staging buffer.
        pub fn deinit(self: *Self, io: std.Io) void {
            // Free any remaining staging items.
            for (self.staging.items) |item| {
                item.arena.deinit();
                self.allocator.destroy(item.arena);
            }
            self.staging.deinit(self.allocator);
            self.handlers.deinit(self.allocator);
            self.reflector.deinit(io);
            self.store.deinit(io);
        }

        /// Register an event handler.
        ///
        /// Must be called before `run()`. Adding handlers after the
        /// informer loop has started is not thread-safe.
        pub fn addEventHandler(self: *Self, handler: HandlerT) !void {
            std.debug.assert(!self.running.load(.acquire));
            try self.handlers.append(self.allocator, handler);
        }

        /// Run the informer loop. Blocks until `stop()` is called or
        /// the client shuts down.
        pub fn run(self: *Self, io: std.Io) !void {
            self.running.store(true, .release);
            self.logger.info("informer starting", &.{
                LogField.string("resource", meta.resource),
            });
            const ctx = self.parent_ctx.withCancel(&self.cancel);
            self.reflector.ctx = ctx;
            while (!ctx.isCanceled(io)) {
                if (self.reflector.state == .failed) return error.ReflectorFailed;

                const maybe_event = self.reflector.step(io) catch {
                    self.reflector.backoffSleep(io, ctx) catch return;
                    continue;
                };

                if (maybe_event) |event| {
                    self.processEvent(io, event);

                    // Apply backoff after processing transient errors.
                    // The reflector returns transient errors as events (not Zig
                    // errors), so the catch branch above doesn't trigger.
                    switch (event) {
                        .transient_error, .persistent_error => {
                            self.reflector.backoffSleep(io, ctx) catch return;
                        },
                        else => {},
                    }
                }
            }
        }

        /// Signal the informer to stop.
        pub fn stop(self: *Self, io: std.Io) void {
            self.logger.info("informer stopping", &.{
                LogField.string("resource", meta.resource),
            });
            self.cancel.cancel(io);
            self.reflector.interruptWatch(io);
        }

        /// Has the initial list been fully synced to the store?
        pub fn hasSynced(self: *Self, io: std.Io) bool {
            return self.store.hasSynced(io);
        }

        /// Returns true if the initial sync failed permanently (e.g. OOM
        /// during the store replace). When true, `hasSynced()` will never
        /// become true and the informer should be considered broken.
        pub fn hasSyncFailed(self: *Self) bool {
            return self.sync_failed.load(.acquire);
        }

        /// Get a read-only handle to the store for querying cached objects.
        pub fn getStore(self: *Self) StoreT.View {
            return .{ .store = &self.store };
        }

        // Internal
        fn processEvent(self: *Self, io: std.Io, event: ReflectorEvent(T)) void {
            switch (event) {
                .init_page => |page| self.processInitPage(io, page),
                .watch_event => |parsed| self.processWatchEvent(io, parsed),
                .watch_ended => {
                    self.metrics.watch_restarts_total.inc();
                },
                .gone => {
                    self.metrics.watch_restarts_total.inc();
                    // Clear staging for the upcoming re-list.
                    self.clearStaging();
                    self.sync_failed.store(false, .release);
                },
                .transient_error => {},
                .persistent_error => {},
            }
        }

        fn processInitPage(self: *Self, io: std.Io, page: ReflectorEvent(T).InitPage) void {
            defer if (page.rv_buf) |buf| self.allocator.free(buf);

            // If a previous page failed, discard all subsequent pages
            // to prevent a partial store replacement.
            if (self.sync_failed.load(.acquire)) {
                self.freeReplaceItems(page.items);
                return;
            }

            // Buffer items into staging.
            self.staging.appendSlice(self.allocator, page.items) catch {
                // On OOM, free the items we couldn't stage and abort the
                // entire sync to prevent a partial store.replace().
                self.logger.err("staging append failed: OOM, aborting sync", &.{});
                self.freeReplaceItems(page.items);
                return self.abortSyncAndRelist(io);
            };
            // Free the items array (items themselves are now in staging).
            self.allocator.free(page.items);

            if (page.is_last) {
                // Atomic swap into store.
                const staged = self.staging.toOwnedSlice(self.allocator) catch {
                    // On OOM, leave staging as-is; will be cleaned up on deinit.
                    self.logger.err("sync failed: OOM converting staging to owned slice", &.{});
                    return self.abortSyncAndRelist(io);
                };
                const replace_result = self.store.replace(io, staged) catch {
                    self.logger.err("sync failed: could not replace store contents", &.{});
                    // replace() takes unconditional ownership of arenas;
                    // only free the slice itself.
                    self.allocator.free(staged);
                    return self.abortSyncAndRelist(io);
                };
                self.logger.info("store replace succeeded", &.{
                    LogField.uint("item_count", @intCast(staged.len)),
                });
                self.allocator.free(staged);

                // Dispatch delete events for items removed during re-list.
                for (replace_result.entries) |entry| {
                    for (self.handlers.items) |h| h.onDelete(io, &entry.object);
                }
                replace_result.release();

                self.metrics.store_object_count.set(@floatFromInt(self.store.len(io)));

                // Dispatch add events for all items in the store.
                self.logger.debug("dispatching initial add events", &.{
                    LogField.uint("handler_count", @intCast(self.handlers.items.len)),
                });
                self.dispatchInitialAdds(io);

                if (!self.sync_failed.load(.acquire) and self.store.hasSynced(io)) {
                    self.metrics.initial_list_synced.set(1.0);
                }
            }
        }

        fn processWatchEvent(self: *Self, io: std.Io, parsed: watch_mod.ParsedEvent(T)) void {
            switch (parsed.event) {
                .added => |obj| {
                    const key = ObjectKey.fromResource(T, obj) orelse {
                        parsed.deinit();
                        return;
                    };
                    self.logger.debug("watch add", &.{
                        LogField.string("namespace", key.namespace),
                        LogField.string("name", key.name),
                    });
                    const old = self.store.put(io, key, obj, parsed.arena) catch {
                        parsed.deinit();
                        self.logger.err("watch add failed (OOM), forcing re-list", &.{});
                        self.reflector.forceRelist(io) catch {
                            self.logger.err("forceRelist failed: OOM setting resource version", &.{});
                        };
                        return;
                    };
                    if (old) |old_entry| {
                        // This was actually an update (object existed).
                        for (self.handlers.items) |h| h.onUpdate(io, &old_entry.object, &obj);
                        old_entry.release();
                    } else {
                        for (self.handlers.items) |h| h.onAdd(io, &obj, false);
                    }
                    self.metrics.watch_events_total.inc();
                    self.metrics.store_object_count.set(@floatFromInt(self.store.len(io)));
                },
                .modified => |obj| {
                    const key = ObjectKey.fromResource(T, obj) orelse {
                        parsed.deinit();
                        return;
                    };
                    self.logger.debug("watch modify", &.{
                        LogField.string("namespace", key.namespace),
                        LogField.string("name", key.name),
                    });
                    const old = self.store.put(io, key, obj, parsed.arena) catch {
                        parsed.deinit();
                        self.logger.err("watch modify failed (OOM), forcing re-list", &.{});
                        self.reflector.forceRelist(io) catch {
                            self.logger.err("forceRelist failed: OOM setting resource version", &.{});
                        };
                        return;
                    };
                    if (old) |old_entry| {
                        for (self.handlers.items) |h| h.onUpdate(io, &old_entry.object, &obj);
                        old_entry.release();
                    } else {
                        // Object didn't exist yet; treat as add.
                        for (self.handlers.items) |h| h.onAdd(io, &obj, false);
                    }
                    self.metrics.watch_events_total.inc();
                    self.metrics.store_object_count.set(@floatFromInt(self.store.len(io)));
                },
                .deleted => |obj| {
                    const key = ObjectKey.fromResource(T, obj) orelse {
                        parsed.deinit();
                        return;
                    };
                    self.logger.debug("watch delete", &.{
                        LogField.string("namespace", key.namespace),
                        LogField.string("name", key.name),
                    });
                    const removed = self.store.remove(io, key);
                    if (removed) |old_entry| {
                        for (self.handlers.items) |h| h.onDelete(io, &old_entry.object);
                        old_entry.release();
                    }
                    // Free the watch event's arena (the deleted object data).
                    parsed.deinit();
                    self.metrics.watch_events_total.inc();
                    self.metrics.store_object_count.set(@floatFromInt(self.store.len(io)));
                },
                .bookmark, .api_error => {
                    // Should not reach here; reflector handles these.
                    parsed.deinit();
                },
            }
        }

        fn dispatchInitialAdds(self: *Self, io: std.Io) void {
            const result = self.store.list(self.allocator, io) catch {
                self.logger.err("dispatchInitialAdds failed: OOM listing store", &.{});
                return self.abortSyncAndRelist(io);
            };
            defer result.release();

            for (result.entries) |entry| {
                for (self.handlers.items) |h| h.onAdd(io, &entry.object, true);
            }
        }

        fn clearStaging(self: *Self) void {
            for (self.staging.items) |item| {
                item.arena.deinit();
                self.allocator.destroy(item.arena);
            }
            self.staging.clearRetainingCapacity();
        }

        /// Free a standalone slice of ReplaceItems, deinitializing each arena.
        fn freeReplaceItems(self: *Self, items: []StoreT.ReplaceItem) void {
            for (items) |item| {
                item.arena.deinit();
                self.allocator.destroy(item.arena);
            }
            self.allocator.free(items);
        }

        /// Abort the current sync and force the reflector to re-list.
        /// Clears staging so the next list cycle starts fresh.
        /// If forceRelist itself fails (deep OOM), sets sync_failed so
        /// remaining pages from the old list are discarded.
        fn abortSyncAndRelist(self: *Self, io: std.Io) void {
            self.clearStaging();
            self.reflector.forceRelist(io) catch {
                self.logger.err("forceRelist failed: OOM setting resource version", &.{});
                self.sync_failed.store(true, .release);
                return;
            };
        }
    };
}
