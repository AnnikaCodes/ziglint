const std = @import("std");

pub fn main() void {
    std.debug.print("This line is over 100 characters long. I wonder if it will it trigger a linter error?\n");
    // ziglint: ignore
    std.debug.print("This line is over 100 characters long. I wonder if it will it trigger a linter error?\n");
    std.debug.print("This line is over 100 characters long. I wonder if it will it trigger a linter error?\n");
    std.debug.print("This line is over 100 characters long. I wonder if it will it trigger a linter error?\n"); // ziglint: ignore
}
