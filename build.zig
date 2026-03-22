const std = @import("std");

pub fn build(b: *std.Build) void {
    const default_k8s_version = "v1.35.3";

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const coverage = b.option(bool, "coverage", "Generate test coverage with kcov") orelse false;
    const k8s_version = b.option([]const u8, "k8s-version", "Kubernetes version to fetch (default: " ++ default_k8s_version ++ ")") orelse default_k8s_version;

    // Spec Fetcher
    // Downloads spec/swagger.json from the Kubernetes repository
    const fetch_mod = b.createModule(.{
        .root_source_file = b.path("generator/fetch_spec.zig"),
        .target = target,
        .optimize = optimize,
    });
    const fetcher = b.addExecutable(.{
        .name = "fetch-spec",
        .root_module = fetch_mod,
    });
    b.installArtifact(fetcher);

    const fetch_cmd = b.addRunArtifact(fetcher);
    fetch_cmd.setCwd(b.path(".")); // run from project root
    fetch_cmd.addArgs(&.{ k8s_version, "spec/swagger.json" });

    const fetch_step = b.step("fetch-spec", "Download Kubernetes OpenAPI spec");
    fetch_step.dependOn(&fetch_cmd.step);

    // Code Generator
    // Reads spec/swagger.json and emits generated/*.zig
    const gen_mod = b.createModule(.{
        .root_source_file = b.path("generator/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const generator = b.addExecutable(.{
        .name = "k8s-codegen",
        .root_module = gen_mod,
    });
    b.installArtifact(generator);

    const gen_cmd = b.addRunArtifact(generator);
    gen_cmd.setCwd(b.path(".")); // run from project root
    gen_cmd.addArgs(&.{ "spec/swagger.json", "generated" });
    gen_cmd.step.dependOn(&fetch_cmd.step);

    const gen_step = b.step("generate", "Generate Zig types from K8s OpenAPI spec");
    gen_step.dependOn(&gen_cmd.step);

    // CRD Code Generator
    // Reads CRD JSON files and emits typed Zig structs with resource_meta
    const crd_gen_mod = b.createModule(.{
        .root_source_file = b.path("generator/crd_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const crd_generator = b.addExecutable(.{
        .name = "crd-codegen",
        .root_module = crd_gen_mod,
    });
    b.installArtifact(crd_generator);

    const crd_gen_step = b.step("generate-crd", "Generate Zig types from CRD JSON files (pass args: -- <output.zig> <crd1.json> ...)");
    const crd_gen_cmd = b.addRunArtifact(crd_generator);
    crd_gen_cmd.setCwd(b.path("."));
    if (b.args) |args| {
        crd_gen_cmd.addArgs(args);
    }
    crd_gen_step.dependOn(&crd_gen_cmd.step);

    // Types module (standalone, generated)
    const types_mod = b.createModule(.{
        .root_source_file = b.path("generated/types.zig"),
    });

    // Library module (imports types)
    const kube_zig_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .imports = &.{
            .{ .name = "types", .module = types_mod },
        },
    });

    // Example applications
    const examples = .{
        .{ "cluster-health", "examples/cluster_health.zig", "run-cluster-health", "Run the cluster health report via kubectl proxy" },
        .{ "deploy-and-expose", "examples/deploy_and_expose.zig", "run-deploy-and-expose", "Run the deploy & expose example via kubectl proxy" },
        .{ "inventory", "examples/inventory.zig", "run-inventory", "Run the namespace inventory via kubectl proxy" },
        .{ "watch-pods", "examples/watch_pods.zig", "run-watch-pods", "Watch pod events via kubectl proxy" },
        .{ "informer-pods", "examples/informer_pods.zig", "run-informer-pods", "Watch pods via informer with local cache" },
        .{ "custom-resource", "examples/custom_resource.zig", "run-custom-resource", "Typed CRD example using Api(T) with custom resource_meta" },
        .{ "dynamic-resource", "examples/dynamic_resource.zig", "run-dynamic-resource", "Dynamic CRD example using DynamicApi with json.Value" },
        .{ "ephemeral-env", "examples/ephemeral_env.zig", "run-ephemeral-env", "Run the ephemeral environment controller via kubectl proxy" },
    };

    inline for (examples) |ex| {
        const ex_mod = b.createModule(.{
            .root_source_file = b.path(ex[1]),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "kube-zig", .module = kube_zig_mod },
            },
        });

        const ex_exe = b.addExecutable(.{
            .name = ex[0],
            .root_module = ex_mod,
        });
        b.installArtifact(ex_exe);

        const ex_run = b.addRunArtifact(ex_exe);
        ex_run.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            ex_run.addArgs(args);
        }

        const ex_step = b.step(ex[2], ex[3]);
        ex_step.dependOn(&ex_run.step);
    }

    // Tests
    const test_step = b.step("test", "Run all offline tests (unit + compile + roundtrip + api + proxy)");

    // Helper: wrap a test compile step with kcov when -Dcoverage is set.
    const kcov_args: []const ?[]const u8 = &.{
        "kcov", "--include-pattern=generator/,src/", "kcov-output", null,
    };

    // Unit tests for generator helpers
    addTestStep(b, test_step, b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("generator/openapi.zig"),
            .target = target,
            .optimize = optimize,
        }),
    }), coverage, kcov_args);

    // Generated types compile + shape tests
    addTestStep(b, test_step, b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/generated_compile_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "k8s", .module = types_mod },
            },
        }),
    }), coverage, kcov_args);

    // JSON round-trip tests with fixtures
    addTestStep(b, test_step, b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/json_roundtrip_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "k8s", .module = types_mod },
            },
        }),
    }), coverage, kcov_args);

    // Api(T) and resource metadata tests
    addTestStep(b, test_step, b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/api_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "kube-zig", .module = kube_zig_mod },
                .{ .name = "k8s", .module = types_mod },
            },
        }),
    }), coverage, kcov_args);

    // Emitter helper unit tests
    addTestStep(b, test_step, b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("generator/emitter.zig"),
            .target = target,
            .optimize = optimize,
        }),
    }), coverage, kcov_args);

    // CRD emitter unit tests
    addTestStep(b, test_step, b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("generator/crd_emitter.zig"),
            .target = target,
            .optimize = optimize,
        }),
    }), coverage, kcov_args);

    // Library inline tests (all src/ files tested via the kube-zig module).
    // The kube-zig module is rooted at src/root.zig and transitively imports all
    // library source files, so their inline tests are discovered automatically.
    {
        const lib_test_mod = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "types", .module = types_mod },
            },
        });
        addTestStep(b, test_step, b.addTest(.{ .root_module = lib_test_mod }), coverage, kcov_args);
    }

    // Client auth and status code tests
    addTestStep(b, test_step, b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/client_auth_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "kube-zig", .module = kube_zig_mod },
            },
        }),
    }), coverage, kcov_args);

    // Retry integration tests
    addTestStep(b, test_step, b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/retry_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "kube-zig", .module = kube_zig_mod },
            },
        }),
    }), coverage, kcov_args);

    // Rate limit integration tests
    addTestStep(b, test_step, b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/rate_limit_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "kube-zig", .module = kube_zig_mod },
            },
        }),
    }), coverage, kcov_args);

    // Circuit breaker integration tests
    addTestStep(b, test_step, b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/circuit_breaker_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "kube-zig", .module = kube_zig_mod },
            },
        }),
    }), coverage, kcov_args);

    // Mock transport tests (CRUD via Api(T), error handling, watch stream)
    addTestStep(b, test_step, b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/mock_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "kube-zig", .module = kube_zig_mod },
                .{ .name = "k8s", .module = types_mod },
            },
        }),
    }), coverage, kcov_args);

    // Reflector reconnect tests (watch 410, disconnect, backoff, cancellation)
    addTestStep(b, test_step, b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/reflector_reconnect_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "kube-zig", .module = kube_zig_mod },
                .{ .name = "k8s", .module = types_mod },
            },
        }),
    }), coverage, kcov_args);
}

fn addTestStep(
    b: *std.Build,
    test_step: *std.Build.Step,
    test_artifact: *std.Build.Step.Compile,
    cov: bool,
    kcov_args: []const ?[]const u8,
) void {
    if (cov) test_artifact.setExecCmd(kcov_args);
    test_step.dependOn(&b.addRunArtifact(test_artifact).step);
}
