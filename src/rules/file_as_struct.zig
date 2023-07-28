//! Check for file name capitalization in the presence of top level fields.

const std = @import("std");
const analysis = @import("../analysis.zig");

pub const FileAsStruct = struct {
    pub fn check_tree(
        self: *FileAsStruct,
        allocator: std.mem.Allocator,
        fault_tracker: *analysis.SourceCodeFaultTracker,
        file_name: []const u8,
        tree: std.zig.Ast,
    ) !void {
        _ = self;
        _ = allocator;

        const tags = tree.nodes.items(.tag);
        const rootDecls = tree.rootDecls();

        const has_top_level_fields = for (rootDecls) |item| {
            if (tags[item].isContainerField()) break true;
        } else false;

        const capitalized = std.ascii.isUpper(std.fs.path.basename(file_name)[0]);
        if (has_top_level_fields != capitalized) {
            try fault_tracker.add(analysis.SourceCodeFault{
                .line_number = 1,
                .column_number = 1,
                .fault_type = .{ .FileAsStruct = !capitalized },
            });
        }
    }
};
