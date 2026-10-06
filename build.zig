const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    // This creates a "module", which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Every executable or library we compile will be based on one or more modules.
    const mod = b.addModule("reverb", .{
        // `root_source_file` is the Zig "entry point" of the module. If a module
        // only contains e.g. external object files, you can make this `null`.
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // the executable from your call to b.addExecutable(...)

    const loom = b.dependency("loom", .{
        .target = target,
        .optimize = optimize,
    });

    const loom_mod = loom.module("loom");
    mod.addImport("loom", loom_mod);

    // // We will also create a module for our other entry point, 'main.zig'.
    const exe_mod = b.createModule(.{
        // `root_source_file` is the Zig "entry point" of the module. If a module
        // only contains e.g. external object files, you can make this `null`.
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "reverb", .module = mod },
            .{ .name = "loom", .module = loom_mod },
        },
    });

    // This creates another `std.Build.Step.Compile`, but this one builds an executable
    // rather than a static library.
    const exe = b.addExecutable(.{
        .name = "reverb",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // ------------------------------------------------------------------
    // The README quickstart, compiled as part of the normal build so the
    // first code a reader runs cannot silently rot.
    // ------------------------------------------------------------------
    const readme_example = b.addExecutable(.{
        .name = "readme_quickstart",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/readme_quickstart.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "reverb", .module = mod },
            },
        }),
    });
    const check_readme = b.step("check-readme", "Compile the README quickstart");
    check_readme.dependOn(&readme_example.step);

    // ------------------------------------------------------------------
    // Tests.
    //
    // Zig only collects `test` blocks from the *root* file of a test
    // binary, so every file carrying tests has to be reachable through an
    // explicit `_ = @import(...)` from the root. `src/root.zig` does that
    // for the unit tests; `tests/integration.zig` drives a real server
    // over real sockets.
    // ------------------------------------------------------------------
    const unit_tests = b.addTest(.{
        .name = "unit",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "loom", .module = loom_mod },
            },
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    run_unit_tests.has_side_effects = true;

    const integration_tests = b.addTest(.{
        .name = "integration",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "reverb", .module = mod },
                .{ .name = "loom", .module = loom_mod },
            },
        }),
    });
    const run_integration_tests = b.addRunArtifact(integration_tests);
    run_integration_tests.has_side_effects = true;

    const test_unit_step = b.step("test-unit", "Run unit tests");
    test_unit_step.dependOn(&run_unit_tests.step);

    const test_integration_step = b.step("test-integration", "Run integration tests");
    test_integration_step.dependOn(&run_integration_tests.step);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_integration_tests.step);
}
