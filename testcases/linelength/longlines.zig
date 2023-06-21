// zig fmt: off
fn yup() void {
    this_is_a_really_really_really_really_really_really_really_really_really_really_really_really_really_long_line();
    const this = "one"; has_got(&lots).of("identifiers on it!"); and_yet("it still is TOO LONG for the line length limit");
    // very long comment expressing my frustration with the early stages of Zig documentation: AAAAAAAAAAAAAAAAAAAAAAAA
    if (1 < 128) std.debug.print("Hello, world!\n", .{}) else @panic("this line is 100 characters");
}
// zig fmt: on
