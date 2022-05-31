// A configurable linter for Zig

const clap = @import("clap");
const std = @import("std");

const args = (
    \\--help                                Display this help and exit.
    \\--version                             Output version information and exit.
    \\--max-line-length <u16>               The maximum length of a line of code.
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

    if (res.args.help or res.positionals.len == 0) {
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
}

// TODO: integration tests
// TODO: more lints! (import order, cyclomatic complexity)
// TODO: support disabling the linter for a line/region of code
