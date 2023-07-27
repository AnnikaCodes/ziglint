const std = @import("std");
const dupe = @import("std");
const builtin = @import("builtin");

fn cool() void {
    std.debug.print("{}", .{"cool"});
    dupe.debug.print("{}", .{builtin.os});
}
