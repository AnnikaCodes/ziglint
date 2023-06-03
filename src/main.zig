//! A configurable linter for Zig

const clap = @import("./lib/clap/clap.zig");
const std = @import("std");
// const git_revision = @import("gitrev").revision;
const analysis = @import("./analysis.zig");

const args = (
    \\--help                                Display this help and exit.
    \\--version                             Output version information and exit.
    \\--max-line-length <u32>               The maximum length of a line of code.
    \\--require-const-pointer-params        Require all pointer parameters to functions be const.
    \\
);

pub fn main() anyerror!void {
    const params = comptime clap.parseParamsComptime(args ++ "<str>...");

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
    }) catch |err| {
        // Report useful error and exit
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer res.deinit();

    // TODO: support getting params from a .ziglintrc file

    if (res.args.version != 0) {
        const stdout = std.io.getStdOut().writer();
        try stdout.writeAll("ziglint from Git commit " ++
            "<TODO: add revision here>" ++
            "\nreport bugs and request features at https://github.com/AnnikaCodes/ziglint\n");
        return;
    } else if (res.args.help != 0 or res.positionals.len == 0) {
        const stdout = std.io.getStdOut().writer();
        try stdout.writeAll(
            \\ziglint: configurable static code analysis for the Zig language
            \\
            \\usage: ziglint [options] <files>
            \\
            \\options:
            \\
        );
        try clap.help(stdout, clap.Help, &params, .{});
        return;
    }

    const analyzer = analysis.ASTAnalyzer.new(
        @field(res.args, "max-line-length") orelse 0,
        @field(res.args, "require-const-pointer-params") != 0,
    );

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) @panic("MEMORY LEAK");
    }

    for (res.positionals) |file| {
        try lint_file(file, allocator, analyzer, true);
    }
}

// Lints a file.
//
// If it's a directory, recursively search it for .zig files and lint them.
fn lint_file(file_name: []const u8, alloc: std.mem.Allocator, analyzer: analysis.ASTAnalyzer, is_top_level: bool) !void {
    const file = std.fs.cwd().openFile(file_name, .{}) catch |err| {
        switch (err) {
            error.AccessDenied => std.log.err("ziglint: access denied: '{s}'", .{file_name}),
            error.DeviceBusy => std.log.err("ziglint: device busy: '{s}'", .{file_name}),
            error.FileNotFound => std.log.err("ziglint: file not found: '{s}'", .{file_name}),
            error.FileTooBig => std.log.err("ziglint: file too big: '{s}'", .{file_name}),

            else => std.log.err("ziglint: error opening '{s}': {}", .{ file_name, err }),
        }

        // exit the program if the *user* specified an inaccessible file;
        // otherwise, just skip it
        if (is_top_level) {
            std.os.exit(1);
        } else {
            return;
        }
    };
    defer file.close();

    const metadata = try file.metadata(); // TODO: is .stat() faster?
    const kind = metadata.kind();
    switch (kind) {
        .file => {
            // lint it
            const contents = try alloc.allocSentinel(u8, metadata.size() + 1, 0);
            defer alloc.free(contents);
            _ = try file.readAll(contents);

            var ast = try std.zig.Ast.parse(alloc, contents, .zig);
            defer ast.deinit(alloc);
            const faults = try analyzer.analyze(alloc, ast);
            defer faults.deinit();

            for (faults.items) |fault| {
                std.debug.print("FAULT: {any}\n", .{fault});
            }
        },
        .directory => {
            // iterate over it
            // todo: is walker faster?
            var dir = try std.fs.cwd().openIterableDir(file_name, .{});
            defer dir.close();

            var iterable = dir.iterate();
            var entry = try iterable.next();
            while (entry != null) : (entry = try iterable.next()) {
                const full_name = try std.fs.path.join(alloc, &[_][]const u8{ file_name, entry.?.name });
                defer alloc.free(full_name);
                try lint_file(full_name, alloc, analyzer, false);
            }
        },
        else => {
            std.log.warn(
                "ziglint: ignoring '{s}', which is not a file or directory, but a(n) {}.",
                .{ file_name, kind },
            );
        },
    }
}

// TODO: integration tests
// TODO: more lints! (import order, cyclomatic complexity)
// TODO: support disabling the linter for a line/region of code
