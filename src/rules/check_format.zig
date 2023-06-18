//! Uses Zig's built-in AST rendering functionality to check if the source code is correctly formatted.
//!
//! This is similar behavior to `zig fmt --check`.

const std = @import("std");
const analysis = @import("../analysis.zig");

pub const CheckFormat = struct {
    ast_is_checked: bool = false,

    pub fn check_node(self: *CheckFormat, alloc: std.mem.Allocator, fault_tracker: *analysis.SourceCodeFaultTracker, tree: std.zig.Ast, _: u32) !void {
        if (self.ast_is_checked) return;

        // error-free tree!
        if (tree.errors.len == 0) {
            const formatted = try tree.render(alloc);
            defer alloc.free(formatted);

            if (!std.mem.eql(u8, tree.source, formatted)) {
                try fault_tracker.add(analysis.SourceCodeFault{ .line_number = 0, .column_number = 0, .fault_type = .ImproperlyFormatted });
            }
        } else {
            // AST errors to report!
            for (tree.errors) |err| {
                const location = tree.tokenLocation(0, err.token);
                try fault_tracker.add(analysis.SourceCodeFault{
                    .line_number = location.line + 1,
                    .column_number = location.column,
                    .fault_type = .ASTError,
                    .ast_error = err,
                });
            }
        }

        self.ast_is_checked = true;
    }
};
