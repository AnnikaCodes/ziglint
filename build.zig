const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) !void {
    const is_release = b.option(bool, "no-git-hash", "Omit Git commit hash (intended for release builds)") orelse false;

    const build_options = b.addOptions();
    if (is_release) {
        build_options.addOption(?[]const u8, "GIT_COMMIT_HASH", null);
    } else {
        const git_result = try std.ChildProcess.exec(.{
            .allocator = b.allocator,
            .argv = &.{ "git", "rev-parse", "--short", "HEAD" },
        });
        // drop the last character (newline)
        build_options.addOption(?[]const u8, "GIT_COMMIT_HASH", git_result.stdout[0 .. git_result.stdout.len - 1]);
    }

    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "ziglint",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.addOptions("comptime_build", build_options);

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

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const analysis_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/analysis.zig" },
        .target = target,
        .optimize = optimize,
    });
    const semver_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/semver.zig" },
        .target = target,
        .optimize = optimize,
    });
    const gitignore_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/gitignore.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_analysis_tests = b.addRunArtifact(analysis_tests);
    const run_semver_tests = b.addRunArtifact(semver_tests);
    const run_gitignore_tests = b.addRunArtifact(gitignore_tests);

    // Creates a step to run the testcases/run.zig unit test runner
    const integration_tests = b.addExecutable(.{
        .root_source_file = .{ .path = "testcases/run.zig" },
        .name = "integration_test",
        .target = target,
        .optimize = optimize,
    });
    integration_tests.step.dependOn(b.getInstallStep());
    const run_integration_tests = b.addRunArtifact(integration_tests);
    const ziglint_path = try std.fs.path.join(b.allocator, &.{ b.exe_dir, "ziglint" });

    run_integration_tests.addArgs(&.{ziglint_path});
    run_integration_tests.cwd = "testcases";

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_integration_tests.step);
    test_step.dependOn(&run_analysis_tests.step);
    test_step.dependOn(&run_semver_tests.step);
    test_step.dependOn(&run_gitignore_tests.step);
}
