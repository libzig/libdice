const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create the libdice module
    const libdice_module = b.createModule(.{
        .root_source_file = b.path("lib/libdice.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Export the module so it can be used by other projects
    _ = b.addModule("libdice", .{
        .root_source_file = b.path("lib/libdice.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Build the library
    const lib = b.addLibrary(.{
        .name = "dice",
        .root_module = libdice_module,
        .linkage = .static,
    });

    b.installArtifact(lib);

    // Unit tests
    const lib_unit_tests = b.addTest(.{
        .root_module = libdice_module,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    // Bootstrap regression subset
    const dual_mode_module = b.createModule(.{
        .root_source_file = b.path("lib/dual_mode_regression_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    dual_mode_module.addImport("libdice", libdice_module);

    const dual_mode_tests = b.addTest(.{
        .root_module = dual_mode_module,
    });
    const run_dual_mode_tests = b.addRunArtifact(dual_mode_tests);

    const dual_mode_step = b.step("test-dual-mode-regression", "Run bootstrap regression tests");
    dual_mode_step.dependOn(&run_dual_mode_tests.step);

    // Examples

    // Smoke server A
    const smoke_server_a_module = b.createModule(.{
        .root_source_file = b.path("examples/smoke_server_a.zig"),
        .target = target,
        .optimize = optimize,
    });
    smoke_server_a_module.addImport("libdice", libdice_module);

    const smoke_server_a = b.addExecutable(.{
        .name = "smoke_server_a",
        .root_module = smoke_server_a_module,
    });
    b.installArtifact(smoke_server_a);

    const run_smoke_server_a = b.addRunArtifact(smoke_server_a);
    const smoke_server_a_step = b.step("run-smoke-server-a", "Run smoke server example A");
    smoke_server_a_step.dependOn(&run_smoke_server_a.step);

    // Smoke client A
    const smoke_client_a_module = b.createModule(.{
        .root_source_file = b.path("examples/smoke_client_a.zig"),
        .target = target,
        .optimize = optimize,
    });
    smoke_client_a_module.addImport("libdice", libdice_module);

    const smoke_client_a = b.addExecutable(.{
        .name = "smoke_client_a",
        .root_module = smoke_client_a_module,
    });
    b.installArtifact(smoke_client_a);

    const run_smoke_client_a = b.addRunArtifact(smoke_client_a);
    const smoke_client_a_step = b.step("run-smoke-client-a", "Run smoke client example A");
    smoke_client_a_step.dependOn(&run_smoke_client_a.step);

    // Smoke server B
    const smoke_server_b_module = b.createModule(.{
        .root_source_file = b.path("examples/smoke_server_b.zig"),
        .target = target,
        .optimize = optimize,
    });
    smoke_server_b_module.addImport("libdice", libdice_module);

    const smoke_server_b = b.addExecutable(.{
        .name = "smoke_server_b",
        .root_module = smoke_server_b_module,
    });
    b.installArtifact(smoke_server_b);

    const run_smoke_server_b = b.addRunArtifact(smoke_server_b);
    const smoke_server_b_step = b.step("run-smoke-server-b", "Run smoke server example B");
    smoke_server_b_step.dependOn(&run_smoke_server_b.step);

    // Smoke client B
    const smoke_client_b_module = b.createModule(.{
        .root_source_file = b.path("examples/smoke_client_b.zig"),
        .target = target,
        .optimize = optimize,
    });
    smoke_client_b_module.addImport("libdice", libdice_module);

    const smoke_client_b = b.addExecutable(.{
        .name = "smoke_client_b",
        .root_module = smoke_client_b_module,
    });
    b.installArtifact(smoke_client_b);

    const run_smoke_client_b = b.addRunArtifact(smoke_client_b);
    const smoke_client_b_step = b.step("run-smoke-client-b", "Run smoke client example B");
    smoke_client_b_step.dependOn(&run_smoke_client_b.step);
}
