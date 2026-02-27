# kube-zig

A Kubernetes client written in [Zig](https://ziglang.org). It provides code generation from the Kubernetes OpenAPI specification, type-safe struct definitions, an HTTP client wrapper, and an orchestrator that performs CRUD operations on Kubernetes resources.

The project generates Zig types from the Kubernetes OpenAPI spec and uses them to interact with a `kubectl proxy` endpoint. No external dependencies are required beyond the Zig standard library.

## Getting Started

### Download the Kubernetes OpenAPI spec

The spec file (`spec/swagger.json`) is not committed to the repository. Download it with:

```sh
zig build fetch-spec
```

By default this downloads the spec for the version pinned in `build.zig`. To fetch a different version:

```sh
zig build fetch-spec -Dk8s-version=v1.30.0
zig build fetch-spec -Dk8s-version=latest    # resolves the latest release via the GitHub API
```

### Generate types from the OpenAPI spec

```sh
zig build generate
```

This downloads `spec/swagger.json` (if not already present) and emits `generated/types.zig` containing typed struct definitions for core Kubernetes types (Pod, Deployment, Service, etc.). The `-Dk8s-version` option is also supported here.

### Build

```sh
zig build
```

### Test

```sh
zig build test
```

This runs three test suites:
- Unit tests for generator helpers (name extraction, keyword detection, quoting logic)
- Compile-time type validation tests (type existence, shape, nested references)
- JSON round-trip tests with fixture files (parsing real Kubernetes resource JSON)

To generate test coverage with [kcov](https://github.com/SimonKagworths/kcov):

```sh
zig build test -Dcoverage=true
```

Results are written to `kcov-output/`.

### Run the examples

All examples require a running `kubectl proxy`:

```sh
kubectl proxy &
```

| Command | Description |
|---------|-------------|
| `zig build run-cluster-health` | Lists all nodes with system info, conditions, capacity vs allocatable resources, and a healthy/unhealthy summary. |
| `zig build run-custom-resource` | Defines a CronTab CRD type with `resource_meta` and performs typed CRUD using `Api(T)`. |
| `zig build run-deploy-and-expose` | Creates an nginx Deployment and a ClusterIP Service, verifies both through the API, then cleans up. |
| `zig build run-dynamic-resource` | Uses `DynamicApi` with runtime `ResourceMeta` to perform CRUD on a CRD without type definitions. |
| `zig build run-informer-pods` | Watches pods using the Informer pattern, maintaining a local cache that stays in sync via list+watch with add/update/delete callbacks. |
| `zig build run-inventory` | Queries several resource types (Deployments, StatefulSets, DaemonSets, Services, ConfigMaps, Secrets, Jobs) in a namespace and prints a summary table with per-kind details. |
| `zig build run-watch-pods` | Streams pod watch events (ADDED, MODIFIED, DELETED, BOOKMARK) in real time. |

### Working with Custom Resource Definitions (CRDs)

Kube-zig supports two approaches for working with CRDs:

- **Typed (`Api(T)`)**: Define a Zig struct with a `resource_meta` declaration (group, version, resource, namespaced, list_kind) and use `Api(T)` for compile-time type safety and structured field access. Best when you know the CRD schema at compile time. See [`examples/custom_resource.zig`](examples/custom_resource.zig).

- **Dynamic (`DynamicApi`)**: Provide a runtime `ResourceMeta` (no `list_kind` needed) and work with `std.json.Value` responses. Best for generic tooling, discovery-based workflows, or CRDs whose schema is not known at compile time. See [`examples/dynamic_resource.zig`](examples/dynamic_resource.zig).
