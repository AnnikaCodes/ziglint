//! Checks comments for banned phrases.
//!
//! Is this really worth putting in a separate file? I don't know.
//!
//! Maybe it should just be in analysis.zig like the `ziglint: ignore` stuff.
const std = @import("std");
const analysis = @import("../analysis.zig");

pub const BannedPhraseConfig = struct {
    warning: ?[][]const u8,
    @"error": ?[][]const u8,
};

pub const BannedCommentPhrases = struct {
    config: ?BannedPhraseConfig,

    pub fn check_comment(
        self: BannedCommentPhrases,
        _: std.mem.Allocator,
        fault_tracker: *analysis.SourceCodeFaultTracker,
        comment: []const u8,
        line_number: u32,
    ) !void {
        // we will only be called if config is truthy - check is in analysis.zig
        if (self.config.?.warning) |warn_phrases| {
            for (warn_phrases) |warn_phrase| {
                if (std.mem.indexOf(u8, comment, warn_phrase)) |col| {
                    try fault_tracker.add(analysis.SourceCodeFault{
                        .line_number = line_number,
                        .column_number = col,
                        .fault_type = .{
                            .BannedCommentPhrase = .{
                                .phrase = warn_phrase,
                                .comment = comment,
                                .severity_level = .Warning,
                            },
                        },
                    });
                }
            }
        }

        if (self.config.?.@"error") |error_phrases| {
            for (error_phrases) |error_phrase| {
                if (std.mem.indexOf(u8, comment, error_phrase)) |col| {
                    try fault_tracker.add(analysis.SourceCodeFault{
                        .line_number = line_number,
                        .column_number = col,
                        .fault_type = .{
                            .BannedCommentPhrase = .{
                                .phrase = error_phrase,
                                .comment = comment,
                                .severity_level = .Error,
                            },
                        },
                    });
                }
            }
        }
    }
};
