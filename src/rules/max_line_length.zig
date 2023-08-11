//! Rule to set a maximum number of characters per line.
const std = @import("std");
const analysis = @import("../analysis.zig");

pub const MaxLineLength = struct {
    /// The maximum number of characters per line.
    limit: u32,
    /// Whether to enforce the limit on lines containing just a comment with a URL.
    url: bool = false,
    /// Whether to enforce the limit on a multiline string's source representation as opposed to its contents.
    multiline: bool = true,

    pub fn check_line(
        self: *const MaxLineLength,
        _: std.mem.Allocator,
        fault_tracker: *analysis.SourceCodeFaultTracker,
        line: []const u8,
        line_number: u32,
    ) !void {
        const length = try std.unicode.utf8CountCodepoints(line);

        if (length > self.limit) {
            if (!self.url and is_url(line)) return;
            // For multiline strings, we care that the *result* fits,
            // but we don't mind indentation in the source.
            if (!self.multiline) {
                if (parse_multiline_string(line)) |string_value| {
                    const string_value_length = try std.unicode.utf8CountCodepoints(string_value);
                    if (string_value_length <= self.limit) return;
                }
            }
            try fault_tracker.add(analysis.SourceCodeFault{
                .line_number = line_number,
                .column_number = self.limit,
                .fault_type = analysis.SourceCodeFaultType{ .LineTooLong = length },
                .ast_error = null,
            });
        }
    }
};

fn cut(haystack: []const u8, needle: []const u8) ?struct { prefix: []const u8, suffix: []const u8 } {
    const index = std.mem.indexOf(u8, haystack, needle) orelse return null;
    return .{ .prefix = haystack[0..index], .suffix = haystack[index + needle.len ..] };
}

/// Heuristically checks if a `line` is a comment with an URL.
fn is_url(line: []const u8) bool {
    const result = cut(line, "// https://") orelse cut(line, "// http://") orelse return false;
    for (result.prefix) |p| if (!(p == ' ' or p == '/')) return false;
    for (result.suffix) |s| if (s == ' ') return false;
    return true;
}

/// If a line is a `\\` string literal, extract its value.
fn parse_multiline_string(line: []const u8) ?[]const u8 {
    const result = cut(line, "\\") orelse return null;
    for (result.prefix) |p| if (p != ' ') return null;
    return result.suffix;
}
