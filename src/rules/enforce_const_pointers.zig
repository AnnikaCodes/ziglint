//! WIP rule to require that pointers be marked `const` if possible.

const analysis = @import("../analysis.zig");
const std = @import("std");

pub const EnforceConstPointers = struct {
    last_enforced_fn_node_idx: u32 = 0,

    pub fn check_node(
        self: *EnforceConstPointers,
        allocator: std.mem.Allocator,
        fault_tracker: *analysis.SourceCodeFaultTracker,
        tree: std.zig.Ast,
        node_idx: u32,
    ) !void {
        if (self.last_enforced_fn_node_idx > node_idx) return;

        // Is it a function prototype? If so, we will need to check const pointer enforcement
        var buffer: [1]u32 = [1]u32{0};
        const fullProto = tree.fullFnProto(&buffer, node_idx);
        if (fullProto == null) return; // not a function prototype

        // TODO: can we know the length ahead of time?
        var mutable_ptr_token_indices = std.ArrayList(u32).init(allocator);
        defer mutable_ptr_token_indices.deinit();
        for (fullProto.?.ast.params) |param_node_idx| {
            const fullPtrType = tree.fullPtrType(param_node_idx);
            if (fullPtrType == null) return; // not a pointer
            if (fullPtrType.?.const_token == null) { // pointer is mutable
                // subtract 2 since main_token is the asterisk - we skip the '*' and the ':'
                const token = fullPtrType.?.ast.main_token - 2;
                try mutable_ptr_token_indices.append(token);
            }
        }

        if (mutable_ptr_token_indices.items.len > 0) {
            // walk through function body and remove used mutable ptrs
            // to do this, we find the block decl
            var i = node_idx;

            while (i < tree.nodes.len) : (i += 1) {
                const fn_decl = tree.nodes.get(i);
                // TODO: can we just skip to the fn_decl instead of doing the fullProto stuff?
                if (fn_decl.tag != .fn_decl) return;
                const block = tree.nodes.get(fn_decl.data.rhs);

                var cur_node = block.data.lhs;
                var end = block.data.rhs;

                if (cur_node > 0 and end > 0) {
                    while (cur_node < end) : (cur_node += 1) {
                        check_ptr_usage(&mutable_ptr_token_indices, tree.nodes.get(cur_node), &tree);
                    }
                    self.last_enforced_fn_node_idx = end;
                } else if (cur_node > 0) {
                    // loop over the block
                    while (cur_node < tree.nodes.len) : (cur_node += 1) {
                        const node = tree.nodes.get(cur_node);
                        if (is_block(node.tag)) break;
                        check_ptr_usage(&mutable_ptr_token_indices, tree.nodes.get(cur_node), &tree);
                    }
                    self.last_enforced_fn_node_idx = cur_node + 1;
                } else {
                    self.last_enforced_fn_node_idx = i + 1;
                }
                break;
            }

            for (mutable_ptr_token_indices.items) |tok| {
                const location = tree.tokenLocation(0, tok);
                try fault_tracker.add(analysis.SourceCodeFault{
                    .line_number = location.line + 1, // is +1 really right here?
                    .column_number = location.column,
                    .fault_type = analysis.SourceCodeFaultType{ .PointerParamNotConst = tree.tokenSlice(tok) },
                });
            }
        }
    }
};

// Checks if any mutable_ptr_token_indices are mutated in node and if so, removes them from the list
// TODO: why doesn't it notice that the pointer is used in swapRemove?
fn check_ptr_usage(
    mutable_ptr_token_indices: *std.ArrayList(u32),
    node: std.zig.Ast.Node,
    tree: *const std.zig.Ast,
) void {
    switch (node.tag) {
        .assign => {
            for (mutable_ptr_token_indices.items, 0..) |ptr_ident, i| {
                // TODO: can optimize by tokenSlice()ing once and passing around?
                if (node_has_identifier(node.data.lhs, tree.tokenSlice(ptr_ident), tree)) {
                    _ = mutable_ptr_token_indices.swapRemove(i);
                }
            }
        },
        // does not mutate
        // actually wait, TODO: does ptr_type_aligned ever mutate a pointer in pointer-to-pointer situations?
        .identifier, .string_literal, .number_literal, .ptr_type_aligned, .root => {},
        // these just hold other stuff
        .if_simple, .equal_equal, .call_one, .struct_init_dot_two, .struct_init_dot_comma => {
            // we must check them both!
            check_ptr_usage(mutable_ptr_token_indices, tree.nodes.get(node.data.lhs), tree);
            check_ptr_usage(mutable_ptr_token_indices, tree.nodes.get(node.data.rhs), tree);
        },
        // variable declaration
        // var a: lhs = rhs
        .simple_var_decl => check_ptr_usage(mutable_ptr_token_indices, tree.nodes.get(node.data.rhs), tree),
        .block_two, .block_two_semicolon => {
            if (node.data.rhs > node.data.lhs) {
                var cur_node = node.data.lhs;
                while (cur_node < node.data.rhs) : (cur_node += 1) {
                    check_ptr_usage(mutable_ptr_token_indices, tree.nodes.get(cur_node), tree);
                }
            } else {
                // gosh darn it
                // loop over the block
                var cur_node = node.data.lhs;
                while (cur_node < tree.nodes.len) : (cur_node += 1) {
                    const next = tree.nodes.get(cur_node);
                    if (is_block(next.tag)) break;
                    check_ptr_usage(mutable_ptr_token_indices, next, tree);
                }
            }
        },
        // function call
        .call => {
            // lhs is the function
            // looks like we need to cache function names to see which parameters they mutate?
            check_ptr_usage(mutable_ptr_token_indices, tree.nodes.get(node.data.lhs), tree);
            // rhs is a list of parameters
            const extra_data = tree.extraData(node.data.rhs, std.zig.Ast.Node.SubRange);
            for (tree.extra_data[extra_data.start..extra_data.end]) |param| {
                check_ptr_usage(mutable_ptr_token_indices, tree.nodes.get(param), tree);
            }
        },
        .field_access => {
            check_ptr_usage(mutable_ptr_token_indices, tree.nodes.get(node.data.lhs), tree);
            const token = tree.tokenSlice(node.data.rhs);
            std.debug.print("field_access token: {s}\n", .{token});
        },

        // TODO: implement more of these
        else => {
            const loc = tree.tokenLocation(0, node.main_token);
            std.debug.print(
                "Don't know if {} at {}:{} mutates a pointer\n",
                .{ node.tag, loc.line + 1, loc.column },
            );
        },
    }
}

fn is_block(tag: std.zig.Ast.Node.Tag) bool {
    switch (tag) {
        .block, .block_two, .block_semicolon, .block_two_semicolon => return true,
        else => return false,
    }
}

fn node_has_identifier(node_idx: std.zig.Ast.Node.Index, ident: []const u8, tree: *const std.zig.Ast) bool {
    const node_ident = get_identifier(node_idx, tree);
    return std.mem.eql(u8, ident, node_ident);
}

// TODO: more efficient to pass nodeindex?
fn get_identifier(node_idx: std.zig.Ast.Node.Index, tree: *const std.zig.Ast) []const u8 {
    const node = tree.nodes.get(node_idx);
    switch (node.tag) {
        .identifier => return tree.tokenSlice(node.main_token),
        // rhs is the ID token
        .ptr_type_aligned => return get_identifier(node.data.rhs, tree),
        // lhs is the ID of the accessed field
        .field_access => return get_identifier(node.data.lhs, tree),
        else => {
            const loc = tree.tokenLocation(0, node.main_token);
            _ = loc;
            // std.debug.print(
            //     "Don't know how to get identifier from node {any} at {}:{}\n",
            //     .{ node.tag, loc.line + 1, loc.column },
            // );
            return "";
        },
    }
}
