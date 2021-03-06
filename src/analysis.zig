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
    line_number: u32,
    column_number: u32,
    fault_type: SourceCodeFaultType,
};

const SourceCodeFaultType = union(enum) {
    // Line was too long. Value is the length of the line.
    LineTooLong: u32,
    // Pointer parameter in a function wasn't *const. Value is the type that it actually was.
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
            for (tree.source) |c, idx| {
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
        var i: usize = 0;
        const nodes = tree.nodes.toMultiArrayList();
        while (i < nodes.len) : (i += 1) {
            const node = nodes.get(i);
            // Is it a function prototype? If so, we will need to check const pointer enforcement
            if (self.enforce_const_pointers and (node.tag == .fn_proto_simple or
                node.tag == .fn_proto_multi or
                node.tag == .fn_proto_one or
                node.tag == .fn_proto))
            {
                // const ptr enforcement!
                switch (node.tag) {
                    .fn_proto_simple => unreachable("TODO: implement fn_proto_simple walking"),
                    .fn_proto_multi => unreachable("TODO: implement fn_proto_multi walking"),
                    .fn_proto_one => unreachable("TODO: implement fn_proto_one walking"),
                    .fn_proto => {
                        unreachable("TODO: implement fn_proto walking");
                    },
                    else => unreachable(
                        \\Something has gone severely wrong within ziglint (tag in if but not in switch).
                        \\Please file a bug at https://github.com/AnnikaCodes/ziglint
                    ),
                }
            }
        }
        return faults;
    }
};

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
            var tree = try std.zig.parse(std.testing.allocator, case.source);
            defer tree.deinit(std.testing.allocator);

            const faults = try analyzer.analyze(std.testing.allocator, tree);
            defer faults.deinit();

            try std.testing.expectEqual(case.expected_faults.len, faults.items.len);

            for (faults.items) |fault, idx| {
                try std.testing.expectEqual(case.expected_faults[idx].line_number, fault.line_number);
                try std.testing.expectEqual(case.expected_faults[idx].column_number, fault.column_number);
                try std.testing.expectEqual(case.expected_faults[idx].fault_type, fault.fault_type);
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
        if (@import("builtin").is_test) return error.SkipZigTest; // TODO: implementation

        var analyzer = ASTAnalyzer{};
        analyzer.enforce_const_pointers = true;

        try run_tests(&analyzer, &.{
            TestCase{
                // Pointer is OK: const & unused
                .source = "fn foo(ptr: *const u8) void {}",
                .expected_faults = &.{},
            },

            TestCase{
                // Pointer is not OK: mutable and unused
                .source = "fn foo(ptr: *u8) void {}",
                .expected_faults = &.{
                    SourceCodeFault{
                        .line_number = 1,
                        .column_number = 13,
                        .fault_type = SourceCodeFaultType{ .PointerParamNotConst = "*u8" },
                    },
                },
            },

            TestCase{
                // Pointer is OK: const & used immutably
                .source = "fn foo(ptr: *const u8) u8 { return *ptr + 1; }",
                .expected_faults = &.{},
            },

            TestCase{
                // Pointer is OK: mutable and used mutably
                .source = "fn foo(ptr: *mut u8) void { *ptr = 1; }",
                .expected_faults = &.{},
            },

            TestCase{
                // Pointer is OK: mutable and POSSIBLY used mutably
                .source =
                \\fn foo(ptr: *mut u8) void {
                \\   if (*ptr == 0) {
                \\        *ptr = 1;
                \\    }
                ,
                .expected_faults = &.{},
            },
        });
    }
};
