//! Handles .gitignore files

// TODO:
//   * handle `**` in directories
//   * add more tests
//   * document the gitignore functionality
//   * support exclusions from ziglint.json

const std = @import("std");

/// Tracks .gitignore directives to ignore/unignore files
pub const IgnoreTracker = struct {
    excludes: std.ArrayList([]const u8),
    includes: std.ArrayList([]const u8),
    base_path: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, base_path: []const u8) IgnoreTracker {
        return IgnoreTracker{
            .excludes = std.ArrayList([]const u8).init(allocator),
            .includes = std.ArrayList([]const u8).init(allocator),
            .base_path = base_path,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *IgnoreTracker) void {
        self.excludes.deinit();
        self.includes.deinit();
    }

    /// Parses statements from a .gitignore file and adds them to the tracker
    pub fn parse_gitignore(self: *IgnoreTracker, gitignore: []const u8) !void {
        var split = std.mem.splitScalar(u8, gitignore, '\n');
        var line = split.next();

        while (line != null) : (line = split.next()) {
            if (line.?.len == 0) continue;
            switch (line.?[0]) {
                // comment
                '#' => continue,
                // include (negated ignore)
                // TODO: do we need to unescape?
                '!' => try self.includes.append(line.?[1..]),
                else => try self.excludes.append(line.?),
            }
        }
    }

    pub fn is_ignored(self: *const IgnoreTracker, path: []const u8) !bool {
        const relative_path = try std.fs.path.relative(self.allocator, self.base_path, path);
        defer self.allocator.free(relative_path);

        for (self.includes.items) |include_pattern| {
            if (matches(relative_path, include_pattern)) return false;
        }

        for (self.excludes.items) |exclude_pattern| {
            if (matches(relative_path, exclude_pattern)) return true;
        }

        return false;
    }
};

/// Checks if a path matches a given .gitignore pattern.
///
/// These patterns are defined in the Git documentation: https://git-scm.com/docs/gitignore#_pattern_format
fn matches(path: []const u8, pattern_input: []const u8) bool {
    // TODO: handle **
    var pattern = pattern_input;
    if (pattern.len == 0) return false; // empty patterns never match

    var relative = true;
    if (pattern[0] == '/') {
        relative = false;
        pattern = pattern[1..];
    }

    var path_parts = std.mem.splitScalar(u8, path, std.fs.path.sep);
    var pattern_parts = std.mem.splitScalar(u8, pattern, '/');

    var current_path_part = path_parts.next();
    var current_pattern_part = pattern_parts.next();

    var at_start = true;
    while (current_pattern_part != null) {
        if (current_path_part == null) return false; // if we run out of path parts before a pattern ends, it's not a match

        if (std.mem.eql(u8, current_pattern_part.?, "**")) {
            // match until next part
            const next_pattern_part = pattern_parts.next();
            if (next_pattern_part == null) return true; // if ** is the last part, it matches everything

            // go through the path parts until we find one that doesn't match the pattern
            while (current_path_part != null) {
                if (part_matches(current_path_part.?, next_pattern_part.?)) break;
                current_path_part = path_parts.next();
            }
            if (current_path_part == null) {
                // we ran out of path parts before we found a match
                return false;
            }
        }

        var match = part_matches(current_path_part.?, current_pattern_part.?);
        if (relative and at_start) {
            // if it's relative and we're at the start,
            // we can move along the path until we find something that matches the pattern
            while (!match) {
                current_path_part = path_parts.next();
                if (current_path_part == null) return false; // if we run out of path parts before a match, it's not a match
                match = part_matches(current_path_part.?, current_pattern_part.?);
            }
            at_start = false;
        } else {
            if (!match) return false;
        }

        // if we get a match, advance the path part
        current_path_part = path_parts.next();
        current_pattern_part = pattern_parts.next();
    }
    return true;
}

fn part_matches(path_part: []const u8, pattern_part: []const u8) bool {
    var path_idx: usize = 0;
    var pattern_idx: usize = 0;
    while (pattern_idx < pattern_part.len) {
        if (path_idx >= path_part.len) return false; // if we run out of path parts before a pattern ends, it's not a match

        switch (pattern_part[pattern_idx]) {
            '*' => {
                // check for **
                if (pattern_idx + 1 < pattern_part.len and pattern_part[pattern_idx + 1] == '*') {
                    // matches a whole directory
                    return true;
                }

                // match as many characters as possible
                if (pattern_idx + 1 == pattern_part.len) return true; // if the * is the last character, it matches everything
                // otherwise, we need to match up to the next character
                var next_char = pattern_part[pattern_idx + 1];
                while (path_part[path_idx] != next_char) {
                    path_idx += 1;
                    if (path_idx >= path_part.len) return false;
                }
                pattern_idx += 1;
            },
            '?' => {
                // match a single character
                path_idx += 1;
                pattern_idx += 1;
            },
            else => {
                if (path_part[path_idx] != pattern_part[pattern_idx]) return false;
                path_idx += 1;
                pattern_idx += 1;
            },
        }
    }
    return true; // if we get here, we matched everything
}

test "matches" {
    try std.testing.expect(matches("foo/bar/baz.zig", "foo/bar/baz.zig"));
    try std.testing.expect(!matches("foo/bar/baz.zig", "foo/bar/quux.zig"));

    try std.testing.expect(matches("foo/bar/baz.zig", "baz.zig"));
    try std.testing.expect(!matches("foo/bar/baz.zig", "/baz.zig"));
    try std.testing.expect(matches("foo/bar/baz.zig", "bar/baz.zig"));
    try std.testing.expect(matches("foo/bar/baz.zig", "bar"));

    // *
    try std.testing.expect(matches("foo/bar/baz.zig", "foo/bar/*.zig"));
    try std.testing.expect(!matches("foo/bar/baz.zig", "foo/*.zig"));

    // **
    try std.testing.expect(matches("foo/bar/baz.zig", "foo/**/baz.zig"));

    try std.testing.expect(matches("foo/bar/baz/quux.zig", "foo/**/*.zig"));
    try std.testing.expect(matches("foo/bar/baz.zig", "foo/**/*.zig"));

    try std.testing.expect(matches("foo/bar/baz/quux.zig", "/**/*.zig"));
    try std.testing.expect(matches("foo/bar/baz.zig", "/**/*.zig"));

    try std.testing.expect(matches("foo/bar/baz/quux.zig", "**/quux.zig"));
    try std.testing.expect(matches("foo/bar/baz/quux.zig", "foo/bar/**"));

    // ?
    try std.testing.expect(matches("foo/bar/baz.zig", "foo/b?r/ba?.zig"));
    try std.testing.expect(!matches("foo/bar/baz.zig", "foo/bar?baz.zig"));
}
