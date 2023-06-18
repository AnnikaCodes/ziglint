//! Rule to set a maximum number of characters per line.
const std = @import("std");
const analysis = @import("../analysis.zig");

pub const MaxLineLength = struct {
    /// The maximum number of characters per line.
    limit: u32,

    pub fn check_line(self: *MaxLineLength, _: std.mem.Allocator, fault_tracker: *analysis.SourceCodeFaultTracker, line: []const u8, line_number: u32) !void {
        const length = line.len;

        if (length > self.limit) {
            try fault_tracker.add(analysis.SourceCodeFault{
                .line_number = line_number,
                .column_number = self.limit,
                .fault_type = analysis.SourceCodeFaultType{ .LineTooLong = length },
            });
        }
    }
};
