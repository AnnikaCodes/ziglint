//! Analysis logic
//!
//! Overall idea: `struct` with methods for analysis
//!
//! Set up options once (at struct initialization or with struct methods),
//! then you can call methods to analyze AST as many times as you want.
//!
//! This also makes unit-testing easier since we can just feed in AST into a unit test
//! (loading code from files and parsing raw Zig source to AST happens elsewhere).
//!
//! The AST-analyzing function should return a list of errors, without stopping when it encounters one.

const std = @import("std");
// A fault in the source code detected by the linter.
pub const SourceCodeFault = struct {
    line_number: usize,
    column_number: usize,
    fault_type: SourceCodeFaultType,
};

const SourceCodeFaultTracker = struct {
    faults: std.ArrayList(SourceCodeFault),
    ziglint_disabled_lines: std.AutoHashMap(usize, void),

    pub fn new(allocator: std.mem.Allocator) SourceCodeFaultTracker {
        return SourceCodeFaultTracker{
            .faults = std.ArrayList(SourceCodeFault).init(allocator),
            // https://github.com/ziglang/zig/issues/6919 :(
            .ziglint_disabled_lines = std.AutoHashMap(usize, void).init(allocator),
        };
    }

    pub fn disable_line(self: *SourceCodeFaultTracker, line_number: u32) !void {
        try self.ziglint_disabled_lines.put(line_number, {});
        for (self.faults.items, 0..) |fault, idx| {
            if (fault.line_number == line_number) {
                _ = self.faults.swapRemove(idx);
            }
        }
    }

    pub fn add(self: *SourceCodeFaultTracker, fault: SourceCodeFault) !void {
        if (self.ziglint_disabled_lines.get(fault.line_number) != null) {
            return;
        }
        try self.faults.append(fault);
    }

    pub fn deinit(self: *SourceCodeFaultTracker) void {
        self.faults.deinit();
        self.ziglint_disabled_lines.deinit();
    }
};

const SourceCodeFaultType = union(enum) {
    // Line was too long. Value is the length of the line.
    LineTooLong: u32,
    // Pointer parameter in a function wasn't *const. Value is the name of the parameter.
    // TODO should this include type?
    PointerParamNotConst: []const u8,
};

pub const ASTAnalyzer = struct {
    // 0 for no checking
    max_line_length: u32 = 120,
    enforce_const_pointers: bool = true,

    pub fn set_max_line_length(self: *ASTAnalyzer, max_line_length: u32) void {
        self.max_line_length = max_line_length;
    }

    pub fn disable_max_line_length(self: *ASTAnalyzer) void {
        self.max_line_length = 0;
    }

    // Actually analyzes AST.
    //
    // Caller must deinit the array.
    // TODO: can just return a slice?
    pub fn analyze(self: *const ASTAnalyzer, allocator: std.mem.Allocator, tree: std.zig.Ast) !SourceCodeFaultTracker {
        var faults = SourceCodeFaultTracker.new(allocator);

        // Enforce line length as needed
        // TODO: look for and store ziglint ignores here
        // is there a better way to do ziglint ignores via the tokenizer or something?
        var current_line_number: u32 = 1;
        var current_line_length: u32 = 0;
        var is_comment = false;
        var line_has_non_comment_content = false;
        for (tree.source, 0..) |c, idx| {
            current_line_length += 1;
            if (c == '/' and tree.source[idx + 1] == '/') {
                // Comment
                is_comment = true;
            }
            if (!line_has_non_comment_content and !is_comment and c != '/' and c != '\t' and c != ' ') {
                // std.debug.print("LINE {}: NOT A COMMENT: '{c}'\n", .{current_line_number, c});
                line_has_non_comment_content = true;
            }

            if (c == '\n' or tree.source[idx + 1] == 0 or (c == '\r' and tree.source[idx + 1] != '\n')) {
                // The line has ended
                if (self.max_line_length != 0 and current_line_length > self.max_line_length) {
                    try faults.add(SourceCodeFault{
                        .line_number = current_line_number,
                        .column_number = self.max_line_length,
                        .fault_type = SourceCodeFaultType{ .LineTooLong = current_line_length },
                    });
                }

                // check for ziglint: ignore remark
                // if (idx > "ziglint: ignore".len) std.debug.print("is_comment: {}, line: {}, treebit: '{s}'\n", .{is_comment, current_line_number, tree.source[(idx - "ziglint: ignore".len )..idx]});
                if (is_comment and
                    idx > "ziglint: ignore\n".len and
                    std.mem.eql(u8, tree.source[(idx - "ziglint: ignore".len)..idx], "ziglint: ignore"))
                {
                    // if it's standalone, then disable ziglint for the next line
                    // otherwise, disable for this line
                    const line = if (line_has_non_comment_content) current_line_number else current_line_number + 1;
                    try faults.disable_line(line);
                }

                current_line_number += 1;
                current_line_length = 0;
                is_comment = false;
                line_has_non_comment_content = false;
            }
        }

        // TODO: look through AST nodes for other rule enforcements
        var i: u32 = 0;

        // while (i < tree.nodes.len) : (i += 1) {
        //     const loc = tree.tokenLocation(0, tree.nodes.get(i).main_token);
        //     std.debug.print("nodes[{}]: {} ({}:{})\n", .{ i, tree.nodes.get(i).tag, loc.line + 1, loc.column });
        // }
        // i = 0;

        var last_enforced_fn_node_idx: u32 = 0;
        while (i < tree.nodes.len) : (i += 1) {
            if (i > last_enforced_fn_node_idx and self.enforce_const_pointers) {
                // Is it a function prototype? If so, we will need to check const pointer enforcement
                var buffer: [1]u32 = [1]u32{0};
                const fullProto = tree.fullFnProto(&buffer, i);
                if (fullProto == null) continue; // not a function prototype
                // std.debug.print("FOUND A FUNCTION PROTOTYPE: `{s}`\n", .{tree.tokenSlice(fullProto.?.name_token.?)});

                // TODO: can we know the length ahead of time?
                var mutable_ptr_token_indices = std.ArrayList(u32).init(allocator);
                defer mutable_ptr_token_indices.deinit();
                for (fullProto.?.ast.params) |param_node_idx| {
                    const fullPtrType = tree.fullPtrType(param_node_idx);
                    if (fullPtrType == null) continue; // not a pointer
                    if (fullPtrType.?.const_token == null) { // pointer is mutable
                        // subtract 2 since main_token is the asterisk - we skip the '*' and the ':'
                        const token = fullPtrType.?.ast.main_token - 2;
                        // std.debug.print("FOUND A MUTABLE POINTER: `{s}`\n", .{tree.tokenSlice(token)});
                        try mutable_ptr_token_indices.append(token);
                    }
                }
                if (mutable_ptr_token_indices.items.len > 0) {
                    // walk through function body and remove used mutable ptrs
                    // to do this, we find the block decl
                    var j = i;

                    while (j < tree.nodes.len) : (j += 1) {
                        const fn_decl = tree.nodes.get(j);
                        if (fn_decl.tag != .fn_decl) continue; // TODO: can we just skip to the fn_decl instead of doing the fullProto stuff?
                        const block = tree.nodes.get(fn_decl.data.rhs);

                        const loc = tree.tokenLocation(0, block.main_token);
                        std.log.debug("{} {}:{}\n", .{ block, loc.line + 1, loc.column });

                        var cur_node = block.data.lhs;
                        var end = block.data.rhs;
                        // std.debug.print("BLOCK: {} to {}\n", .{ cur_node, end });
                        if (cur_node > 0 and end > 0) {
                            while (cur_node < end) : (cur_node += 1) {
                                check_ptr_usage(&mutable_ptr_token_indices, tree.nodes.get(cur_node), &tree);
                            }
                            last_enforced_fn_node_idx = end;
                        } else if (cur_node > 0) {
                            // loop over th eblock
                            while (cur_node < tree.nodes.len) : (cur_node += 1) {
                                const node = tree.nodes.get(cur_node);
                                if (node.tag == .block or node.tag == .block_two or node.tag == .block_semicolon or node.tag == .block_two_semicolon) break;
                                check_ptr_usage(&mutable_ptr_token_indices, tree.nodes.get(cur_node), &tree);
                            }
                            last_enforced_fn_node_idx = cur_node + 1;
                        } else {
                            // std.log.warn("fn_decl has no block: {}\n", .{fn_decl});
                            last_enforced_fn_node_idx = j + 1;
                        }
                        break;
                    }

                    for (mutable_ptr_token_indices.items) |tok| {
                        const location = tree.tokenLocation(0, tok);
                        try faults.add(SourceCodeFault{
                            .line_number = location.line + 1, // is +1 really right here?
                            .column_number = location.column,
                            .fault_type = SourceCodeFaultType{ .PointerParamNotConst = tree.tokenSlice(tok) },
                        });
                    }
                }
            }
        }
        return faults;
    }
};

fn index_of(comptime T: type, array: *const std.ArrayList(T), item: T) ?usize {
    var i: usize = 0;
    while (i < array.items.len) : (i += 1) {
        if (array.items[i] == item) return i;
    }
    return null;
}
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
        .identifier, .string_literal, .number_literal, .ptr_type_aligned => {},
        // these just hold other stuff
        .if_simple, .equal_equal => {
            // lhs is the condition express, rhs is what is executed if it's true
            // we must check them both!
            check_ptr_usage(mutable_ptr_token_indices, tree.nodes.get(node.data.lhs), tree);
            check_ptr_usage(mutable_ptr_token_indices, tree.nodes.get(node.data.rhs), tree);
        },
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
                    if (next.tag == .block or next.tag == .block_two or next.tag == .block_semicolon or next.tag == .block_two_semicolon) break;
                    check_ptr_usage(mutable_ptr_token_indices, next, tree);
                }
            }
        },
        // TODO: implement more of these
        else => {
            // const loc = tree.tokenLocation(0, node.main_token);
            // std.debug.print("Don't know if {} at {}:{} mutates a pointer\n", .{ node.tag, loc.line + 1, loc.column });
        },
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
            // std.debug.print("Don't know how to get identifier from node {any} at {}:{}\n", .{ node.tag, loc.line + 1, loc.column });
            return "";
        },
    }
}

// TODO: run tests in CI
test {
    _ = Tests;
}

const Tests = struct {
    const TestCase = struct {
        source: [:0]const u8,
        expected_faults: []const SourceCodeFault,
    };

    fn run_tests(analyzer: *const ASTAnalyzer, comptime cases: []const TestCase) !void {
        inline for (cases) |case| {
            var tree = try std.zig.Ast.parse(std.testing.allocator, case.source, .zig);
            defer tree.deinit(std.testing.allocator);

            var faults = try analyzer.analyze(std.testing.allocator, tree);
            defer faults.deinit();

            try std.testing.expectEqual(case.expected_faults.len, faults.faults.items.len);

            if (case.expected_faults.len == 0) {
                try std.testing.expectEqual(faults.faults.items.len, 0);
            } else {
                for (faults.faults.items, 0..) |fault, idx| {
                    try std.testing.expectEqual(case.expected_faults[idx].line_number, fault.line_number);
                    try std.testing.expectEqual(case.expected_faults[idx].column_number, fault.column_number);
                    try std.testing.expectEqualDeep(case.expected_faults[idx].fault_type, fault.fault_type);
                }
            }
        }
    }

    test "line-length lints" {
        var analyzer = ASTAnalyzer{
            .max_line_length = 120,
            .enforce_const_pointers = false,
        };
        try run_tests(&analyzer, &.{
            TestCase{
                .source = "std.debug.print(skerjghrekgkrejhgkjerhgkjhrjkhgjksrhgjkrshjgkhsrjkghksjfhgkjhskjghkjfddadwhjkwjfkwjfkewjfkjwkfwkgsfkjfwjfhweewtjewtwehjtwwrewghdfkhgsjkjkds);",
                .expected_faults = &.{
                    SourceCodeFault{
                        .line_number = 1,
                        .column_number = 120,
                        .fault_type = SourceCodeFaultType{ .LineTooLong = 157 },
                    },
                },
            },
            TestCase{
                .source =
                \\var x = 0;
                \\// This is a comment
                \\       var                        jjjjj                           =                                                   10;
                ,
                .expected_faults = &.{
                    SourceCodeFault{
                        .line_number = 3,
                        .column_number = 120,
                        .fault_type = SourceCodeFaultType{ .LineTooLong = 121 },
                    },
                },
            },
        });
    }

    test "const-pointer enforcement" {
        var analyzer = ASTAnalyzer{
            .max_line_length = 0,
            .enforce_const_pointers = true,
        };

        try run_tests(&analyzer, &.{
            TestCase{
                // Pointer is OK: const & unused
                .source = "fn foo1(ptr: *const u8) void {}",
                .expected_faults = &.{},
            },

            TestCase{
                // Pointer is not OK: mutable and unused
                .source = "fn foo2(ptr: *u8) void {}",
                .expected_faults = &.{
                    SourceCodeFault{
                        .line_number = 1,
                        .column_number = 8,
                        .fault_type = SourceCodeFaultType{ .PointerParamNotConst = "ptr" },
                    },
                },
            },

            TestCase{
                // Pointer is OK: const & used immutably
                .source = "fn foo3(ptr: *const u8) u8 { return *ptr + 1; }",
                .expected_faults = &.{},
            },

            TestCase{
                // Pointer is OK: mutable and used mutably
                .source = "fn foo4(ptr: *u8) void { *ptr = 1; std.debug.print('lol'); secret_third_thing(); }",
                .expected_faults = &.{},
            },

            TestCase{
                // Pointer is OK: mutable and used mutably
                .source = "fn foo6(ptr: *u8) void { *ptr = 1; }",
                .expected_faults = &.{},
            },

            TestCase{
                // Pointer is OK: mutable and POSSIBLY used mutably
                .source =
                \\fn foo5(ptr: *u8) void {
                \\   if (*ptr == 0) {
                \\        *ptr = 1;
                \\    }
                \\}
                ,
                .expected_faults = &.{},
            },
        });
    }
};

fn get_token_text(token: std.zig.Ast.TokenIndex, tree: std.zig.Ast) []const u8 {
    return tree.source[tree.tokens.get(token).start..tree.tokens.get(token + 1).start];
}
