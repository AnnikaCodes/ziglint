const std = @import("std");

pub fn build(b: *std.build.Builder) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.

    const mode = b.standardOptimizeOption(.{});

    const git_revision = b.exec(&[_][]const u8{
        "git", "rev-parse", "--short", "HEAD",
    });
    const options = b.addOptions();
    options.addOption([]const u8, "revision", git_revision);
    const exe = b.addExecutable(.{
        .name = "ziglint",
        .root_source_file = .{ .path = "src/main.zig" },
        .optimize = mode,
    });
    // exe.addPackage(std.build.Pkg{ .name = "clap", .source = std.build.FileSource{ .path = "lib/clap/clap.zig" } });
    exe.addIncludePath("lib/clap/clap");
    exe.addOptions("gitrev", options);
    // exe.setTarget(target);
    // exe.setBuildMode(mode);
    _ = b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/analysis.zig" },
        .optimize = mode,
    });

    // exe_tests.setTarget(target);
    // exe_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);
}
