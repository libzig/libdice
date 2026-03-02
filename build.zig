const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const feature_options = b.addOptions();
    feature_options.addOption(bool, "ice_udp", b.option(bool, "ice_udp", "Enable ICE over UDP") orelse true);
    feature_options.addOption(bool, "ice_tcp", b.option(bool, "ice_tcp", "Enable ICE over TCP") orelse false);
    feature_options.addOption(bool, "turn", b.option(bool, "turn", "Enable TURN support") orelse false);
    feature_options.addOption(bool, "turn_tcp", b.option(bool, "turn_tcp", "Enable TURN over TCP support") orelse false);
    feature_options.addOption(bool, "trickle", b.option(bool, "trickle", "Enable Trickle ICE support") orelse true);
    feature_options.addOption(bool, "consent", b.option(bool, "consent", "Enable consent freshness checks") orelse false);
    feature_options.addOption(bool, "reliable", b.option(bool, "reliable", "Enable reliable/bytestream mode") orelse false);
    feature_options.addOption(bool, "upnp", b.option(bool, "upnp", "Enable UPnP integration") orelse false);

    // Create the libdice module
    const libdice_module = b.createModule(.{
        .root_source_file = b.path("lib/libdice.zig"),
        .target = target,
        .optimize = optimize,
    });
    libdice_module.addOptions("build_options", feature_options);

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

    // Optional coturn integration smoke test (requires running coturn)
    const coturn_integration_module = b.createModule(.{
        .root_source_file = b.path("lib/integration/coturn_smoke_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    coturn_integration_module.addImport("libdice", libdice_module);

    const coturn_integration_tests = b.addTest(.{
        .root_module = coturn_integration_module,
    });
    const run_coturn_integration = b.addRunArtifact(coturn_integration_tests);

    const coturn_integration_step = b.step("test-coturn-integration", "Run coturn integration smoke test");
    coturn_integration_step.dependOn(&run_coturn_integration.step);

    // Libnice parity translation suite
    const libnice_parity_module = b.createModule(.{
        .root_source_file = b.path("lib/integration/libnice_parity_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    libnice_parity_module.addImport("libdice", libdice_module);

    const libnice_parity_tests = b.addTest(.{
        .root_module = libnice_parity_module,
    });
    const run_libnice_parity = b.addRunArtifact(libnice_parity_tests);

    const libnice_parity_step = b.step("test-libnice-parity", "Run translated libnice parity tests");
    libnice_parity_step.dependOn(&run_libnice_parity.step);
    test_step.dependOn(&run_libnice_parity.step);

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

    // ICE pump demo
    const ice_pump_demo_module = b.createModule(.{
        .root_source_file = b.path("examples/ice_pump_demo.zig"),
        .target = target,
        .optimize = optimize,
    });
    ice_pump_demo_module.addImport("libdice", libdice_module);

    const ice_pump_demo = b.addExecutable(.{
        .name = "ice_pump_demo",
        .root_module = ice_pump_demo_module,
    });
    b.installArtifact(ice_pump_demo);

    const run_ice_pump_demo = b.addRunArtifact(ice_pump_demo);
    const ice_pump_demo_step = b.step("run-ice-pump-demo", "Run ICE pump demo example");
    ice_pump_demo_step.dependOn(&run_ice_pump_demo.step);

    // ICE timeout demo
    const ice_timeout_demo_module = b.createModule(.{
        .root_source_file = b.path("examples/ice_timeout_demo.zig"),
        .target = target,
        .optimize = optimize,
    });
    ice_timeout_demo_module.addImport("libdice", libdice_module);

    const ice_timeout_demo = b.addExecutable(.{
        .name = "ice_timeout_demo",
        .root_module = ice_timeout_demo_module,
    });
    b.installArtifact(ice_timeout_demo);

    const run_ice_timeout_demo = b.addRunArtifact(ice_timeout_demo);
    const ice_timeout_demo_step = b.step("run-ice-timeout-demo", "Run ICE timeout demo example");
    ice_timeout_demo_step.dependOn(&run_ice_timeout_demo.step);

    // ICE drive demo
    const ice_drive_demo_module = b.createModule(.{
        .root_source_file = b.path("examples/ice_drive_demo.zig"),
        .target = target,
        .optimize = optimize,
    });
    ice_drive_demo_module.addImport("libdice", libdice_module);

    const ice_drive_demo = b.addExecutable(.{
        .name = "ice_drive_demo",
        .root_module = ice_drive_demo_module,
    });
    b.installArtifact(ice_drive_demo);

    const run_ice_drive_demo = b.addRunArtifact(ice_drive_demo);
    const ice_drive_demo_step = b.step("run-ice-drive-demo", "Run ICE drive-loop demo example");
    ice_drive_demo_step.dependOn(&run_ice_drive_demo.step);

    // ICE demo selector
    const ice_demo_selector_module = b.createModule(.{
        .root_source_file = b.path("examples/ice_demo_selector.zig"),
        .target = target,
        .optimize = optimize,
    });
    ice_demo_selector_module.addImport("libdice", libdice_module);

    const ice_demo_selector = b.addExecutable(.{
        .name = "ice_demo_selector",
        .root_module = ice_demo_selector_module,
    });
    b.installArtifact(ice_demo_selector);

    const run_ice_demo_selector = b.addRunArtifact(ice_demo_selector);
    if (b.args) |args| {
        run_ice_demo_selector.addArgs(args);
    }
    const ice_demo_selector_step = b.step("run-ice-demo", "Run ICE demo selector (pump|timeout|drive|sdp)");
    ice_demo_selector_step.dependOn(&run_ice_demo_selector.step);

    // SDP-style signaling demo
    const sdp_example_module = b.createModule(.{
        .root_source_file = b.path("examples/sdp_example.zig"),
        .target = target,
        .optimize = optimize,
    });
    sdp_example_module.addImport("libdice", libdice_module);

    const sdp_example = b.addExecutable(.{
        .name = "sdp_example",
        .root_module = sdp_example_module,
    });
    b.installArtifact(sdp_example);

    const run_sdp_example = b.addRunArtifact(sdp_example);
    const sdp_example_step = b.step("run-sdp-example", "Run SDP-style signaling example");
    sdp_example_step.dependOn(&run_sdp_example.step);

    const run_ice_demo_pump_summary = b.addRunArtifact(ice_demo_selector);
    run_ice_demo_pump_summary.addArgs(&.{ "pump", "--summary" });

    const run_ice_demo_timeout_summary = b.addRunArtifact(ice_demo_selector);
    run_ice_demo_timeout_summary.addArgs(&.{ "timeout", "--summary" });

    const run_ice_demo_drive_summary = b.addRunArtifact(ice_demo_selector);
    run_ice_demo_drive_summary.addArgs(&.{ "drive", "--summary" });

    const run_ice_demo_sdp_summary = b.addRunArtifact(ice_demo_selector);
    run_ice_demo_sdp_summary.addArgs(&.{ "sdp", "--summary" });

    const examples_smoke_step = b.step("test-examples-smoke", "Run nonblocking example smoke scenarios");
    examples_smoke_step.dependOn(&run_ice_demo_pump_summary.step);
    examples_smoke_step.dependOn(&run_ice_demo_timeout_summary.step);
    examples_smoke_step.dependOn(&run_ice_demo_drive_summary.step);
    examples_smoke_step.dependOn(&run_ice_demo_sdp_summary.step);
}
