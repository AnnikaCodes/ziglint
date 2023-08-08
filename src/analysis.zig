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
const SeverityLevel = @import("main.zig").SeverityLevel;
// const banned_comment_phrase_rule = @import("rules/banned_comment_phrases.zig");
// const BannedPhraseConfig = banned_comment_phrase_rule.BannedPhraseConfig;

// A fault in the source code detected by the linter.
// pub const SourceCodeFault = struct {
//     line_number: usize,
//     column_number: usize,
//     fault_type: SourceCodeFaultType,
//     ast_error: ?std.zig.Ast.Error = null, // only there if fault_type == ASTError
// };

// pub const SourceCodeFaultTracker = struct {
//     faults: std.ArrayList(SourceCodeFault),
//     ziglint_disabled_lines: std.AutoHashMap(usize, void),

//     pub fn new(alloc: std.mem.Allocator) SourceCodeFaultTracker {
//         return SourceCodeFaultTracker{
//             .faults = std.ArrayList(SourceCodeFault).init(alloc),
//             // https://github.com/ziglang/zig/issues/6919 :(
//             .ziglint_disabled_lines = std.AutoHashMap(usize, void).init(alloc),
//         };
//     }

//     pub fn disable_line(self: *SourceCodeFaultTracker, line_number: u32) !void {
//         try self.ziglint_disabled_lines.put(line_number, {});
//         for (self.faults.items, 0..) |fault, idx| {
//             if (fault.line_number == line_number) {
//                 _ = self.faults.swapRemove(idx);
//             }
//         }
//     }

//     pub fn add(self: *SourceCodeFaultTracker, fault: SourceCodeFault) !void {
//         if (self.ziglint_disabled_lines.get(fault.line_number) != null) {
//             return;
//         }
//         try self.faults.append(fault);
//     }

//     pub fn deinit(self: *SourceCodeFaultTracker) void {
//         self.faults.deinit();
//         self.ziglint_disabled_lines.deinit();
//     }
// };

pub const SourceCodeFaultType = union(enum) {
    // Line was too long. Value is the length of the line.
    LineTooLong: usize,
    // Import was already imported elswhere in the file. Value is the name of the import.
    DupeImport: []const u8,
    // Error with the AST. Error is in SourceCodeFault ast_error field.
    ASTError,
    // The source code i s not formatted according to Zig standards.
    ImproperlyFormatted,
    // File is incorrectly capitalized. Value is true if the file should be capitalized.
    FileAsStruct: bool,
    /// A comment contains a banned word. Value is the banned word + severity level.
    BannedCommentPhrase: struct {
        phrase: []const u8,
        comment: []const u8,
        severity_level: SeverityLevel,
    },
};

pub const ASTAnalyzer = struct {
    // 0 for no checking
    max_line_length: u32 = 100,
    check_format: bool = true,
    dupe_import: bool = false,
    file_as_struct: bool = false,
    // banned_comment_phrases: ?BannedPhraseConfig = null,

    pub fn deinit(self: *ASTAnalyzer) void {
        if (self.check_format_buffer) |*buf| {
            buf.deinit();
        }
    }

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
    pub fn analyze(
        self: *const ASTAnalyzer,
        alloc: std.mem.Allocator,
        file_name: []const u8,
        tree: std.zig.Ast,
        check_format_buffer: ?*std.ArrayList(u8),
        // ) !SourceCodeFaultTracker {
    ) !void {
        // var faults = SourceCodeFaultTracker.new(alloc);

        // Enforce line length as needed
        // is there a better way to do ziglint ignores via the tokenizer or something?
        // Line length hasn't yet been split off into its own rule since ziglint: ignore happens here too
        // var max_line_length = @import("rules/max_line_length.zig").MaxLineLength{ .limit = self.max_line_length };
        // const banned_comment_phrases = banned_comment_phrase_rule.BannedCommentPhrases{
        //     .config = self.banned_comment_phrases,
        // };

        // var current_line_number: u32 = 1;
        // _ = current_line_number;
        // var current_line_start: usize = 0;
        // _ = current_line_start;
        // var current_line_length: u32 = 0;
        // _ = current_line_length;
        // var comment_start_idx: ?usize = null;
        // _ = comment_start_idx; // null if no comment
        // var line_has_non_comment_content = false;
        // _ = line_has_non_comment_content;
        // for (tree.source, 0..) |c, idx| {
        //     current_line_length += 1;
        //     // if (comment_start_idx == null and c == '/' and tree.source[idx + 1] == '/') {
        //     //     // Comment
        //     //     comment_start_idx = idx;
        //     // }
        //     // if (!line_has_non_comment_content and comment_start_idx == null and c != '/' and c != '\t' and c != ' ') {
        //     //     // std.debug.print("LINE {}: NOT A COMMENT: '{c}'\n", .{current_line_number, c});
        //     //     line_has_non_comment_content = true;
        //     // }

        //     if (c == '\n' or tree.source[idx + 1] == 0 or (c == '\r' and tree.source[idx + 1] != '\n')) {
        //         // The line has ended - run per-line rules
        //         const line = tree.source[current_line_start..idx];
        //         if (self.max_line_length != 0) {
        //             try max_line_length.check_line(alloc, line, current_line_number);
        //         }

        //         // if (comment_start_idx) |start_idx| {
        //         //     // check for ziglint: ignore remark
        //         //     if (idx > "ziglint: ignore\n".len and
        //         //         std.mem.eql(u8, tree.source[(idx - "ziglint: ignore".len)..idx], "ziglint: ignore"))
        //         //     {
        //         //         // if it's standalone, then disable ziglint for the next line
        //         //         // otherwise, disable for this line
        //         //         const ln = if (line_has_non_comment_content) current_line_number else current_line_number + 1;
        //         //         try faults.disable_line(ln);
        //         //     }

        //         //     // run per-comment rules
        //         //     const comment = tree.source[start_idx..idx];
        //         //     if (self.banned_comment_phrases != null) {
        //         //         try banned_comment_phrases.check_comment(alloc, &faults, comment, current_line_number);
        //         //     }
        //         // }

        //         current_line_number += 1;
        //         current_line_length = 0;
        //         current_line_start = idx + 1;
        //         comment_start_idx = null;
        //         line_has_non_comment_content = false;
        //     }
        // }

        // var file_as_struct = @import("rules/file_as_struct.zig").FileAsStruct{};

        // per-tree rules
        // if (self.check_format) try check_format.check_tree(alloc, &faults, file_name, tree);
        if (self.check_format) {
            var check_format = @import("rules/check_format.zig").CheckFormat{};
            if (check_format_buffer == null) {
                @panic("check_format_buffer must be set if check_format is enabled");
            }
            try check_format.check_tree(alloc, file_name, tree, check_format_buffer.?);
        }
        // if (self.file_as_struct) try file_as_struct.check_tree(alloc, &faults, file_name, tree);

        // TODO: look through AST nodes for other rule enforcements
        // var dupe_import = @import("rules/dupe_import.zig").DupeImport.init(alloc);
        // defer dupe_import.deinit();

        // var i: u32 = 0;
        // while (i < tree.nodes.len) : (i += 1) {
        //     // run per-node rules
        //     if (self.dupe_import) try dupe_import.check_node(alloc, &faults, tree, i);
        // }
        // return faults;
    }
};

fn index_of(comptime T: type, array: *const std.ArrayList(T), item: T) ?usize {
    var i: usize = 0;
    while (i < array.items.len) : (i += 1) {
        if (array.items[i] == item) return i;
    }
    return null;
}

// // TODO: run tests in CI
// test {
//     _ = Tests;
// }

// const Tests = struct {
//     const TestCase = struct {
//         source: [:0]const u8,
//         expected_faults: []const SourceCodeFault,
//     };

//     fn run_tests(analyzer: *const ASTAnalyzer, comptime cases: []const TestCase) !void {
//         inline for (cases) |case| {
//             var tree = try std.zig.Ast.parse(std.testing.allocator, case.source, .zig);
//             defer tree.deinit(std.testing.allocator);

//             var faults = try analyzer.analyze(std.testing.allocator, "name", tree);
//             defer faults.deinit();

//             try std.testing.expectEqual(case.expected_faults.len, faults.faults.items.len);

//             if (case.expected_faults.len == 0) {
//                 try std.testing.expectEqual(faults.faults.items.len, 0);
//             } else {
//                 for (faults.faults.items, 0..) |fault, idx| {
//                     try std.testing.expectEqual(case.expected_faults[idx].line_number, fault.line_number);
//                     try std.testing.expectEqual(case.expected_faults[idx].column_number, fault.column_number);
//                     // Zig is annoying about the .ASTError case but those are covered in integration rather than here
//                     // since we're not really testing our own logic anyway
//                     if (case.expected_faults[idx].fault_type != .ASTError) {
//                         try std.testing.expectEqualDeep(case.expected_faults[idx].fault_type, fault.fault_type);
//                     }
//                 }
//             }
//         }
//     }

//     test "line-length lints" {
//         var analyzer = ASTAnalyzer{
//             .max_line_length = 120,
//             .check_format = false,
//         };
//         try run_tests(&analyzer, &.{
//             TestCase{
//                 // ziglint: ignore
//                 .source = "std.debug.print(skerjghrekgkrejhgkjerhgkjhrjkhgjksrhgjkrshjgkhsrjkghksjfhgkjhskjghkjfddadwhjkwjfkwjfkewjfkjwkfwkgsfkjfwjfhweewtjewtwehjtwwrewghdfkhgsjkjkds);",
//                 .expected_faults = &.{
//                     SourceCodeFault{
//                         .line_number = 1,
//                         .column_number = 120,
//                         .fault_type = SourceCodeFaultType{ .LineTooLong = 156 },
//                         .ast_error = null,
//                     },
//                 },
//             },
//             TestCase{
//                 .source =
//                 \\var x = 0;
//                 \\// This is a comment
//                 // ziglint: ignore
//                 \\       var                        jjjjj                           =                                                    10;
//                 ,
//                 .expected_faults = &.{
//                     SourceCodeFault{
//                         .line_number = 3,
//                         .column_number = 120,
//                         .fault_type = SourceCodeFaultType{ .LineTooLong = 121 },
//                     },
//                 },
//             },
//         });
//     }
// };

// fn get_token_text(token: std.zig.Ast.TokenIndex, tree: std.zig.Ast) []const u8 {
//     return tree.source[tree.tokens.get(token).start..tree.tokens.get(token + 1).start];
// }
