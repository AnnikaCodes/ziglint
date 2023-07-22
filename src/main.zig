//! A configurable linter for Zig

const std = @import("std");
const builtin = @import("builtin");
// const git_revision = @import("gitrev").revision;
const analysis = @import("./analysis.zig");
const upgrade = @import("./upgrade.zig");
const IgnoreTracker = @import("./gitignore.zig").IgnoreTracker;
const Version = @import("./semver.zig").Version;

/////////////////////////////////////////////////////
///              VERSION INFORMATION              ///
///      Change me when you make an upgrade!      ///
/////////////////////////////////////////////////////
const ZIGLINT_VERSION = Version{
    .major = 0,
    .minor = 0,
    .patch = 5,
    .prerelease = null,
    .build_metadata = @import("comptime_build").GIT_COMMIT_HASH,
};

const MAX_CONFIG_BYTES = 64 * 1024; // 64kb max

const fields = std.meta.fields(analysis.ASTAnalyzer);

// for sorting
// TODO figure out the idiomatic way to sort in zig
fn less_than(_: @TypeOf(.{}), a: analysis.SourceCodeFault, b: analysis.SourceCodeFault) bool {
    return a.line_number < b.line_number;
}

// a comptime BufferedWriter is for some reason not working on Windows
// we could pass around a writer, but for now I've been lazy and just got a writer every time
// on Windows
var stderr = if (builtin.target.os.tag == .windows) null else std.io.bufferedWriter(std.io.getStdErr().writer());
pub fn stderr_print(comptime format: []const u8, args: anytype) !void {
    if (builtin.target.os.tag == .windows) {
        var w = std.io.getStdErr().writer();
        try w.print(format ++ "\n", args);
    } else {
        try stderr.writer().print(format ++ "\n", args);
        try stderr.flush();
    }
}

const Configuration = struct {
    max_line_length: ?u32 = null,
    check_format: ?bool = null,
    enforce_const_pointers: ?bool = null,
    include_gitignored: ?bool = null,
    exclude: ?[][]const u8 = null,
    include: ?[][]const u8 = null,

    /// Replaces our fields with its fields if the field is not null in other
    ///
    /// Does NOT free potentially-allocated memory; we use an ArenaAllocator so it's all freed when ziglint exits.
    pub fn merge(self: *Configuration, other: *const Configuration, alloc: std.mem.Allocator) !void {
        inline for (std.meta.fields(Configuration)) |field| {
            if (@field(other, field.name)) |value| {
                const is_array = field.type == ?[][]const u8;
                const self_has_value = @field(self, field.name) != null;
                if (is_array and self_has_value) {
                    // merge fields via concatenation
                    @field(self, field.name) = try std.mem.concat(
                        alloc,
                        []const u8,
                        &.{ @field(self, field.name).?, value },
                    );
                } else {
                    // merge fields via replacement
                    @field(self, field.name) = value;
                }
            }
        }
    }
};

fn show_help() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(
        \\ziglint: configurable static code analysis for the Zig programming language
        \\report bugs and request features at https://github.com/AnnikaCodes/ziglint
        \\
        \\usage:
        \\      to analyze code:                      ziglint [options] [files]
        \\      to see what version is running:       ziglint version
        \\      to upgrade to the latest version:     ziglint upgrade
        \\      to view this help message again:      ziglint help
        \\
        \\options:
        \\      --max-line-length <u32>
        \\          set the maximum length of a line of code
        \\
        \\      --check-format
        \\          ensure code is syntactically correct and formatted according to Zig standards
        \\          (this is similar to what `zig fmt --check` does)
        \\
        \\      --include-gitignored
        \\          lint files excluded by .gitignore directives
        \\
        \\      --exclude <paths>
        \\          exclude files or directories from linting
        \\          <paths> should be a comma-separated list of Gitignore-style globs
        \\          this doesn't take priority over inclusion directives from ziglint.json or .gitignore files
        \\
        \\      --include <paths>
        \\          include files or directories in linting
        \\          <paths> should be a comma-separated list of Gitignore-style globs
        \\
        \\      --require-const-pointer-params
        \\          require all unmutated pointer parameters to functions be `const` (not yet fully implemented)
        \\
        \\when analyzing code, ziglint's exit code will be the number of faults it finds,
        \\or 2^8 - 1 = 255 if the number of faults is too big to be represented by 8 bits.
        \\
    );
}

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer std.debug.assert(gpa.deinit() != .leak);

    // use an ArenaAllocator for everything that's not per-file
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // check for subcommads
    if (args.len >= 2) {
        if (std.mem.eql(u8, args[1], "upgrade")) {
            // upgrade path
            var override_url: ?[]const u8 = null;
            if (args.len >= 3) {
                override_url = args[2];
                try stderr_print("overriding GitHub API URL to {s}", .{override_url.?});
            }
            try upgrade.upgrade(arena_allocator, ZIGLINT_VERSION, override_url);
            return;
        } else if (std.mem.eql(u8, args[1], "version")) {
            const stdout = std.io.getStdOut().writer();
            try stdout.print("{}\n", .{ZIGLINT_VERSION});
            return;
        } else if (std.mem.eql(u8, args[1], "help")) {
            return show_help();
        }
    }

    // check for switches/arguments
    var args_idx: usize = 1;
    var switches = Configuration{};
    var cmd_line_files = std.ArrayList([]const u8).init(arena_allocator);
    defer cmd_line_files.deinit();

    while (args_idx < args.len) : (args_idx += 1) {
        const arg = args[args_idx];
        if (arg.len > 2 and arg[0] == '-' and arg[1] == '-') { // switch
            const switch_name = arg[2..];
            const is_exclude = std.mem.eql(u8, switch_name, "exclude");
            const is_include = std.mem.eql(u8, switch_name, "include");
            if (std.mem.eql(u8, switch_name, "max-line-length")) {
                args_idx += 1;
                if (args_idx >= args.len) {
                    try stderr_print(
                        "--max-line-length requires an argument; use `ziglint help` for more information",
                        .{},
                    );
                    std.process.exit(1);
                }

                const len = args[args_idx];
                switches.max_line_length = std.fmt.parseInt(u32, len, 10) catch |err| {
                    switch (err) {
                        error.InvalidCharacter => {
                            try stderr_print("invalid (non-digit) character in '--max-line-length {s}'", .{len});
                        },
                        error.Overflow => {
                            try stderr_print(
                                "--max-line-length value {s} doesn't fit in a 32-bit unsigned integer",
                                .{len},
                            );
                        },
                    }
                    std.process.exit(1);
                };
            } else if (std.mem.eql(u8, switch_name, "check-format")) {
                switches.check_format = true;
            } else if (std.mem.eql(u8, switch_name, "require-const-pointer-params")) {
                switches.enforce_const_pointers = true;
            } else if (std.mem.eql(u8, switch_name, "include-gitignored")) {
                switches.include_gitignored = true;
            } else if (is_include or is_exclude) {
                args_idx += 1;
                if (args_idx >= args.len) {
                    try stderr_print("{s} requires an argument of comma-spearated globs; " ++
                        "use `ziglint help` for more information", .{arg});
                    std.process.exit(1);
                }

                var split = std.mem.splitScalar(u8, args[args_idx], ',');
                var globs = std.ArrayList([]const u8).init(arena_allocator);
                while (split.next()) |glob| {
                    try globs.append(glob);
                }

                if (is_include) {
                    switches.include = try globs.toOwnedSlice();
                } else if (is_exclude) {
                    switches.exclude = try globs.toOwnedSlice();
                } else unreachable;
            } else {
                try stderr_print("unknown switch: {s}\n", .{arg});
                try show_help();
                std.process.exit(1);
            }
        } else {
            try cmd_line_files.append(arg);
        }
    }

    // track the files we've already seen to make sure we don't get stuck in loops
    // or double-lint files due to symlinks.
    var seen = std.StringHashMap(void).init(arena_allocator);
    defer {
        // free all the keys, which got put here from std.fs.realpathAlloc() allocations
        // with the non-arena (per-file) allocator
        var key_iterator = seen.keyIterator();
        while (key_iterator.next()) |key| {
            allocator.free(key.*);
        }

        // no need to free the hashmap itself as it's arena-allocated
        seen.deinit();
    }

    const files = if (cmd_line_files.items.len > 0) cmd_line_files.items else &[_][]const u8{"."};
    var fault_count: u64 = 0;
    for (files) |file| {
        var config_file_parsed = try get_config(file, arena_allocator);
        var config = switches;

        if (config_file_parsed) |c| {
            config = c.value;
            try config.merge(&switches, arena_allocator);
        }

        var analyzer = analysis.ASTAnalyzer{};
        inline for (std.meta.fields(analysis.ASTAnalyzer)) |field| {
            if (@field(config, field.name)) |value| @field(analyzer, field.name) = value;
        }

        var ignore_tracker = IgnoreTracker.init(arena_allocator, file);
        defer ignore_tracker.deinit();

        if (config.exclude) |excludes| try ignore_tracker.add_slice_to_excludes(excludes);
        if (config.include) |includes| try ignore_tracker.add_slice_to_includes(includes);

        var gitignore_text: ?[]const u8 = null;

        if (config.include_gitignored != false) {
            const gitignore_path = try find_file(arena_allocator, file, ".gitignore");
            if (gitignore_path) |path| {
                try stderr_print("using Gitignore {s}", .{path});

                gitignore_text = try std.fs.cwd().readFileAlloc(arena_allocator, path, MAX_CONFIG_BYTES);
                try ignore_tracker.parse_gitignore(gitignore_text.?);
            }
        }

        fault_count += try lint(file, allocator, analyzer, &ignore_tracker, &seen, true);
    }

    if (fault_count >= 256) {
        // too many faults to exit with
        try stderr_print("error: too many faults ({}) to exit with the correct exit code", .{fault_count});
        std.process.exit(255);
    }
    std.process.exit(@as(u8, @intCast(fault_count)));
}

// Creates a Configuration object for the given file based on the nearest ziglintrc file.
fn get_config(file_name: []const u8, alloc: std.mem.Allocator) !?std.json.Parsed(Configuration) {
    const ziglintrc_path = try find_file(alloc, file_name, "ziglint.json");
    if (ziglintrc_path) |path| {
        defer alloc.free(path);

        try stderr_print("using config file {s}", .{path});
        const config_raw = try std.fs.cwd().readFileAlloc(alloc, path, MAX_CONFIG_BYTES);
        const cfg = std.json.parseFromSlice(Configuration, alloc, config_raw, .{}) catch |err| err_handle_blk: {
            switch (err) {
                error.UnknownField => {
                    var field_names: [fields.len][]const u8 = undefined;
                    inline for (fields, 0..) |field, i| {
                        field_names[i] = field.name;
                    }
                    const fields_str = try std.mem.join(alloc, ", ", &field_names);
                    defer alloc.free(fields_str);

                    try stderr_print(
                        "error: an unknown field was encountered in ziglint.json\nValid fields are: {s}",
                        .{fields_str},
                    );
                },
                else => try stderr_print("error: couldn't parse ziglint.json: {any}", .{err}),
            }
            break :err_handle_blk null;
        };
        if (cfg != null) return cfg;
    }

    try stderr_print("warning: no valid ziglint.json found! using default configuration.", .{});
    return null;
}

// finds a ziglintrc file in the given directory or any parent directory
// caller needs to free the result if it's there
fn find_file(alloc: std.mem.Allocator, file_name: []const u8, search_name: []const u8) !?[]const u8 {
    var is_dir = false;
    if (std.fs.cwd().openFile(file_name, .{})) |file| {
        is_dir = ((try file.stat()).kind == .directory);
        file.close();
    } else |err| {
        switch (err) {
            error.FileNotFound => {
                try stderr_print("error: file not found: {s}", .{file_name});
                std.process.exit(1);
            },
            error.IsDir => is_dir = true,
            else => return err,
        }
    }

    var full_path = try std.fs.realpathAlloc(alloc, file_name);
    defer alloc.free(full_path);
    var nearest_dir = if (is_dir) full_path else std.fs.path.dirname(full_path);

    while (nearest_dir != null) {
        const ziglintrc = try std.fs.path.join(alloc, &[_][]const u8{ nearest_dir.?, search_name });
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
//
// Returns the number of faults found.
fn lint(
    file_name: []const u8,
    alloc: std.mem.Allocator,
    analyzer: analysis.ASTAnalyzer,
    ignore_tracker: *const IgnoreTracker,
    seen: *std.StringHashMap(void),
    is_top_level: bool,
) anyerror!u64 {
    // we need the full, not relative, path to make sure we avoid symlink loops
    const real_path = try std.fs.realpathAlloc(alloc, file_name);
    if (seen.contains(real_path)) {
        // we need to free the `real_path` memory here since we're not adding it to the hashmap
        alloc.free(real_path);
        return 0; // no faults, since we already checked this path
    } else {
        try seen.put(real_path, {});
    }

    const file = std.fs.cwd().openFile(file_name, .{}) catch |err| {
        switch (err) {
            error.AccessDenied => try stderr_print("error: access denied: '{s}'", .{file_name}),
            error.DeviceBusy => try stderr_print("error: device busy: '{s}'", .{file_name}),
            error.FileNotFound => try stderr_print("error: file not found: '{s}'", .{file_name}),
            error.FileTooBig => try stderr_print("error: file too big: '{s}'", .{file_name}),

            error.SymLinkLoop => {
                // symlink loops should be caught by our hashmap of seen files
                // if not, we have a problem, so let's check
                if (!seen.contains(real_path)) {
                    try stderr_print(
                        "error: couldn't open '{s}' due to a symlink loop, " ++
                            "but it still hasn't been linted (full path: {s})",
                        .{ file_name, real_path },
                    );
                }
            },

            // Windows can't open a directory with openFile, apparently.
            error.IsDir => {
                return try walk_directory(file_name, alloc, analyzer, ignore_tracker, seen);
            },

            else => try stderr_print("error: couldn't open '{s}': {}", .{ file_name, err }),
        }

        // exit the program if the *user* specified an inaccessible file;
        // otherwise, just skip it
        if (is_top_level) {
            std.os.exit(1);
        } else {
            return 0;
        }
    };
    defer file.close();

    const metadata = try file.metadata(); // TODO: is .stat() faster?
    const kind = metadata.kind();
    var fault_count: u64 = 0;
    switch (kind) {
        .file => {
            if (!is_top_level) {
                // not a Zig file + not directly specified by the user
                if (!std.mem.endsWith(u8, file_name, ".zig")) return fault_count;
                // ignored by a .gitignore
                if (try ignore_tracker.is_ignored(file_name)) return fault_count;
            }

            // lint it
            const contents = try alloc.allocSentinel(u8, metadata.size(), 0);
            defer alloc.free(contents);
            _ = file.readAll(contents) catch |err| {
                try stderr_print("error: couldn't read '{s}': {}", .{ file_name, err });
                return fault_count;
            };

            var ast = try std.zig.Ast.parse(alloc, contents, .zig);
            defer ast.deinit(alloc);
            var faults = try analyzer.analyze(alloc, ast);
            defer faults.deinit();
            fault_count += faults.faults.items.len;

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
                    .ImproperlyFormatted => try stdout_writer.print(
                        "the file is {s}improperly formatted{s}; try using `zig fmt` to fix it",
                        .{ red_text, end_text_fmt },
                    ),
                    .ASTError => {
                        try stdout_writer.print("Zig's code parser detected an error: {s}", .{red_text});
                        try ast.renderError(fault.ast_error.?, stdout_writer);
                        try stdout_writer.print("{s}", .{end_text_fmt});
                    },
                }
                try stdout_writer.writeAll("\n");
            }
        },
        .directory => {
            fault_count += try walk_directory(file_name, alloc, analyzer, ignore_tracker, seen);
        },
        else => {
            try stderr_print(
                "ignoring '{s}', which is not a file or directory, but a(n) {}.",
                .{ file_name, kind },
            );
        },
    }
    return fault_count;
}

// iterate over a directory and lint
// returns # of faults found
fn walk_directory(
    file_name: []const u8,
    alloc: std.mem.Allocator,
    analyzer: analysis.ASTAnalyzer,
    ignore_tracker: *const IgnoreTracker,
    seen: *std.StringHashMap(void),
) !u64 {
    // todo: is walker faster?
    var dir = try std.fs.cwd().openIterableDir(file_name, .{});
    defer dir.close();

    var iterable = dir.iterate();
    var entry = try iterable.next();
    var fault_count: u64 = 0;
    while (entry != null) : (entry = try iterable.next()) {
        const full_name = try std.fs.path.join(alloc, &[_][]const u8{ file_name, entry.?.name });
        defer alloc.free(full_name);
        fault_count += try lint(full_name, alloc, analyzer, ignore_tracker, seen, false);
    }
    return fault_count;
}

// TODO: more lints! (import order, cyclomatic complexity)
// TODO: support disabling the linter for a line/region of code
