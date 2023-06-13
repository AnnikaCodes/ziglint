//! Handles upgrading the ziglint binary.

const std = @import("std");
const builtin = @import("builtin");
const semver = @import("./semver.zig");

const RELEASE_API_URI = std.Uri.parse("https://api.github.com/repos/AnnikaCodes/ziglint/releases/latest") catch unreachable;
const MAX_API_RESPONSE_SIZE = 64 * 1024; // 64 kilobytes

const EXECUTABLE_ = std.Target.exeFileExtSimple(builtin.target.cpu.arch, builtin.target.os.tag);
const GithubReleaseAsset = struct {
    url: []const u8,
    name: []const u8,
    content_type: []const u8,
    size: u32,

    pub fn format(value: GithubReleaseAsset, comptime fmt: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        try writer.print("GithubReleaseAsset{{ .name = \"{s}\", .url = \"{s}\", .size = {}, .content_type = \"{s}\" }}", .{ value.name, value.url, value.size, value.content_type });
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

pub fn upgrade(alloc: std.mem.Allocator, current_version: semver.Version, override_url: ?[]const u8) !void {
    const api_url = if (override_url == null) RELEASE_API_URI else std.Uri.parse(override_url.?) catch |err| errblk: {
        std.log.err("couldn't parse specified API URL '{s}' ({}); using the default GitHub endpoint instead", .{ override_url.?, err });
        break :errblk RELEASE_API_URI;
    };

    // attempt to access the API endpoint and parse its JSON
    var client = std.http.Client{ .allocator = alloc };
    defer client.deinit();

    var api_request = try client.request(.GET, api_url, .{ .allocator = alloc }, .{});
    defer api_request.deinit();

    try api_request.start();
    try api_request.wait();

    var api_buffer = try alloc.alloc(u8, MAX_API_RESPONSE_SIZE);
    defer alloc.free(api_buffer);

    const raw_response = api_buffer[0..try api_request.readAll(api_buffer)];
    var latest_release = try std.json.parseFromSlice(GithubRelease, alloc, raw_response, .{ .ignore_unknown_fields = true });
    defer std.json.parseFree(GithubRelease, alloc, latest_release);
    std.debug.print("raw JSON: {s}\n", .{raw_response});
    std.debug.print("parsed JSON: {}\n", .{latest_release});

    var release_name = latest_release.name;
    const latest_version = semver.Version.parse(release_name) catch errblk: {
        // try cutting off the leading "v" if it exists
        if (release_name[0] == 'v') {
            release_name = release_name[1..];
            break :errblk semver.Version.parse(release_name[1..]) catch {
                log_failure_to_parse_version_and_exit(release_name);
            };
        }
        // cut off stuff before a space
        const space = std.mem.indexOf(u8, release_name, " ");
        if (space != null) {
            release_name = release_name[space.? + 1 ..];
            break :errblk semver.Version.parse(release_name) catch log_failure_to_parse_version_and_exit(release_name);
        }
        std.log.err("couldn't parse latest release name '{s}' (nor '{s}') as a version", .{ latest_release.name, release_name });
        std.process.exit(1);
    };

    if (!latest_version.has_precendence_over(current_version)) {
        std.log.info("the current version ({}) is up to date", .{current_version});
        return;
    }

    const extension = comptime builtin.target.exeFileExt();
    const target = @tagName(builtin.target.os.tag) ++ "-" ++ @tagName(builtin.target.cpu.arch);
    const executable_name = "ziglint-" ++ target ++ extension;

    // find the asset with the name "ziglint-<platform>-<arch>"
    for (latest_release.assets) |asset| {
        if (std.mem.eql(u8, asset.name, executable_name)) {
            std.log.info("downloading {s} version {s}", .{ asset.name, latest_version });

            const uri = try std.Uri.parse(asset.url);
            var headers = std.http.Headers.init(alloc);
            defer headers.deinit();
            try headers.append("Accept", asset.content_type);

            // the redirect URI becomes EVIL and CORRUPTED due to bugs
            // specifically, the %s from %-escapes in the provided URL are escaped again
            // lib/std/Uri.zig has been patched
            //
            // fn isQueryChar(c: u8) bool {
            //     return isPathChar(c) or c == '?' or c == '%'; // preescaped
            // }

            var ziglint_request = try client.request(.GET, uri, headers, .{});
            defer ziglint_request.deinit();

            try ziglint_request.start();
            try ziglint_request.wait();

            var tmpdir = std.testing.tmpDir(.{});
            defer tmpdir.cleanup();
            // open a file in the tmpdir to write into
            var tmpfile = try tmpdir.dir.createFile(executable_name, .{});
            defer tmpfile.close();

            // reuse the API buffer to write the file to disk
            var n = try ziglint_request.readAll(api_buffer);
            while (n > 0) : (n = try ziglint_request.readAll(api_buffer)) {
                try tmpfile.writeAll(api_buffer[0..n]);
            }

            return;
        }
    }
    std.log.warn("version {s} of ziglint has been released (you're running version {s}), " ++
        "but it's not currently available for your processor and operating system ({s}).", .{ latest_version, current_version, target });
}

fn log_failure_to_parse_version_and_exit(release_name: []const u8) noreturn {
    std.log.err("couldn't parse latest release name '{s}' as a version", .{release_name});
    std.process.exit(1);
}
