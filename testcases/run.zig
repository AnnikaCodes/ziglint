// Runs the integration tests

const std = @import("std");

const MAX_OUTPUT_SIZE = 1024 * 1024; // 1MB

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer std.debug.assert(gpa.deinit() != .leak);

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.log.err("usage: {s} <path to ziglint executable>", .{args[0]});
        return;
    }

    const ziglint = try std.fs.realpathAlloc(allocator, args[1]);
    defer allocator.free(ziglint);

    const stdout = std.io.getStdOut();
    const stdout_writer = stdout.writer();
    const stderr_writer = std.io.getStdErr().writer();
    const use_color = stdout.supportsAnsiEscapeCodes();

    const bold_green_text: []const u8 = if (use_color) "\x1b[1;32m" else "";
    const bold_red_text: []const u8 = if (use_color) "\x1b[1;31m" else "";
    const end_text_fmt: []const u8 = if (use_color) "\x1b[0m" else "";

    // iterate over all directories in . and run the integration tests
    var dir = try std.fs.cwd().openIterableDir(".", .{});
    defer dir.close();

    var iterable = dir.iterate();
    var entry = try iterable.next();

    var failures = false;
    while (entry != null) : (entry = try iterable.next()) {
        if (entry.?.kind == .directory) {
            const name = entry.?.name;
            var test_directory = try std.fs.cwd().openDir(name, .{});
            defer test_directory.close();

            const expected_output = test_directory.readFileAlloc(allocator, "output.txt", MAX_OUTPUT_SIZE) catch |err| {
                switch (err) {
                    error.FileNotFound => {
                        std.log.err("test {s} has no output.txt file — skipping...", .{name});
                        continue;
                    },
                    else => {
                        std.log.err("unexpected error opening output.txt for test {s}: {}", .{ name, err });
                        @panic("panicking...");
                    },
                }
            };
            defer allocator.free(expected_output);

            // log to stdout
            try stdout_writer.print("Running integration test '{s}'...", .{name});
            const is_gitignore = std.mem.eql(u8, name, "gitignore");
            if (is_gitignore) try test_directory.rename(".gitignore-test", ".gitignore");

            const result = try std.ChildProcess.exec(.{
                .allocator = allocator,
                .argv = &.{ziglint},
                .cwd_dir = test_directory,
            });
            defer {
                allocator.free(result.stderr);
                allocator.free(result.stdout);
            }

            if (is_gitignore) {
                test_directory.rename(".gitignore", ".gitignore-test") catch {
                    std.log.err(
                        "******** FAILED TO RENAME testcases/gitignore/.gitignore-test TO .gitignore ********",
                        .{},
                    );
                };
            }

            // alphabetize expected and actual output
            const expected = try alphabetize(allocator, expected_output);
            defer allocator.free(expected);

            const actual = try alphabetize(allocator, result.stdout);
            defer allocator.free(actual);
            for (expected, actual) |expected_line, actual_line| {
                std.testing.expectEqualStrings(expected_line, actual_line) catch {
                    try stderr_writer.print("An integration test {s}FAILED{s}: '{s}'\n", .{ bold_red_text, end_text_fmt, name });
                    failures = true;
                    continue;
                };
            }

            try stdout_writer.print(" {s}ok{s}\n", .{ bold_green_text, end_text_fmt });
        }
        if (failures) std.process.exit(1);
    }
}

// Splits by newline and alphabetizes test output
// Caller must deinit
fn alphabetize(allocator: std.mem.Allocator, input: []const u8) ![][]const u8 {
    var list = std.ArrayList([]const u8).init(allocator);
    defer list.deinit();

    var line_start: usize = 0;
    var idx: usize = 0;
    while (idx < input.len) : (idx += 1) {
        if (input[idx] == '\n') {
            const line = input[line_start..idx];
            try list.append(line);
            line_start = idx + 1;
        }
    }

    var result = try list.toOwnedSlice();

    // sort strings in list.items alphabetically
    std.sort.insertion([]const u8, result, .{}, less_than);
    return result;
}

fn less_than(_: @TypeOf(.{}), lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}
