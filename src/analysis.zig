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

const AST = @import("std").zig.Ast;
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
    max_line_length: ?u32 = undefined,
    enforce_const_pointers: bool = false,

    pub fn set_max_line_length(self: *ASTAnalyzer, max_line_length: u32) void {
        self.max_line_length = max_line_length;
    }

    pub fn disable_max_line_length(self: *ASTAnalyzer) void {
        self.max_line_length = undefined;
    }

    // Actually analyzes AST.
    pub fn analyze(self: *const ASTAnalyzer, ast: AST) []const SourceCodeFault {
        unreachable("TODO: implement AST analysis");
        _ = self;
        _ = ast;
    }
};

test "line-length limit" {
    const std = @import("std");
    var a = ASTAnalyzer{};
    a.set_max_line_length(120);
    const source: [:0]const u8 = "std.debug.print(skerjghrekgkrejhgkjerhgkjhrjkhgjksrhgjkrshjgkhsrjkghksjfhgkjhskjghkjfhjkgsfkjghdfkhgsjkfhgkjsdhgkjdhskgjhdskjghdksjghdskjghdhgksdhgjkshjkds);";

    var tree = try std.zig.parse(std.testing.allocator, source);
    defer tree.deinit(std.testing.allocator);
    const faults = a.analyze(tree);

    try std.testing.expectEqual(@intCast(usize, 1), faults.len);
    const fault = faults[0];
    try std.testing.expectEqual(@intCast(usize, 1), fault.line_number);
    try std.testing.expect(fault.fault_type == .LineTooLong);
    try std.testing.expectEqual(source.len, fault.fault_type.LineTooLong);

    a.disable_max_line_length();
    const faults_empty = a.analyze(tree);
    try std.testing.expectEqual(@intCast(usize, 0), faults_empty.len);
}
