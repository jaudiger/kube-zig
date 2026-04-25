// Deploy & Expose: creates an nginx Deployment and a ClusterIP Service,
// verifies both resources through the API, then cleans up.

const std = @import("std");
const kube_zig = @import("kube-zig");
const k8s = kube_zig.types;

const app_name = "hello-kube-zig";
const app_image = "nginx:1.28-alpine";
const app_port: i32 = 80;
const service_port: i32 = 8080;
const replicas: i32 = 2;

const DeployApi = kube_zig.Api(k8s.AppsV1Deployment);
const ServiceApi = kube_zig.Api(k8s.CoreV1Service);

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug_allocator.deinit() == .ok);
    const allocator = debug_allocator.allocator();

    const config = kube_zig.ProxyConfig.init(init.environ_map);
    var text_logger = kube_zig.TextStdoutLogger.init(io, .info);

    var client = try kube_zig.Client.init(allocator, io, config.base_url, .{ .logger = text_logger.logger() });
    defer client.deinit(io);

    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    const w = &stdout.interface;
    defer w.flush() catch {};

    const namespace = config.namespace;

    try w.print("Deploy & Expose Example\n", .{});
    try w.print("Connecting to: {s}\n\n", .{config.base_url});
    try w.print("App: {s}  Image: {s}  Replicas: {d}\n", .{ app_name, app_image, replicas });
    try w.print("Service: {s} port {d} -> container port {d}\n\n", .{ app_name, service_port, app_port });

    // Build shared labels: {"app": "hello-kube-zig"}
    var label_map: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    defer label_map.deinit(allocator);
    try label_map.put(allocator, "app", app_name);
    const labels: std.json.ArrayHashMap([]const u8) = .{ .map = label_map };

    const deployments = DeployApi.init(&client, client.context(), namespace);
    const services = ServiceApi.init(&client, client.context(), namespace);

    // 1. Apply the Deployment (idempotent create-or-update)
    try w.print("-- Applying Deployment --\n", .{});

    const dep_result = deployments.apply(io, app_name, .{
        .metadata = .{
            .name = app_name,
            .namespace = namespace,
            .labels = labels,
        },
        .spec = .{
            .replicas = replicas,
            .selector = .{ .matchLabels = labels },
            .template = .{
                .metadata = .{ .labels = labels },
                .spec = .{
                    .containers = &.{.{
                        .name = app_name,
                        .image = app_image,
                        .ports = &.{.{ .containerPort = app_port }},
                    }},
                },
            },
        },
    }, .{ .field_manager = "deploy-and-expose-example", .force = true }) catch |err| {
        try w.print("  Failed to apply deployment: {}\n", .{err});
        return;
    };
    const dep_parsed = dep_result.value() catch |err| {
        try w.print("  Failed to apply deployment: {}\n", .{err});
        return;
    };
    defer dep_parsed.deinit();

    const dep_name = kube_zig.metadata.getName(k8s.AppsV1Deployment, dep_parsed.value) orelse "?";
    try w.print("  Applied deployment: {s}\n\n", .{dep_name});

    // 2. Apply the Service (idempotent create-or-update)
    try w.print("-- Applying Service --\n", .{});

    const svc_result = services.apply(io, app_name, .{
        .metadata = .{
            .name = app_name,
            .namespace = namespace,
            .labels = labels,
        },
        .spec = .{
            .type = "ClusterIP",
            .selector = labels,
            .ports = &.{.{
                .name = "http",
                .port = service_port,
                .targetPort = .{ .int = app_port },
                .protocol = "TCP",
            }},
        },
    }, .{ .field_manager = "deploy-and-expose-example", .force = true }) catch |err| {
        try w.print("  Failed to apply service: {}\n", .{err});
        deleteResource(DeployApi, deployments, io, "Deployment", w);
        return;
    };
    const svc_parsed = svc_result.value() catch |err| {
        try w.print("  Failed to apply service: {}\n", .{err});
        deleteResource(DeployApi, deployments, io, "Deployment", w);
        return;
    };
    defer svc_parsed.deinit();

    const svc_name = kube_zig.metadata.getName(k8s.CoreV1Service, svc_parsed.value) orelse "?";
    const cluster_ip = if (svc_parsed.value.spec) |s| (s.clusterIP orelse "pending") else "?";
    try w.print("  Applied service: {s}  ClusterIP: {s}\n\n", .{ svc_name, cluster_ip });

    // 3. Verify: fetch the deployment and service back
    try w.print("-- Verifying resources --\n", .{});

    const dep_get_result = deployments.get(io, app_name) catch |err| {
        try w.print("  Failed to get deployment: {}\n", .{err});
        cleanupAll(deployments, services, io, w);
        return;
    };
    const dep_get = dep_get_result.value() catch |err| {
        try w.print("  Failed to get deployment: {}\n", .{err});
        cleanupAll(deployments, services, io, w);
        return;
    };
    defer dep_get.deinit();

    const desired = if (dep_get.value.spec) |s| (s.replicas orelse 0) else 0;
    const ready_replicas = if (dep_get.value.status) |s| (s.readyReplicas orelse 0) else 0;
    try w.print("  Deployment {s}: {d}/{d} replicas ready\n", .{ app_name, ready_replicas, desired });

    const svc_get_result = services.get(io, app_name) catch |err| {
        try w.print("  Failed to get service: {}\n", .{err});
        cleanupAll(deployments, services, io, w);
        return;
    };
    const svc_get = svc_get_result.value() catch |err| {
        try w.print("  Failed to get service: {}\n", .{err});
        cleanupAll(deployments, services, io, w);
        return;
    };
    defer svc_get.deinit();

    const svc_ip = if (svc_get.value.spec) |s| (s.clusterIP orelse "pending") else "?";
    try w.print("  Service {s}: ClusterIP={s}\n", .{ app_name, svc_ip });

    if (svc_get.value.spec) |spec| {
        if (spec.ports) |ports| {
            for (ports) |p| {
                try w.print("    Port: {s} {d}/{s}\n", .{
                    p.name orelse "?",
                    p.port,
                    p.protocol orelse "TCP",
                });
            }
        }
    }

    try w.print("\n  Access inside cluster: http://{s}:{d}\n\n", .{ svc_ip, service_port });

    // 4. Clean up
    cleanupAll(deployments, services, io, w);

    try w.print("Done.\n", .{});
}

/// Generic cleanup: delete a named resource through any Api(T) instance.
fn deleteResource(comptime ApiT: type, api: ApiT, io: std.Io, comptime label: []const u8, w: *std.Io.Writer) void {
    w.print("-- Deleting " ++ label ++ " {s} --\n", .{app_name}) catch return;
    const result = api.delete(io, app_name, .{}) catch |err| {
        w.print("  Failed to delete " ++ label ++ ": {}\n", .{err}) catch {};
        return;
    };
    result.deinit();
    w.print("  Deleted.\n", .{}) catch {};
}

fn cleanupAll(deployments: DeployApi, services: ServiceApi, io: std.Io, w: *std.Io.Writer) void {
    deleteResource(DeployApi, deployments, io, "Deployment", w);
    deleteResource(ServiceApi, services, io, "Service", w);
}
