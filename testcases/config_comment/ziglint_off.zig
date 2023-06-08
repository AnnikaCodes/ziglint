const std = @import("std");

pub fn main() void {
    std.debug.print("This line is over 100 characters long. I wonder if it will it trigger a linter error?\n");
    // ziglint: off
    std.debug.print("This line is over 100 characters long. I wonder if it will it trigger a linter error?\n");
    std.debug.print("This line is over 100 characters long. I wonder if it will it trigger a linter error?\n");
    std.debug.print("This line is over 100 characters long. I wonder if it will it trigger a linter error?\n"); // ziglint: off
}
// zig fmt: off
pub fn should_be_const_1(ptr: *u8) void { _ = ptr; }
pub fn should_be_const_2(ptr: *u8) void { _ = ptr; } // ziglint: off
pub fn should_be_const_3(ptr: *u8) void { _ = ptr; }
// ziglint: off
pub fn should_be_const_4(ptr: *u8) void { _ = ptr; }
