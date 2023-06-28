//! Implementation of the Semantic Versioning Specification version 2.0.0 as described at https://semver.org/

const std = @import("std");

pub const VersionError = error{
    TooManyDots,
    NoMajor,
    NoMinor,
    NoPatch,
    InvalidCharacter,
    Overflow,
    OutOfMemory,
};

pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,

    // `null` if the version is not a prerelease, and otherwise a string containing the prerelease identifiers
    // note that it is NOT split up on the dots yet - that happens in the comparison step (if needed)
    prerelease: ?[]const u8,
    // build metadata, if any, as defined in point 10 of the SemVer spec
    // still null if there are *pre-release* identifiers
    build_metadata: ?[]const u8,

    // Parses a semantic-versioning-compliant version string into a Version struct.
    //
    // This method does not validate the version; it should not reject valid version strings,
    // but may accept invalid ones.
    //
    // Major, minor, and patch numbers greater than or equal to 2 to the 32nd power are not supported by this method.
    pub fn parse(raw_version: []const u8) VersionError!Version {
        var major: ?u32 = null;
        var minor: ?u32 = null;
        var patch: ?u32 = null;
        var number_start_idx: usize = 0;
        var prerelease: ?[]const u8 = null;
        var build_metadata: ?[]const u8 = null;

        for (raw_version, 0..) |char, idx| {
            if (char == '.') {
                // heehee we have a dot!
                // parse between this dot and the last one (or start of string) to get a number
                const parsed_number = try std.fmt.parseInt(u32, raw_version[number_start_idx..idx], 10);
                if (major == null) {
                    major = parsed_number;
                } else if (minor == null) {
                    minor = parsed_number;
                    // once we have the minor, we need to parse the patch, but first —
                    // is there a prerelease or build metadata? let's look ahead!
                    var patch_end = raw_version.len;
                    var prerelease_end: ?usize = null;

                    var inner_loop_idx = idx;
                    while (inner_loop_idx < raw_version.len) : (inner_loop_idx = inner_loop_idx + 1) {
                        if (raw_version[inner_loop_idx] == '-' and prerelease_end == null) {
                            // prerelease!
                            patch_end = inner_loop_idx;
                            prerelease_end = raw_version.len;
                        }

                        if (raw_version[inner_loop_idx] == '+') {
                            // build metadata!
                            if (prerelease_end == null) {
                                patch_end = inner_loop_idx;
                            } else {
                                prerelease_end = inner_loop_idx;
                            }

                            build_metadata = raw_version[inner_loop_idx + 1 ..];
                            break;
                        }
                    }

                    if (prerelease_end) |end| {
                        prerelease = raw_version[patch_end + 1 .. end];
                    }

                    patch = try std.fmt.parseInt(u32, raw_version[idx + 1 .. patch_end], 10);
                    break;
                } else {
                    return error.TooManyDots;
                }
                number_start_idx = idx + 1;
            }
        }
        if (major == null) return error.NoMajor;
        if (minor == null) return error.NoMinor;
        if (patch == null) return error.NoPatch;

        return Version{
            .major = major.?,
            .minor = minor.?,
            .patch = patch.?,
            .prerelease = prerelease,
            .build_metadata = build_metadata,
        };
    }

    // Returns `true` if this Version has precedence over the other Version,
    // as described in the Semantic Versioning Specification 2.0.0.
    //
    // Digits-only prerelease identifiers greater than or equal to 2 to the 32nd power are not supported by this method.
    pub fn has_precendence_over(self: Version, other: Version) bool {
        if (self.major != other.major) return self.major > other.major;
        if (self.minor != other.minor) return self.minor > other.minor;
        if (self.patch != other.patch) return self.patch > other.patch;

        // deal with PRERELEASE IDENTIFIERS
        // if one version has prerelease identifiers and the other doesn't, the one without has precedence
        if (self.prerelease == null and other.prerelease != null) return true;
        if (self.prerelease != null and other.prerelease == null) return false;
        // if the versions are equivalent, neither has precedence
        if (self.prerelease == null and other.prerelease == null) return false;

        var self_prerelease_iter = std.mem.split(u8, self.prerelease.?, ".");
        var other_prerelease_iter = std.mem.split(u8, other.prerelease.?, ".");

        var self_prerelease_identifier = self_prerelease_iter.next();
        var other_prerelease_identifier = other_prerelease_iter.next();
        while (self_prerelease_identifier != null or other_prerelease_identifier != null) {
            // check if one side has run out of identifiers - the longer one has precedence
            if (self_prerelease_identifier == null) return false;
            if (other_prerelease_identifier == null) return true;

            // compare digits if both sides have them
            var self_numeric: ?u32 = std.fmt.parseInt(u32, self_prerelease_identifier.?, 10) catch null;
            var other_numeric: ?u32 = std.fmt.parseInt(u32, other_prerelease_identifier.?, 10) catch null;
            if (self_numeric != null and other_numeric != null) {
                return self_numeric.? > other_numeric.?;
            }
            // 3. Numeric identifiers always have lower precedence than non-numeric identifiers.
            if (self_numeric != null and other_numeric == null) return false;
            if (self_numeric == null and other_numeric != null) return true;

            // 2. Identifiers with letters or hyphens are compared lexically in ASCII sort order.
            var idx: usize = 0;
            const our_prerel_len = self_prerelease_identifier.?.len;
            const their_prerel_len = other_prerelease_identifier.?.len;
            while (idx < our_prerel_len and idx < their_prerel_len) : (idx = idx + 1) {
                if (self_prerelease_identifier.?[idx] > other_prerelease_identifier.?[idx]) return true;
                if (self_prerelease_identifier.?[idx] < other_prerelease_identifier.?[idx]) return false;
            }
            if (self_prerelease_identifier.?.len != other_prerelease_identifier.?.len) {
                return self_prerelease_identifier.?.len < other_prerelease_identifier.?.len;
            }

            self_prerelease_identifier = self_prerelease_iter.next();
            other_prerelease_identifier = other_prerelease_iter.next();
        }
        return false;
    }

    pub fn format(value: Version, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{}.{}.{}", .{ value.major, value.minor, value.patch });
        if (value.prerelease) |prerelease| {
            try writer.print("-{s}", .{prerelease});
        }
        if (value.build_metadata) |metadata| {
            try writer.print("+{s}", .{metadata});
        }
    }
};

test "Semantic Versionin Specification — point 2" {
    const nine = try Version.parse("1.9.0");
    try std.testing.expectEqualDeep(Version{
        .major = 1,
        .minor = 9,
        .patch = 0,
        .prerelease = null,
        .build_metadata = null,
    }, nine);

    const ten = try Version.parse("1.10.0");
    try std.testing.expectEqualDeep(Version{
        .major = 1,
        .minor = 10,
        .patch = 0,
        .prerelease = null,
        .build_metadata = null,
    }, ten);

    const eleven = try Version.parse("1.11.0");
    try std.testing.expectEqualDeep(Version{
        .major = 1,
        .minor = 11,
        .patch = 0,
        .prerelease = null,
        .build_metadata = null,
    }, eleven);

    try test_precedence_pair(eleven, nine);
    try test_precedence_pair(eleven, ten);
}

test "Semantic Versioning Specification — Point 9" {
    try std.testing.expectEqualDeep(Version{
        .major = 1,
        .minor = 0,
        .patch = 0,
        .prerelease = "alpha",
        .build_metadata = null,
    }, try Version.parse("1.0.0-alpha"));

    try std.testing.expectEqualDeep(Version{
        .major = 1,
        .minor = 0,
        .patch = 0,
        .prerelease = "alpha.1",
        .build_metadata = null,
    }, try Version.parse("1.0.0-alpha.1"));

    try std.testing.expectEqualDeep(Version{
        .major = 1,
        .minor = 0,
        .patch = 0,
        .prerelease = "0.3.7",
        .build_metadata = null,
    }, try Version.parse("1.0.0-0.3.7"));

    try std.testing.expectEqualDeep(Version{
        .major = 1,
        .minor = 0,
        .patch = 0,
        .prerelease = "x.7.z.92",
        .build_metadata = null,
    }, try Version.parse("1.0.0-x.7.z.92"));

    try std.testing.expectEqualDeep(Version{
        .major = 1,
        .minor = 0,
        .patch = 0,
        .prerelease = "x-y-z.--",
        .build_metadata = null,
    }, try Version.parse("1.0.0-x-y-z.--"));
}

test "Semantic Versioning Specification — Point 10" {
    try std.testing.expectEqualDeep(Version{
        .major = 1,
        .minor = 0,
        .patch = 0,
        .prerelease = "alpha",
        .build_metadata = "001",
    }, try Version.parse("1.0.0-alpha+001"));

    try std.testing.expectEqualDeep(Version{
        .major = 1,
        .minor = 0,
        .patch = 0,
        .prerelease = null,
        .build_metadata = "20130313144700",
    }, try Version.parse("1.0.0+20130313144700"));

    try std.testing.expectEqualDeep(Version{
        .major = 1,
        .minor = 0,
        .patch = 0,
        .prerelease = "beta",
        .build_metadata = "exp.sha.5114f85",
    }, try Version.parse("1.0.0-beta+exp.sha.5114f85"));

    try std.testing.expectEqualDeep(Version{
        .major = 1,
        .minor = 0,
        .patch = 0,
        .prerelease = null,
        .build_metadata = "21AF26D3----117B344092BD",
    }, try Version.parse("1.0.0+21AF26D3----117B344092BD"));
}

fn test_precedence_pair(has_precedence: Version, no_precedence: Version) !void {
    try std.testing.expect(has_precedence.has_precendence_over(no_precedence));
    try std.testing.expect(!no_precedence.has_precendence_over(has_precedence));
}

test "Semantic Versioning Specification — Point 11.2" {
    // Example: 1.0.0 < 2.0.0 < 2.1.0 < 2.1.1.
    try test_precedence_pair(try Version.parse("2.0.0"), try Version.parse("1.0.0"));

    try test_precedence_pair(try Version.parse("2.1.0"), try Version.parse("2.0.0"));
    try test_precedence_pair(try Version.parse("2.1.0"), try Version.parse("1.0.0"));

    try test_precedence_pair(try Version.parse("2.1.1"), try Version.parse("2.1.0"));
    try test_precedence_pair(try Version.parse("2.1.1"), try Version.parse("2.0.0"));
    try test_precedence_pair(try Version.parse("2.1.1"), try Version.parse("1.0.0"));
}

test "Semantic Versioning Specification — Point 11.3" {
    try test_precedence_pair(try Version.parse("1.0.0"), try Version.parse("1.0.0-alpha"));
}

test "Semantic Versioning Specification — Point 11.4" {
    // Example: 1.0.0-alpha < 1.0.0-alpha.1 < 1.0.0-alpha.beta < 1.0.0-beta < 1.0.0-beta.2
    // 1.0.0-beta.2 < 1.0.0-beta.11 < 1.0.0-rc.1 < 1.0.0
    try test_precedence_pair(try Version.parse("1.0.0-alpha.1"), try Version.parse("1.0.0-alpha"));

    try test_precedence_pair(try Version.parse("1.0.0-alpha.beta"), try Version.parse("1.0.0-alpha.1"));
    try test_precedence_pair(try Version.parse("1.0.0-alpha.beta"), try Version.parse("1.0.0-alpha"));

    try test_precedence_pair(try Version.parse("1.0.0-beta"), try Version.parse("1.0.0-alpha.beta"));
    try test_precedence_pair(try Version.parse("1.0.0-beta"), try Version.parse("1.0.0-alpha.1"));
    try test_precedence_pair(try Version.parse("1.0.0-beta"), try Version.parse("1.0.0-alpha"));

    try test_precedence_pair(try Version.parse("1.0.0-beta.2"), try Version.parse("1.0.0-beta"));
    try test_precedence_pair(try Version.parse("1.0.0-beta.2"), try Version.parse("1.0.0-alpha.beta"));
    try test_precedence_pair(try Version.parse("1.0.0-beta.2"), try Version.parse("1.0.0-alpha.1"));
    try test_precedence_pair(try Version.parse("1.0.0-beta.2"), try Version.parse("1.0.0-alpha"));

    try test_precedence_pair(try Version.parse("1.0.0-beta.11"), try Version.parse("1.0.0-beta.2"));
    try test_precedence_pair(try Version.parse("1.0.0-beta.11"), try Version.parse("1.0.0-beta"));
    try test_precedence_pair(try Version.parse("1.0.0-beta.11"), try Version.parse("1.0.0-alpha.beta"));
    try test_precedence_pair(try Version.parse("1.0.0-beta.11"), try Version.parse("1.0.0-alpha.1"));
    try test_precedence_pair(try Version.parse("1.0.0-beta.11"), try Version.parse("1.0.0-alpha"));

    try test_precedence_pair(try Version.parse("1.0.0-rc.1"), try Version.parse("1.0.0-beta.11"));
    try test_precedence_pair(try Version.parse("1.0.0-rc.1"), try Version.parse("1.0.0-beta.2"));
    try test_precedence_pair(try Version.parse("1.0.0-rc.1"), try Version.parse("1.0.0-beta"));
    try test_precedence_pair(try Version.parse("1.0.0-rc.1"), try Version.parse("1.0.0-alpha.beta"));
    try test_precedence_pair(try Version.parse("1.0.0-rc.1"), try Version.parse("1.0.0-alpha.1"));
    try test_precedence_pair(try Version.parse("1.0.0-rc.1"), try Version.parse("1.0.0-alpha"));

    try test_precedence_pair(try Version.parse("1.0.0"), try Version.parse("1.0.0-rc.1"));
    try test_precedence_pair(try Version.parse("1.0.0"), try Version.parse("1.0.0-beta.11"));
    try test_precedence_pair(try Version.parse("1.0.0"), try Version.parse("1.0.0-beta.2"));
    try test_precedence_pair(try Version.parse("1.0.0"), try Version.parse("1.0.0-beta"));
    try test_precedence_pair(try Version.parse("1.0.0"), try Version.parse("1.0.0-alpha.beta"));
    try test_precedence_pair(try Version.parse("1.0.0"), try Version.parse("1.0.0-alpha.1"));
}
