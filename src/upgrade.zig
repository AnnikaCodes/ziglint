//! Handles upgrading the ziglint binary.

const std = @import("std");

const RELEASE_API_URI = std.Uri.parse("https://api.github.com/repos/AnnikaCodes/ziglint/releases/latest") catch unreachable;
const MAX_API_RESPONSE_SIZE = 64 * 1024; // 64 kilobyes

const GithubReleaseAsset = struct {
    url: []const u8,
    name: []const u8,

    pub fn format(value: GithubReleaseAsset, comptime fmt: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        try writer.print("GithubReleaseAsset{{ .name = \"{s}\", .url = \"{s}\" }}", .{value.name, value.url});
    }
};

// The GitHub API response for a release.
// See the schema here: https://docs.github.com/en/rest/releases/releases?apiVersion=2022-11-28#get-the-latest-release
// We ignore fields that aren't necessary for `ziglint upgrade`.
const GithubRelease = struct {
    name: []const u8,
    assets: []GithubReleaseAsset,

    pub fn format(value: GithubRelease, comptime fmt: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        try writer.print("GithubRelease{{\n", .{});
        inline for (std.meta.fields(GithubRelease)) |field| {
            try writer.print("    .{s} = ", .{field.name});
            switch (field.type) {
                []const u8 => try writer.print("\"{s}\",\n", .{@field(value, field.name)}),
                []GithubReleaseAsset => {
                    try writer.print("[\n", .{});
                    for (@field(value, field.name)) |asset| {
                        try writer.print("        {},\n", .{asset});
                    }
                    try writer.print("    ],\n", .{});
                },
                else => try writer.print("{},\n", .{@field(value, field.name)}),
            }
        }
        try writer.print("}}", .{});
    }
};

pub fn upgrade(alloc: std.mem.Allocator, override_url: ?[]const u8) !void {
    const api_url = if (override_url == null) RELEASE_API_URI else std.Uri.parse(override_url.?) catch |err| errblk: {
        std.log.err("couldn't parse specified API URL '{s}' ({}); using the default GitHub endpoint instead", .{override_url.?, err});
        break :errblk RELEASE_API_URI;
    };

    // attempt to access the API endpoint and parse its JSON
    var client = std.http.Client { .allocator = alloc };
    defer client.deinit();

    var request = try client.request(.GET, api_url, .{ .allocator = alloc }, .{});
    defer request.deinit();

    try request.start();
    try request.wait();

    var request_buffer = try alloc.alloc(u8, MAX_API_RESPONSE_SIZE);
    defer alloc.free(request_buffer);

    const raw_response = request_buffer[0..try request.readAll(request_buffer)];
    var latest_release = try std.json.parseFromSlice(GithubRelease, alloc, raw_response, .{ .ignore_unknown_fields = true });
    defer std.json.parseFree(GithubRelease, alloc, latest_release);
    std.debug.print("raw JSON: {s}\n", .{raw_response});
    std.debug.print("parsed JSON: {}\n", .{latest_release});
}
