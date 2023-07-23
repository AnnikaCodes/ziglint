//! Check for cases where @import is called multiple times with the same value within a file

const std = @import("std");
const analysis = @import("../analysis.zig");

pub const DupeImport = struct {
    imports: std.StringHashMap(std.zig.Ast.Location),

    pub fn init(allocator: std.mem.Allocator) DupeImport {
        return .{ .imports = std.StringHashMap(std.zig.Ast.Location).init(allocator) };
    }

    pub fn deinit(self: *DupeImport) void {
        self.imports.deinit();
    }

    pub fn check_node(
        self: *DupeImport,
        _: std.mem.Allocator,
        fault_tracker: *analysis.SourceCodeFaultTracker,
        tree: std.zig.Ast,
        node_idx: u32,
    ) !void {
        const node = tree.nodes.get(node_idx);
        if (!std.mem.eql(u8, tree.tokenSlice(node.main_token), "@import")) return;

        const location = tree.tokenLocation(0, node.main_token);
        const result = try self.imports.getOrPut(tree.tokenSlice(node.main_token + 2));
        if (!result.found_existing) {
            result.value_ptr.* = location;
        } else {
            try fault_tracker.add(analysis.SourceCodeFault{
                .line_number = location.line + 1,
                .column_number = location.column,
                .fault_type = analysis.SourceCodeFaultType{ .DupeImport = result.key_ptr.* },
                .ast_error = null,
            });
        }
    }
};
