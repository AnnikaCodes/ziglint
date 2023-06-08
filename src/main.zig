//! A configurable linter for Zig

const clap = @import("./lib/clap/clap.zig");
const std = @import("std");
// const git_revision = @import("gitrev").revision;
const analysis = @import("./analysis.zig");

const MAX_CONFIG_BYTES = 64 * 1024; // 64kb max

const fields = std.meta.fields(analysis.ASTAnalyzer);

// for sorting
// TODO figure out the idiomatic way to sort in zig
fn less_than(_: @TypeOf(.{}), a: analysis.SourceCodeFault, b: analysis.SourceCodeFault) bool {
    return a.line_number < b.line_number;
}

const args = (
    \\--help                                  Display this help and exit.
    \\--version                               Output version information and exit.
    \\--max-line-length <u32>                 The maximum length of a line of code
    \\--no-require-const-pointer-params       Disable requiring all unmutated pointer parameters to functions be const.
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
    } else if (res.args.help != 0) {
        const stdout = std.io.getStdOut().writer();
        try stdout.writeAll(
            \\ziglint: configurable static code analysis for the Zig language
            \\
            \\usage: ziglint [options] [files]
            \\
            \\([files] defaults to the current directory if not specified)
            \\
            \\options:
            \\
        );
        try clap.help(stdout, clap.Help, &params, .{});
        return;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) @panic("MEMORY LEAK");
    }

    const files = if (res.positionals.len > 0) res.positionals else &[_][]const u8{"."};
    for (files) |file| {
        var analyzer = try get_analyzer(file, allocator);

        // command-line args override ziglintrc
        if (@field(res.args, "max-line-length") != null) {
            analyzer.max_line_length = @field(res.args, "max-line-length").?;
        }
        if (@field(res.args, "no-require-const-pointer-params") != 0) {
            analyzer.enforce_const_pointers = false;
        }

        try lint(file, allocator, analyzer, true);
    }
}

// Creates an ASTAnalyzer for the given file based on the nearest ziglintrc file.
fn get_analyzer(file_name: []const u8, alloc: std.mem.Allocator) !analysis.ASTAnalyzer {
    const ziglintrc_path = try find_ziglintrc(file_name, alloc);
    if (ziglintrc_path != null) {
        defer alloc.free(ziglintrc_path.?);

        std.log.info("using config file {s}", .{ziglintrc_path.?});
        const config_raw = try std.fs.cwd().readFileAlloc(alloc, ziglintrc_path.?, MAX_CONFIG_BYTES);
        defer alloc.free(config_raw);
        return std.json.parseFromSlice(analysis.ASTAnalyzer, alloc, config_raw, .{}) catch |err| {
            switch (err) {
                error.UnknownField => {
                    var field_names: [fields.len][]const u8 = undefined;
                    inline for (fields, 0..) |field, i| {
                        field_names[i] = field.name;
                    }
                    const fields_str = try std.mem.join(alloc, ", ", &field_names);
                    defer alloc.free(fields_str);

                    std.log.err(
                        "an unknown field was encountered in ziglintrc.json\nValid fields are: {s}",
                        .{fields_str},
                    );
                },
                else => std.log.err("error parsing ziglintrc.json: {any}", .{err}),
            }
            std.process.exit(1);
        };
    }

    std.log.warn("No ziglintrc.json found! Using default configuration.", .{});
    return analysis.ASTAnalyzer{
        .max_line_length = 125,
        .enforce_const_pointers = true,
    };
}

// finds a ziglintrc file in the given directory or any parent directory
// caller needs to free the result if it's there
fn find_ziglintrc(file_name: []const u8, alloc: std.mem.Allocator) !?[]const u8 {
    const file = try std.fs.cwd().openFile(file_name, .{});
    defer file.close();
    var is_dir = (try file.stat()).kind == .directory;
    var full_path = try std.fs.realpathAlloc(alloc, file_name);
    defer alloc.free(full_path);
    var nearest_dir = if (is_dir) full_path else std.fs.path.dirname(full_path);

    while (nearest_dir != null) {
        const ziglintrc = try std.fs.path.join(alloc, &[_][]const u8{ nearest_dir.?, "ziglintrc.json" });
        const stat = std.fs.cwd().statFile(ziglintrc);
        if (stat != error.FileNotFound) {
            _ = try stat; // return error if there is one
            return ziglintrc;
        } else {
            alloc.free(ziglintrc);
        }

        nearest_dir = std.fs.path.dirname(nearest_dir.?);
    }
    return null;
}

// Lints a file.
//
// If it's a directory, recursively search it for .zig files and lint them.
fn lint(file_name: []const u8, alloc: std.mem.Allocator, analyzer: analysis.ASTAnalyzer, is_top_level: bool) !void {
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
            if (!std.mem.endsWith(u8, file_name, ".zig")) {
                // not a Zig file
                return;
            }
            const contents = try alloc.allocSentinel(u8, metadata.size() + 1, 0);
            defer alloc.free(contents);
            _ = try file.readAll(contents);

            var ast = try std.zig.Ast.parse(alloc, contents, .zig);
            defer ast.deinit(alloc);
            var faults = try analyzer.analyze(alloc, ast);
            defer faults.deinit();

            // TODO just return faults.items

            const sorted_faults = std.sort.insertion(analysis.SourceCodeFault, faults.faults.items, .{}, less_than);
            _ = sorted_faults;
            const stdout = std.io.getStdOut();
            const stdout_writer = stdout.writer();

            const use_color: bool = stdout.supportsAnsiEscapeCodes();
            const bold_text: []const u8 = if (use_color) "\x1b[1m" else "";
            const red_text: []const u8 = if (use_color) "\x1b[31m" else "";
            const bold_magenta: []const u8 = if (use_color) "\x1b[1;35m" else "";
            const end_text_fmt: []const u8 = if (use_color) "\x1b[0m" else "";

            for (faults.faults.items) |fault| {
                try stdout_writer.print("{s}{s}:{}:{}{s}: ", .{
                    bold_text,
                    file_name,
                    fault.line_number,
                    fault.column_number,
                    end_text_fmt,
                });
                switch (fault.fault_type) {
                    .LineTooLong => |len| try stdout_writer.print(
                        "line is {s}{} characters long{s}; the maximum is {}",
                        .{ red_text, len, end_text_fmt, analyzer.max_line_length },
                    ),
                    .PointerParamNotConst => |name| try stdout_writer.print(
                        "pointer parameter {s}{s}{s}{s} is not const{s}, but I think it can be",
                        .{
                            bold_magenta,
                            name,
                            end_text_fmt,
                            red_text,
                            end_text_fmt,
                        },
                    ),
                }
                try stdout_writer.writeAll("\n");
            }

            // if (faults.items.len == 0) {
            //     try stdout.print("{s}{s}{s}: {s}no faults found!{s}\n", .{ bold_text, file_name, end_text_fmt, GREEN, end_text_fmt });
            // }
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
                try lint(full_name, alloc, analyzer, false);
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
