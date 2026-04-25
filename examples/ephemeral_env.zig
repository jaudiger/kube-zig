// Ephemeral Environment Controller: watches EphemeralEnv custom resources and
// provisions preview environments (Namespace + ConfigMap + Deployment + Service)
// with automatic TTL-based cleanup.
//
// This example exercises the full kube-zig controller framework: Controller(T)
// with secondary watches, ControllerManager, ProbeServer, EventRecorder,
// finalizers, metadata helpers, signal handling, structured logging,
// server-side apply (SSA), conditions, and owner references.
//
// Prerequisites:
//   1. A running cluster with `kubectl proxy` on :8001
//   2. The EphemeralEnv CRD installed:
//
//      kubectl apply -f - <<'EOF'
//      apiVersion: apiextensions.k8s.io/v1
//      kind: CustomResourceDefinition
//      metadata:
//        name: ephemeralenvs.platform.example.com
//      spec:
//        group: platform.example.com
//        versions:
//          - name: v1alpha1
//            served: true
//            storage: true
//            schema:
//              openAPIV3Schema:
//                type: object
//                properties:
//                  spec:
//                    type: object
//                    properties:
//                      ttlMinutes:
//                        type: integer
//                        minimum: 1
//                        maximum: 1440
//                      image:
//                        type: string
//                      replicas:
//                        type: integer
//                        minimum: 1
//                      port:
//                        type: integer
//                      envVars:
//                        type: object
//                        additionalProperties:
//                          type: string
//                  status:
//                    type: object
//                    properties:
//                      phase:
//                        type: string
//                        enum: [Provisioning, Ready, Expiring, Terminated]
//                      message:
//                        type: string
//                      namespaceName:
//                        type: string
//                      conditions:
//                        type: array
//                        items:
//                          type: object
//                          required: [type, status]
//                          properties:
//                            type:
//                              type: string
//                            status:
//                              type: string
//                              enum: ["True", "False", "Unknown"]
//                            reason:
//                              type: string
//                            message:
//                              type: string
//                            lastTransitionTime:
//                              type: string
//            subresources:
//              status: {}
//        scope: Cluster
//        names:
//          plural: ephemeralenvs
//          singular: ephemeralenv
//          kind: EphemeralEnv
//          shortNames:
//            - eenv
//      EOF
//
// Usage:
//   kubectl proxy &
//   zig build run-ephemeral-env
//
//   # In another terminal, create an EphemeralEnv:
//   kubectl apply -f - <<'EOF'
//   apiVersion: platform.example.com/v1alpha1
//   kind: EphemeralEnv
//   metadata:
//     name: preview-42
//   spec:
//     ttlMinutes: 5
//     image: nginx:latest
//     replicas: 2
//     port: 80
//   EOF
//
//   kubectl get ephemeralenvs
//   kubectl get ns eenv-preview-42
//   kubectl get deploy -n eenv-preview-42
//   # Wait 5 minutes, namespace auto-deletes

const std = @import("std");
const kube_zig = @import("kube-zig");
const k8s = kube_zig.types;

const LogField = kube_zig.LogField;

const finalizer_name = "platform.example.com/cleanup";
const field_manager = "ephemeral-env-controller";

// CRD type definitions
pub const EphemeralEnvList = struct {
    apiVersion: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    metadata: ?ListMetadata = null,
    items: []const EphemeralEnv = &.{},
};

pub const ListMetadata = struct {
    resourceVersion: ?[]const u8 = null,
    @"continue": ?[]const u8 = null,
};

pub const EphemeralEnv = struct {
    pub const resource_meta = .{
        .group = "platform.example.com",
        .version = "v1alpha1",
        .kind = "EphemeralEnv",
        .resource = "ephemeralenvs",
        .namespaced = false,
        .list_kind = EphemeralEnvList,
    };

    apiVersion: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    metadata: ?Metadata = null,
    spec: ?EphemeralEnvSpec = null,
    status: ?EphemeralEnvStatus = null,
};

pub const Metadata = struct {
    name: ?[]const u8 = null,
    namespace: ?[]const u8 = null,
    resourceVersion: ?[]const u8 = null,
    uid: ?[]const u8 = null,
    creationTimestamp: ?[]const u8 = null,
    deletionTimestamp: ?[]const u8 = null,
    labels: ?std.json.ArrayHashMap([]const u8) = null,
    annotations: ?std.json.ArrayHashMap([]const u8) = null,
    finalizers: ?[]const []const u8 = null,
    ownerReferences: ?[]const OwnerRef = null,
    generation: ?i64 = null,
};

pub const OwnerRef = struct {
    apiVersion: []const u8,
    kind: []const u8,
    name: []const u8,
    uid: []const u8,
    controller: ?bool = null,
    blockOwnerDeletion: ?bool = null,
};

pub const EphemeralEnvSpec = struct {
    ttlMinutes: ?i32 = null,
    image: ?[]const u8 = null,
    replicas: ?i32 = null,
    port: ?i32 = null,
    envVars: ?std.json.ArrayHashMap([]const u8) = null,
};

pub const EphemeralEnvStatus = struct {
    phase: ?[]const u8 = null,
    message: ?[]const u8 = null,
    conditions: ?[]const Condition = null,
    namespaceName: ?[]const u8 = null,
};

pub const Condition = struct {
    type: []const u8,
    status: []const u8,
    reason: ?[]const u8 = null,
    message: ?[]const u8 = null,
    lastTransitionTime: ?[]const u8 = null,
};

// Reconciler context
const EphemeralEnvApi = kube_zig.Api(EphemeralEnv);
const NamespaceApi = kube_zig.Api(k8s.CoreV1Namespace);
const ConfigMapApi = kube_zig.Api(k8s.CoreV1ConfigMap);
const DeployApi = kube_zig.Api(k8s.AppsV1Deployment);
const ServiceApi = kube_zig.Api(k8s.CoreV1Service);

const ReconcileCtx = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    client: *kube_zig.Client,
    store: kube_zig.Store(EphemeralEnv).View,
    recorder: kube_zig.EventRecorder,
    logger: kube_zig.Logger,

    fn reconcile(self: *ReconcileCtx, key: kube_zig.ObjectKey, ctx: kube_zig.Context) anyerror!kube_zig.ReconcileResult {
        _ = ctx;
        const env_name = key.name;
        self.logger.info("reconciling", &.{LogField.string("name", env_name)});

        // Deep-clone from cache so the lock is released before HTTP calls.
        const result = self.store.getCloned(self.allocator, self.io, key) catch |err| {
            self.logger.warn("failed to clone object from cache", &.{LogField.err("error", err)});
            return .{ .requeue = true };
        } orelse {
            self.logger.info("object not found in cache, skipping", &.{LogField.string("name", env_name)});
            return .{};
        };
        defer result.deinit();
        const obj = &result.object;

        const meta = obj.metadata orelse return .{};
        const uid = meta.uid orelse "";

        const api = EphemeralEnvApi.init(self.client, self.client.context(), null);

        // Handle deletion (finalizer cleanup).
        if (meta.deletionTimestamp != null) {
            return self.handleDeletion(api, env_name, uid);
        }

        // Only call the API-server GET+PUT when the cached object lacks the
        // finalizer.  On steady-state re-reconciles the finalizer is present in
        // the cache, so this avoids a round-trip every cycle.
        if (!kube_zig.finalizers.hasFinalizer(&meta, finalizer_name)) {
            kube_zig.finalizers.ensureFinalizer(EphemeralEnv, self.io, api, self.allocator, env_name, finalizer_name) catch |err| {
                self.logger.warn("failed to ensure finalizer", &.{LogField.err("error", err)});
                return .{ .requeue = true };
            };
        }

        // Compute owner reference for child resources.
        const owner_ref: ?k8s.MetaV1OwnerReference = if (kube_zig.owner_ref.ownerReferenceFor(EphemeralEnv, obj.*)) |ref|
            toK8sOwnerRef(ref)
        else
            null;

        const ns_name = try self.allocNsName(env_name);
        defer self.allocator.free(ns_name);
        const spec = obj.spec orelse return .{};

        const ttl_minutes: i64 = spec.ttlMinutes orelse 30;
        const ttl_seconds = ttl_minutes * 60;

        // Derive creation time from the immutable creationTimestamp set by the
        // API server.  No annotation PATCH needed, which avoids a CR write that
        // would generate a watch event and trigger a dirty-flag re-enqueue.
        const created_epoch = kube_zig.time.parseTimestamp(meta.creationTimestamp orelse "") orelse {
            self.logger.warn("failed to parse creationTimestamp", &.{LogField.string("name", env_name)});
            return .{ .requeue_after_ns = 30 * std.time.ns_per_s };
        };

        const now: i64 = @intCast(@divTrunc(std.Io.Clock.real.now(self.io).nanoseconds, std.time.ns_per_s));
        const elapsed = now - created_epoch;

        // TTL expired; skip provisioning, go straight to cleanup.
        if (elapsed >= ttl_seconds) {
            self.logger.info("TTL expired, cleaning up", &.{LogField.string("name", env_name)});

            // Skip updatePhase here because the CR is about to be deleted, so
            // a status PATCH would only generate a watch event that causes
            // a redundant re-reconcile via the dirty flag.

            const ns_api = NamespaceApi.init(self.client, self.client.context(), null);
            del: {
                const del_result = ns_api.delete(self.io, ns_name, .{}) catch {
                    self.logger.warn("failed to delete namespace during TTL expiry", &.{});
                    break :del;
                };
                del_result.deinit();
            }

            // Delete the EphemeralEnv CR itself so the loop terminates.
            // This sets deletionTimestamp; the next reconcile will enter
            // handleDeletion which removes the finalizer.
            cr_del: {
                const cr_del_result = api.delete(self.io, env_name, .{}) catch {
                    self.logger.warn("failed to delete EphemeralEnv CR during TTL expiry", &.{});
                    break :cr_del;
                };
                cr_del_result.deinit();
            }

            self.recorder.event(
                self.io,
                objRef(env_name, uid),
                null,
                .normal,
                "TTLExpired",
                "Environment TTL expired, namespace deleted",
            );

            return .{};
        }

        const current_phase = if (obj.status) |s| s.phase orelse "" else "";

        // Already fully provisioned, nothing to do.  Returning without
        // any API calls avoids generating watch MODIFY events on the CR,
        // which would set the work-queue dirty flag and bypass the
        // requeue_after delay.
        if (std.mem.eql(u8, current_phase, "Ready")) {
            const remaining: u64 = @intCast(@max(0, ttl_seconds - elapsed));
            self.logger.info("environment ready", &.{ LogField.string("name", env_name), LogField.uint("remaining_s", remaining) });
            return .{ .requeue_after_ns = remaining * std.time.ns_per_s };
        }

        // Not yet ready; provision child resources.
        if (!std.mem.eql(u8, current_phase, "Provisioning")) {
            updatePhase(self.allocator, self.io, self.logger, api, env_name, "Provisioning", ns_name) catch |err| {
                self.logger.warn("failed to update status to Provisioning", &.{LogField.err("error", err)});
            };
        }

        try self.ensureNamespace(ns_name, env_name, owner_ref);

        if (spec.envVars != null) {
            try self.ensureConfigMap(ns_name, env_name, owner_ref);
        }

        try self.ensureDeployment(ns_name, env_name, spec, owner_ref);

        try self.ensureService(ns_name, env_name, spec, owner_ref);

        updatePhase(self.allocator, self.io, self.logger, api, env_name, "Ready", ns_name) catch |err| {
            self.logger.warn("failed to update status to Ready", &.{LogField.err("error", err)});
        };

        const remaining: u64 = @intCast(@max(0, ttl_seconds - elapsed));
        self.logger.info("environment ready", &.{ LogField.string("name", env_name), LogField.uint("remaining_s", remaining) });

        return .{ .requeue_after_ns = remaining * std.time.ns_per_s };
    }

    // Helpers
    fn allocNsName(self: *ReconcileCtx, env_name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "eenv-{s}", .{env_name});
    }

    fn handleDeletion(
        self: *ReconcileCtx,
        api: EphemeralEnvApi,
        env_name: []const u8,
        uid: []const u8,
    ) !kube_zig.ReconcileResult {
        self.logger.info("handling deletion", &.{LogField.string("name", env_name)});

        // Delete the child namespace.
        const ns_name = try self.allocNsName(env_name);
        defer self.allocator.free(ns_name);

        const ns_api = NamespaceApi.init(self.client, self.client.context(), null);
        del: {
            const del_result = ns_api.delete(self.io, ns_name, .{}) catch {
                self.logger.warn("failed to delete namespace during cleanup (may already be gone)", &.{});
                break :del;
            };
            del_result.deinit();
        }

        // Remove the finalizer (high-level helper: GET+PUT with automatic
        // 409 retry via kube_zig.retryOnConflict).
        kube_zig.finalizers.removeFinalizerAndUpdate(EphemeralEnv, self.io, api, env_name, finalizer_name) catch |err| {
            self.logger.warn("failed to remove finalizer", &.{ LogField.string("name", env_name), LogField.err("error", err) });
            return .{ .requeue = true };
        };

        self.recorder.event(
            self.io,
            objRef(env_name, uid),
            null,
            .normal,
            "Cleanup",
            "Deleted namespace for environment",
        );

        self.logger.info("finalizer removed, deletion complete", &.{LogField.string("name", env_name)});
        return .{};
    }

    fn ensureNamespace(
        self: *ReconcileCtx,
        ns_name: []const u8,
        env_name: []const u8,
        owner_ref: ?k8s.MetaV1OwnerReference,
    ) !void {
        const ns_api = NamespaceApi.init(self.client, self.client.context(), null);

        var label_map: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
        defer label_map.deinit(self.allocator);
        try label_map.put(self.allocator, "managed-by", "ephemeral-env-controller");
        try label_map.put(self.allocator, "ephemeral-env", env_name);
        const labels: std.json.ArrayHashMap([]const u8) = .{ .map = label_map };

        // SSA apply: creates the namespace if absent, updates owned fields otherwise.
        const ns = k8s.CoreV1Namespace{
            .metadata = .{
                .name = ns_name,
                .labels = labels,
                .ownerReferences = if (owner_ref) |ref| &.{ref} else null,
            },
        };

        const result = try ns_api.apply(self.io, ns_name, ns, .{ .field_manager = field_manager, .force = true });
        switch (result) {
            .ok => |parsed| parsed.deinit(),
            .api_error => |err_resp| {
                err_resp.deinit();
                self.logger.warn("namespace apply returned API error", &.{LogField.string("name", ns_name)});
            },
        }
    }

    fn ensureConfigMap(
        self: *ReconcileCtx,
        ns_name: []const u8,
        env_name: []const u8,
        owner_ref: ?k8s.MetaV1OwnerReference,
    ) !void {
        const cm_name = try std.fmt.allocPrint(self.allocator, "{s}-config", .{env_name});
        defer self.allocator.free(cm_name);

        const cm_api = ConfigMapApi.init(self.client, self.client.context(), ns_name);

        const cm = k8s.CoreV1ConfigMap{
            .metadata = .{
                .name = cm_name,
                .namespace = ns_name,
                .ownerReferences = if (owner_ref) |ref| &.{ref} else null,
            },
        };

        const result = try cm_api.apply(self.io, cm_name, cm, .{ .field_manager = field_manager, .force = true });
        switch (result) {
            .ok => |p| p.deinit(),
            .api_error => |e| e.deinit(),
        }
    }

    fn ensureDeployment(
        self: *ReconcileCtx,
        ns_name: []const u8,
        env_name: []const u8,
        spec: EphemeralEnvSpec,
        owner_ref: ?k8s.MetaV1OwnerReference,
    ) !void {
        const image = spec.image orelse "nginx:latest";
        const replicas_val = spec.replicas orelse 1;
        const port_val = spec.port orelse 80;

        const deploy_api = DeployApi.init(self.client, self.client.context(), ns_name);

        var label_map: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
        defer label_map.deinit(self.allocator);
        try label_map.put(self.allocator, "app", env_name);
        const labels: std.json.ArrayHashMap([]const u8) = .{ .map = label_map };

        // SSA apply: creates or updates the deployment idempotently.
        // Replaces the previous get+create/patch pattern with a single call.
        const deploy = k8s.AppsV1Deployment{
            .metadata = .{
                .name = env_name,
                .namespace = ns_name,
                .labels = labels,
                .ownerReferences = if (owner_ref) |ref| &.{ref} else null,
            },
            .spec = .{
                .replicas = replicas_val,
                .selector = .{ .matchLabels = labels },
                .template = .{
                    .metadata = .{ .labels = labels },
                    .spec = .{
                        .containers = &.{.{
                            .name = env_name,
                            .image = image,
                            .ports = &.{.{ .containerPort = port_val }},
                        }},
                    },
                },
            },
        };

        const result = try deploy_api.apply(self.io, env_name, deploy, .{ .field_manager = field_manager, .force = true });
        switch (result) {
            .ok => |p| p.deinit(),
            .api_error => |e| {
                e.deinit();
                self.logger.warn("deployment apply returned API error", &.{LogField.string("name", env_name)});
            },
        }
    }

    fn ensureService(
        self: *ReconcileCtx,
        ns_name: []const u8,
        env_name: []const u8,
        spec: EphemeralEnvSpec,
        owner_ref: ?k8s.MetaV1OwnerReference,
    ) !void {
        const port_val = spec.port orelse 80;

        const svc_api = ServiceApi.init(self.client, self.client.context(), ns_name);

        var label_map: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
        defer label_map.deinit(self.allocator);
        try label_map.put(self.allocator, "app", env_name);
        const selector: std.json.ArrayHashMap([]const u8) = .{ .map = label_map };

        // SSA apply: creates or updates the service idempotently.
        const svc = k8s.CoreV1Service{
            .metadata = .{
                .name = env_name,
                .namespace = ns_name,
                .ownerReferences = if (owner_ref) |ref| &.{ref} else null,
            },
            .spec = .{
                .type = "ClusterIP",
                .selector = selector,
                .ports = &.{.{
                    .port = port_val,
                    .targetPort = .{ .int = port_val },
                    .protocol = "TCP",
                }},
            },
        };

        const result = try svc_api.apply(self.io, env_name, svc, .{ .field_manager = field_manager, .force = true });
        switch (result) {
            .ok => |p| p.deinit(),
            .api_error => |e| {
                e.deinit();
                self.logger.warn("service apply returned API error", &.{LogField.string("name", env_name)});
            },
        }
    }
};

// Free functions (no self needed)
fn updatePhase(
    allocator: std.mem.Allocator,
    io: std.Io,
    logger: kube_zig.Logger,
    api: EphemeralEnvApi,
    env_name: []const u8,
    phase: []const u8,
    ns_name: []const u8,
) !void {
    // Derive condition values from the phase.
    const is_ready = std.mem.eql(u8, phase, "Ready");
    const condition_status: kube_zig.conditions.ConditionStatus = if (is_ready) .condition_true else .condition_false;
    const reason: []const u8 = if (std.mem.eql(u8, phase, "Ready"))
        "AllResourcesReady"
    else if (std.mem.eql(u8, phase, "Provisioning"))
        "Provisioning"
    else if (std.mem.eql(u8, phase, "Expiring"))
        "TTLExpired"
    else
        "Terminated";

    const message: []const u8 = if (std.mem.eql(u8, phase, "Ready"))
        "Environment is running"
    else if (std.mem.eql(u8, phase, "Provisioning"))
        "Setting up environment resources"
    else if (std.mem.eql(u8, phase, "Expiring"))
        "TTL expired, cleaning up"
    else
        "Environment terminated";

    // Build the "Ready" condition using the conditions helper.
    var ts_buf: [kube_zig.time.Precision.seconds.bufLen()]u8 = undefined;
    const timestamp = kube_zig.time.bufNow(io, .seconds, &ts_buf);

    const new_conditions = try kube_zig.conditions.setCondition(
        Condition,
        null,
        .{ .type = "Ready", .status = condition_status, .reason = reason, .message = message },
        timestamp,
        allocator,
    );
    defer allocator.free(new_conditions);

    // SSA applyStatus: no resourceVersion needed, avoids the 409 Conflict
    // that occurred when the cached rv became stale after earlier updates.
    const status_body = EphemeralEnv{
        .metadata = .{ .name = env_name },
        .status = .{
            .phase = phase,
            .namespaceName = ns_name,
            .message = message,
            .conditions = new_conditions,
        },
    };

    const result = try api.applyStatus(io, env_name, status_body, .{
        .field_manager = field_manager,
        .force = true,
    });
    switch (result) {
        .ok => |parsed| parsed.deinit(),
        .api_error => |err_resp| {
            err_resp.deinit();
            logger.warn("failed to update status", &.{ LogField.string("phase", phase), LogField.string("name", env_name) });
        },
    }
}

fn objRef(env_name: []const u8, uid: []const u8) k8s.CoreV1ObjectReference {
    return .{
        .apiVersion = "platform.example.com/v1alpha1",
        .kind = "EphemeralEnv",
        .name = env_name,
        .uid = uid,
    };
}

/// Convert the library's OwnerReference to the generated MetaV1OwnerReference.
fn toK8sOwnerRef(ref: kube_zig.owner_ref.OwnerReference) k8s.MetaV1OwnerReference {
    return .{
        .apiVersion = ref.apiVersion,
        .kind = ref.kind,
        .name = ref.name,
        .uid = ref.uid,
        .controller = ref.controller,
        .blockOwnerDeletion = ref.blockOwnerDeletion,
    };
}

// Custom namespace mapper
// Maps namespace events back to the owning EphemeralEnv via the
// "ephemeral-env" label. This label-based mapping complements the
// ownerReferences set on child resources.

fn namespaceMapper(_: std.mem.Allocator, obj: *const k8s.CoreV1Namespace) ?kube_zig.ObjectKey {
    const meta = obj.metadata orelse return null;
    const labels = meta.labels orelse return null;
    const env_name = labels.map.get("ephemeral-env") orelse return null;
    return .{ .namespace = "", .name = env_name };
}

// Shutdown context
const ShutdownCtx = struct {
    io: std.Io,
    mgr: *kube_zig.ControllerManager,
    probes: *kube_zig.ProbeServer,
    logger: kube_zig.Logger,

    fn shutdown(self: *ShutdownCtx) void {
        self.logger.info("signal received, shutting down", &.{});
        self.mgr.stop(self.io);
        self.probes.stop(self.io);
    }
};

// Main
pub fn main(init: std.process.Init) !void {
    const io = init.io;

    // Allocator setup.
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug_allocator.deinit() == .ok);
    const allocator = debug_allocator.allocator();

    // Client init via ProxyConfig with structured JSON logging.
    const config = kube_zig.ProxyConfig.init(init.environ_map);
    var text_logger = kube_zig.TextStdoutLogger.init(io, .info);
    const logger = text_logger.logger();

    var client = try kube_zig.Client.init(allocator, io, config.base_url, .{ .logger = logger });
    defer client.deinit(io);

    // Create the controller (cluster-scoped, namespace = null).
    var reconcile_ctx = ReconcileCtx{
        .allocator = allocator,
        .io = io,
        .client = &client,
        .store = undefined, // Set after controller init.
        .recorder = kube_zig.EventRecorder.init(&client, "ephemeral-env-controller", "ephemeral-env-controller"),
        .logger = logger.withScope("ephemeral-env"),
    };

    var ctrl = try kube_zig.Controller(EphemeralEnv).init(allocator, io, &client, client.context(), null, .{
        .reconcile_fn = kube_zig.ReconcileFn.fromTypedCtx(ReconcileCtx, &reconcile_ctx, ReconcileCtx.reconcile),
        .logger = logger,
    });
    defer ctrl.deinit(io);

    // Wire the store into the reconcile context.
    reconcile_ctx.store = ctrl.getStore();

    // Watch secondary: CoreV1Namespace (cluster-scoped) with label-based mapper.
    try ctrl.watchSecondary(io, k8s.CoreV1Namespace, &client, null, .{
        .map_fn = namespaceMapper,
    });

    // Create ControllerManager and add the controller.
    var mgr = kube_zig.ControllerManager.init(allocator, .{ .logger = logger, .client = &client });
    defer mgr.deinit();
    try mgr.add(kube_zig.Runnable.fromController(EphemeralEnv, &ctrl));

    // Create ProbeServer with readiness + liveness checks.
    var probes = try kube_zig.ProbeServer.init(allocator, io, .{ .port = 8080 });
    defer probes.deinit(io);
    try probes.addReadinessCheck(mgr.healthCheck());
    try probes.addLivenessCheck(client.healthCheck());
    try probes.start(io);

    // Setup signal handling.
    var shutdown_ctx = ShutdownCtx{
        .io = io,
        .mgr = &mgr,
        .probes = &probes,
        .logger = logger.withScope("ephemeral-env"),
    };

    const sig_handle = try kube_zig.signal.setupShutdown(io, &.{
        kube_zig.signal.ShutdownCallback.fromTypedCtx(ShutdownCtx, &shutdown_ctx, ShutdownCtx.shutdown),
    });

    // Print startup banner.
    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    const w = &stdout.interface;
    defer w.flush() catch {};

    try w.print("Ephemeral Environment Controller\n", .{});
    try w.print("Connecting to: {s}\n", .{config.base_url});
    try w.print("Probes listening on :8080 (/healthz, /readyz)\n", .{});
    try w.print("Watching EphemeralEnv resources (cluster-scoped)\n", .{});
    try w.print("Press Ctrl+C to stop.\n\n", .{});
    w.flush() catch {};

    // mgr.run() blocks until signal.
    try mgr.run(io);

    // Join signal thread and cleanup.
    sig_handle.thread.join();
    logger.withScope("ephemeral-env").info("controller shut down cleanly", &.{});
}
