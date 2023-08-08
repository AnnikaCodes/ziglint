//! Uses Zig's built-in AST rendering functionality to check if the source code is correctly formatted.
//!
//! This is similar behavior to `zig fmt --check`.

const std = @import("std");
const analysis = @import("../analysis.zig");

pub const CheckFormat = struct {
    pub fn check_tree(
        _: *CheckFormat,
        _: std.mem.Allocator,
        // fault_tracker: *analysis.SourceCodeFaultTracker,
        _: []const u8,
        tree: std.zig.Ast,
        buffer: *std.ArrayList(u8),
    ) !void {
        // error-free tree!
        if (tree.errors.len == 0) {
            buffer.shrinkRetainingCapacity(0);
            try buffer.ensureTotalCapacity(tree.source.len);

            try tree.renderToArrayList(buffer);

            if (!std.mem.eql(u8, tree.source, buffer.items)) {
                // try fault_tracker.add(analysis.SourceCodeFault{
                //     .line_number = 0,
                //     .column_number = 0,
                //     .fault_type = .ImproperlyFormatted,
                // });
            }
        } else {
            // AST errors to report!
            // for (tree.errors) |err| {
            //     const location = tree.tokenLocation(0, err.token);
            //     _ = location;
            // try fault_tracker.add(analysis.SourceCodeFault{
            //     .line_number = location.line + 1,
            //     .column_number = location.column,
            //     .fault_type = .ASTError,
            //     .ast_error = err,
            // });
            // }
        }
    }
};
