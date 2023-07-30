//! A configurable linter for Zig

const std = @import("std");
const builtin = @import("builtin");
const ParallelLinter = @import("./parallel_lint.zig").ParallelLinter;

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
    .patch = 7,
    .prerelease = null,
    .build_metadata = @import("comptime_build").GIT_COMMIT_HASH,
};

const MAX_CONFIG_BYTES = 64 * 1024; // 64kb max

const fields = std.meta.fields(analysis.ASTAnalyzer);

// for sorting
// TODO figure out the idiomatic way to sort in zig

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

const SeverityParseError = error{
    InvalidSeverityLevel,
};
pub const SeverityLevel = enum {
    /// Prints the fault and increments the exit code
    Error,
    /// Prints the fault but does not increment the exit code
    Warning,
    /// Does not look for the fault
    Disabled,

    fn parse(value: RawJSONSeverityLevel) SeverityParseError!SeverityLevel {
        if (std.mem.eql(u8, value, "error")) return .Error;
        if (std.mem.eql(u8, value, "warning")) return .Warning;
        if (std.mem.eql(u8, value, "disabled")) return .Disabled;

        return SeverityParseError.InvalidSeverityLevel;
    }
};

/// Packages a severity level with a configuration value.
fn SeverityLevelPlusConfig(comptime config: type) type {
    return struct {
        severity: SeverityLevel,
        config: config,
    };
}

const RawJSONSeverityLevel = []const u8;
fn RawJSONSeverityLevelPlusConfig(comptime config: type) type {
    return struct {
        severity: RawJSONSeverityLevel,
        config: config,
    };
}

const BannedPhraseConfig = @import("rules/banned_comment_phrases.zig").BannedPhraseConfig;
// Since the JSON includes strings, not enums, we parse the JSON into this intermediate struct, then
// parse this into a Configuration.
//
// TODO: can we programmatically generte this from a Configuration somehow?
const JSONConfiguration = struct {
    max_line_length: ?RawJSONSeverityLevelPlusConfig(u32) = null,
    check_format: ?RawJSONSeverityLevel = null,
    dupe_import: ?RawJSONSeverityLevel = null,
    file_as_struct: ?RawJSONSeverityLevel = null,
    banned_comment_phrases: ?BannedPhraseConfig = null,
    include_gitignored: ?bool = null,
    exclude: ?[][]const u8 = null,
    include: ?[][]const u8 = null,

    fn parseSeverityFromString(severity_string: RawJSONSeverityLevel) SeverityLevel {
        return SeverityLevel.parse(severity_string) catch {
            stderr_print(
                "'{s}' is not a valid severity level. " ++
                    "Valid severity levels are 'error', 'warning', and 'disabled'.",
                .{severity_string},
            ) catch unreachable;
            std.process.exit(1);
        };
    }

    fn to_config(self: JSONConfiguration) !Configuration {
        var configuration = Configuration{};

        inline for (std.meta.fields(JSONConfiguration)) |field| {
            if (@field(self, field.name) != null) {
                const field_value = @field(self, field.name).?;
                switch (field.type) {
                    // convert to SeverityLevel
                    ?RawJSONSeverityLevel => {
                        const severity = JSONConfiguration.parseSeverityFromString(field_value);
                        @field(configuration, field.name) = severity;
                    },
                    // convert to SeverityLevelPlusConfig(u32)
                    ?RawJSONSeverityLevelPlusConfig(u32) => {
                        const severity = JSONConfiguration.parseSeverityFromString(field_value.severity);

                        @field(configuration, field.name) = SeverityLevelPlusConfig(u32){
                            .severity = severity,
                            .config = field_value.config,
                        };
                    },
                    // no conversion needed
                    ?bool, ?[][]const u8, ?BannedPhraseConfig => @field(configuration, field.name) = field_value,
                    else => {
                        try stderr_print(
                            "Couldn't parse type {s} in the Configuation from JSON. Something has gone very wrong.",
                            .{@typeName(field.type)},
                        );
                        @panic("panicking...");
                    },
                }
            }
        }
        return configuration;
    }
};

pub const Configuration = struct {
    max_line_length: ?SeverityLevelPlusConfig(u32) = null,
    check_format: ?SeverityLevel = null,
    dupe_import: ?SeverityLevel = null,
    file_as_struct: ?SeverityLevel = null,
    banned_comment_phrases: ?BannedPhraseConfig = null,
    include_gitignored: ?bool = null,
    verbose: ?bool = null,
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
        \\      --verbose
        \\          print more information about what ziglint is doing
        \\
        \\      --max-line-length <u32>
        \\          set the maximum length of a line of code
        \\
        \\      --check-format
        \\          ensure code is syntactically correct and formatted according to Zig standards
        \\          (this is similar to what `zig fmt --check` does)
        \\
        \\      --dupe-import
        \\           check for cases where @import is called multiple times with the same value within a file
        \\
        \\      --file-as-struct
        \\           check for file name capitalization in the presence of top level fields
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
        \\when analyzing code, ziglint's exit code will be the number of faults it finds,
        \\or 2^8 - 1 = 255 if the number of faults is too big to be represented by 8 bits.
        \\
    );
}

// look ahead to the next argument to see if it's a "warn" or "warning" directive
fn get_severity_level(args: [][]const u8, args_idx: usize) SeverityLevel {
    const next_idx = args_idx + 1;
    if (next_idx >= args.len) return SeverityLevel.Error; // default to Error

    if (is_warning(args[next_idx])) {
        return SeverityLevel.Warning;
    } else {
        return SeverityLevel.Error;
    }
}

fn is_warning(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " ");
    return (std.mem.eql(u8, trimmed, "warn") or std.mem.eql(u8, trimmed, "warning"));
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

                var len_string: []const u8 = args[args_idx];
                var severity_level = SeverityLevel.Error;
                if (std.mem.indexOfScalar(u8, len_string, ',')) |comma_location| {
                    const severity_text = std.mem.trim(u8, len_string[comma_location + 1 ..], " ");
                    if (is_warning(severity_text)) severity_level = .Warning;
                    len_string = len_string[0..comma_location];
                }

                const max_len = std.fmt.parseInt(u32, len_string, 10) catch |err| {
                    switch (err) {
                        error.InvalidCharacter => {
                            try stderr_print("invalid (non-digit) character in '--max-line-length {s}'", .{len_string});
                        },
                        error.Overflow => {
                            try stderr_print(
                                "--max-line-length value {s} doesn't fit in a 32-bit unsigned integer",
                                .{len_string},
                            );
                        },
                    }
                    std.process.exit(1);
                };
                switches.max_line_length = .{ .severity = severity_level, .config = max_len };
            } else if (std.mem.eql(u8, switch_name, "check-format")) {
                switches.check_format = get_severity_level(args, args_idx);
            } else if (std.mem.eql(u8, switch_name, "dupe-import")) {
                switches.dupe_import = get_severity_level(args, args_idx);
            } else if (std.mem.eql(u8, switch_name, "file-as-struct")) {
                switches.file_as_struct = get_severity_level(args, args_idx);
            } else if (std.mem.eql(u8, switch_name, "include-gitignored")) {
                switches.include_gitignored = true;
            } else if (std.mem.eql(u8, switch_name, "verbose")) {
                switches.verbose = true;
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
    var error_count: u64 = 0;
    for (files) |file| {
        var config_file_parsed = try get_config(file, arena_allocator, switches.verbose orelse false);
        var config = switches;

        if (config_file_parsed) |c| {
            config = c.value;
            try config.merge(&switches, arena_allocator);
        }

        var analyzer = analysis.ASTAnalyzer{};
        inline for (std.meta.fields(analysis.ASTAnalyzer)) |field| {
            if (@field(config, field.name)) |value| {
                // the AST analyzer doesn't need to know if it's an error or warning.
                @field(analyzer, field.name) = switch (@TypeOf(value)) {
                    SeverityLevel => value != .Disabled,
                    SeverityLevelPlusConfig(u32) => if (value.severity == .Disabled) 0 else value.config,
                    else => value,
                };
            }
        }

        var ignore_tracker = IgnoreTracker.init(arena_allocator, file);
        defer ignore_tracker.deinit();

        if (config.exclude) |excludes| try ignore_tracker.add_slice_to_excludes(excludes);
        if (config.include) |includes| try ignore_tracker.add_slice_to_includes(includes);

        var gitignore_text: ?[]const u8 = null;

        if (config.include_gitignored != false) {
            const gitignore_path = try find_file(arena_allocator, file, ".gitignore");
            if (gitignore_path) |path| {
                if (config.verbose orelse false) try stderr_print("using Gitignore {s}", .{path});

                gitignore_text = try std.fs.cwd().readFileAlloc(arena_allocator, path, MAX_CONFIG_BYTES);
                try ignore_tracker.parse_gitignore(gitignore_text.?);
            }
        }

        var linter = ParallelLinter.init(
            arena_allocator,
            allocator,
            &analyzer,
            &config,
            &ignore_tracker,
        );
        error_count += try linter.run(file);
    }

    if (error_count >= 256) {
        // too many faults to exit with
        try stderr_print("error: too many faults ({}) to exit with the correct exit code", .{error_count});
        std.process.exit(255);
    }
    std.process.exit(@as(u8, @intCast(error_count)));
}

// Creates a Configuration object for the given file based on the nearest ziglintrc file.
fn get_config(file_name: []const u8, alloc: std.mem.Allocator, verbose: bool) !?std.json.Parsed(Configuration) {
    const ziglintrc_path = try find_file(alloc, file_name, "ziglint.json");
    if (ziglintrc_path) |path| {
        defer alloc.free(path);

        if (verbose) try stderr_print("using config file {s}", .{path});
        const config_raw = try std.fs.cwd().readFileAlloc(alloc, path, MAX_CONFIG_BYTES);
        const possible_json_cfg = std.json.parseFromSlice(
            JSONConfiguration,
            alloc,
            config_raw,
            .{},
        ) catch |err| err_handle_blk: {
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
        if (possible_json_cfg) |json_cfg| {
            return .{
                .arena = json_cfg.arena,
                // convert JSONConfiguration -> Configuration and parse the severity levels into enums
                .value = try json_cfg.value.to_config(),
            };
        }
    }

    if (verbose) try stderr_print("warning: no valid ziglint.json found! using default configuration.", .{});
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
