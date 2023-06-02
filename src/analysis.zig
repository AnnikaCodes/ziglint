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
const SourceCodeFault = struct {
    line_number: usize,
    column_number: usize,
    fault_type: SourceCodeFaultType,
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
    max_line_length: u32 = 0,
    enforce_const_pointers: bool = false,

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
    pub fn analyze(self: *const ASTAnalyzer, allocator: std.mem.Allocator, tree: std.zig.Ast) !std.ArrayList(SourceCodeFault) {
        var faults = std.ArrayList(SourceCodeFault).init(allocator);

        // Enforce line length as needed
        if (self.max_line_length != 0) {
            var current_line_number: u32 = 1;
            var current_line_length: u32 = 0;
            for (tree.source, 0..) |c, idx| {
                current_line_length += 1;
                if (c == '\n' or tree.source[idx + 1] == 0 or (c == '\r' and tree.source[idx + 1] != '\n')) {
                    // The line has ended
                    if (current_line_length > self.max_line_length) {
                        try faults.append(SourceCodeFault{
                            .line_number = current_line_number,
                            .column_number = self.max_line_length,
                            .fault_type = SourceCodeFaultType{ .LineTooLong = current_line_length },
                        });
                    }
                    current_line_number += 1;
                    current_line_length = 0;
                }
            }
        }

        // TODO: look through AST nodes for other rule enforcements
        var i: u32 = 0;
        const tokens = tree.tokens.toMultiArrayList();
        const nodes = tree.nodes.toMultiArrayList();

        std.debug.print("\n\n", .{});
        var q: u32 = 0;
        while (q < tokens.len) : (q += 1) {
            std.debug.print("\ntokens[{}] = {s}", .{ q, tree.tokenSlice(q) });
        }
        q = 0;
        while (q < nodes.len) : (q += 1) {
            std.debug.print("\nnodes[{}] = {}", .{ q, nodes.get(q) });
        }
        q = 0;
        while (q < tree.extra_data.len) : (q += 1) {
            std.debug.print("\nextra_data[{}] = {}", .{ q, tree.extra_data[q] });
        }

        var const_ptr_enforced_fn_token_indices = std.ArrayList(u32).init(allocator);
        defer const_ptr_enforced_fn_token_indices.deinit();
        while (i < nodes.len) : (i += 1) {
            const node = nodes.get(i);
            _ = node;
            // Is it a function prototype? If so, we will need to check const pointer enforcement
            var buffer: [1]u32 = [1]u32{0};
            const fullProto = tree.fullFnProto(&buffer, i);
            // TODO: can we know the length ahead of time?
            var mutable_ptr_token_indices = std.ArrayList(u32).init(allocator);
            defer mutable_ptr_token_indices.deinit();
            var buf2: [2]u32 = [2]u32{ 0, 0 };
            const fullContainer = tree.fullContainerField(i);
            _ = buf2;

            std.debug.print("\nfullContainer = {any}\nmembers = {}", .{ fullContainer, 0 });

            if (self.enforce_const_pointers and fullProto != null) {
                const name_token_idx = fullProto.?.name_token.?;
                if (index_of(u32, &const_ptr_enforced_fn_token_indices, name_token_idx) != null) {
                    // We already enforced this function
                    continue;
                }
                try const_ptr_enforced_fn_token_indices.append(name_token_idx);

                for (fullProto.?.ast.params) |param_node_idx| {
                    const fullPtrType = tree.fullPtrType(param_node_idx);
                    if (fullPtrType == null) continue; // not a pointer
                    if (fullPtrType.?.const_token == null) { // pointer is mutable
                        std.debug.print("FOUND A MUTABLE POINTER: {any}, {s}\n", .{ fullPtrType, get_identifier(param_node_idx - 1, &tree) });
                        // subtract 2 since main_token is the asterisk - we skip the '*' and the ':'
                        try mutable_ptr_token_indices.append(fullPtrType.?.ast.main_token - 2);
                    }
                }
                if (mutable_ptr_token_indices.items.len > 0) {
                    // walk through function body and remove used mutable ptrs
                    // to do this, we find the block decl
                    var j = i;
                    std.debug.print("\nBEFORE: mutable_ptr_token_indices = {any}\n", .{mutable_ptr_token_indices.items});

                    while (j < nodes.len) : (j += 1) {
                        const block = nodes.get(j);
                        if (block.tag == .block_two or block.tag == .block_two_semicolon) {
                            const start = block.data.lhs;
                            const end = block.data.rhs;
                            if (start == 0) {
                                check_ptr_usage(&mutable_ptr_token_indices, nodes.get(end), &tree);
                            } else if (end == 0) {
                                check_ptr_usage(&mutable_ptr_token_indices, nodes.get(start), &tree);
                            } else {
                                var k = start;
                                while (k < end) : (k += 1) {
                                    check_ptr_usage(&mutable_ptr_token_indices, nodes.get(k), &tree);
                                }
                            }
                            break;
                        } else if (block.tag == .block or block.tag == .block_semicolon) {
                            // empty block
                            break;
                        }
                    }
                    std.debug.print("\nmutable_ptr_token_indices = {any}\n", .{mutable_ptr_token_indices.items});
                    for (mutable_ptr_token_indices.items) |tok| {
                        const location = tree.tokenLocation(0, tok);
                        try faults.append(SourceCodeFault{
                            .line_number = location.line + 1, // TODO
                            .column_number = location.column, // TODO
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
                    std.debug.print("Removing mutable pointer from list: {s}\n", .{tree.tokenSlice(ptr_ident)});
                    _ = mutable_ptr_token_indices.swapRemove(i);
                }
            }
        },
        else => std.debug.print("Don't know if {} mutates a pointer\n", .{node.tag}),
    }
}

fn node_has_identifier(node_idx: std.zig.Ast.Node.Index, ident: []const u8, tree: *const std.zig.Ast) bool {
    const node_ident = get_identifier(node_idx, tree);
    return std.mem.eql(u8, ident, node_ident);
}

// TODO: more efficient to pass nodeindex?
fn get_identifier(node_idx: std.zig.Ast.Node.Index, tree: *const std.zig.Ast) []const u8 {
    const node = tree.nodes.get(node_idx);
    std.debug.print("get_identifier: node = {any}, tree.tokenSlice(mainTok)={s}\n", .{ node, tree.tokenSlice(node.main_token) });
    switch (node.tag) {
        .identifier => return tree.tokenSlice(node.main_token),
        else => {
            std.debug.print("Don't know how to get identifier from node: {any}\n", .{node.tag});
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

            const faults = try analyzer.analyze(std.testing.allocator, tree);
            defer faults.deinit();

            std.debug.print("faults: {any}\n", .{faults.items});
            std.debug.print("fault1: {any}\n", .{faults.items[0].fault_type});
            try std.testing.expectEqual(case.expected_faults.len, faults.items.len);

            if (case.expected_faults.len == 0) {
                try std.testing.expectEqual(faults.items.len, 0);
            } else {
                for (faults.items, 0..) |fault, idx| {
                    try std.testing.expectEqual(case.expected_faults[idx].line_number, fault.line_number);
                    try std.testing.expectEqual(case.expected_faults[idx].column_number, fault.column_number);
                    try std.testing.expectEqualDeep(case.expected_faults[idx].fault_type, fault.fault_type);
                }
            }
        }
    }

    test "line-length lints" {
        var analyzer = ASTAnalyzer{};
        analyzer.set_max_line_length(120);
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
        // if (@import("builtin").is_test) return error.SkipZigTest; // TODO: implementation

        var analyzer = ASTAnalyzer{};
        analyzer.enforce_const_pointers = true;

        try run_tests(&analyzer, &.{
            // TestCase{
            //     // Pointer is OK: const & unused
            //     .source = "fn foo1(ptr: *const u8) void {}",
            //     .expected_faults = &.{},
            // },

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

            // TestCase{
            //     // Pointer is OK: const & used immutably
            //     .source = "fn foo3(ptr: *const u8) u8 { return *ptr + 1; }",
            //     .expected_faults = &.{},
            // },

            // TestCase{
            //     // Pointer is OK: mutable and used mutably
            //     .source = "fn foo4(ptr: *u8) void { *ptr = 1; std.debug.print('lol'); secret_third_thing(); }",
            //     .expected_faults = &.{},
            // },

            // TestCase{
            //     // Pointer is OK: mutable and used mutably
            //     .source = "fn foo6(ptr: *u8) void { *ptr = 1; }",
            //     .expected_faults = &.{},
            // },

            // TestCase{
            //     // Pointer is OK: mutable and POSSIBLY used mutably
            //     .source =
            //     \\fn foo5(ptr: *u8) void {
            //     \\   if (*ptr == 0) {
            //     \\        *ptr = 1;
            //     \\    }
            //     ,
            //     .expected_faults = &.{},
            // },
        });
    }
};

fn get_token_text(token: std.zig.Ast.TokenIndex, tree: std.zig.Ast) []const u8 {
    return tree.source[tree.tokens.get(token).start..tree.tokens.get(token + 1).start];
}
