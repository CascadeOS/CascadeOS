// SPDX-License-Identifier: MIT
// Various parts of the below implementation are from:
//  - https://github.com/dmgk/zig-uuid (see LICENSE-zig-uuid for upstream license)
//  - https://github.com/HelenOS/helenos (see LICENSE-helenos for upstream license)

const std = @import("std");
const core = @import("core");

/// Defines a UUID (Universally Unique IDentifier) as defined by RFC 4122.
pub const UUID = extern struct {
    bytes: [16]u8,

    pub const nil: UUID = UUID.parse("00000000-0000-0000-0000-000000000000") catch unreachable;

    pub const omni: UUID = UUID.parse("ffffffff-ffff-ffff-ffff-ffffffffffff") catch unreachable;

    /// Generates a random version 4 UUID.
    ///
    /// Uses `random` to generate a random 128-bit value.
    /// Then sets the version and variant fields to the appropriate values for a
    /// version 4 UUID as defined in RFC 4122.
    ///
    /// Returns: A random version 4 UUID.
    ///
    /// Parameters:
    /// - `random`: The random number generator to use.
    pub fn generateV4(random: std.rand.Random) UUID {
        var uuid: UUID = undefined;

        random.bytes(&uuid.bytes);

        // Version 4
        uuid.bytes[6] = (uuid.bytes[6] & 0x0f) | 0x40;

        // Variant 1
        uuid.bytes[8] = (uuid.bytes[8] & 0x3f) | 0x80;

        return uuid;
    }

    pub const ParseError = error{InvalidUUID};

    /// Parses a UUID from its string representation.
    ///
    /// Returns: The UUID parsed from the string.
    ///
    /// Parameters:
    /// - `buf`: The string representation of the UUID to parse.
    ///          Must be of the format: `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`
    ///
    /// Errors:
    /// - `ParseError.InvalidUUID` if the string is not a valid UUID representation.
    pub fn parse(buf: []const u8) ParseError!UUID {
        if (buf.len != 36) return ParseError.InvalidUUID;

        var temporary_layout: InMemoryLayout = undefined;

        inline for (parse_format_sections) |section| {
            if (section.proceeded_by_hyphen and buf[section.start_index - 1] != '-') {
                return ParseError.InvalidUUID;
            }

            const T = @TypeOf(@field(temporary_layout, section.field_name));

            // TODO: Don't use `std.fmt`

            @field(temporary_layout, section.field_name) =
                core.nativeTo(
                T,
                std.fmt.parseUnsigned(
                    T,
                    buf[section.start_index..][0..section.length],
                    16,
                ) catch return ParseError.InvalidUUID,
                section.endianness,
            );
        }

        return @bitCast(temporary_layout);
    }

    const InMemoryLayout = packed struct(u128) {
        time_low: u32,
        time_mid: u16,
        time_ver: u16,
        clock: u16,
        node: u48,
    };

    pub fn print(self: UUID, writer: anytype) !void {
        const temporary_layout: *const InMemoryLayout = @ptrCast(@alignCast(&self));

        var buf: [36]u8 = [_]u8{0} ** 36;

        inline for (parse_format_sections) |section| {
            if (section.proceeded_by_hyphen) buf[section.start_index - 1] = '-';

            const T = @TypeOf(@field(temporary_layout, section.field_name));

            // TODO: Don't use `std.fmt`
            _ = std.fmt.formatIntBuf(
                buf[section.start_index..][0..section.length],
                core.toNative(
                    T,
                    @field(temporary_layout, section.field_name),
                    section.endianness,
                ),
                16,
                .lower,
                .{
                    .width = section.length,
                    .fill = '0',
                },
            );
        }

        try writer.writeAll(&buf);
    }

    pub inline fn format(
        self: UUID,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        return print(self, writer);
    }

    const ParseFormatSection = struct {
        field_name: []const u8,
        start_index: usize,
        length: usize,
        endianness: std.builtin.Endian,
        proceeded_by_hyphen: bool,
    };

    // "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    // "time low - time mid - time ver - clock - node"
    const parse_format_sections: []const ParseFormatSection = &.{
        .{ .field_name = "time_low", .start_index = 0, .length = 8, .proceeded_by_hyphen = false, .endianness = .Little },
        .{ .field_name = "time_mid", .start_index = 9, .length = 4, .proceeded_by_hyphen = true, .endianness = .Little },
        .{ .field_name = "time_ver", .start_index = 14, .length = 4, .proceeded_by_hyphen = true, .endianness = .Little },
        .{ .field_name = "clock", .start_index = 19, .length = 4, .proceeded_by_hyphen = true, .endianness = .Big },
        .{ .field_name = "node", .start_index = 24, .length = 12, .proceeded_by_hyphen = true, .endianness = .Big },
    };

    comptime {
        core.testing.expectSize(@This(), 16);
    }
};

test "parse and format" {
    const uuids = [_][]const u8{
        "d0cd8041-0504-40cb-ac8e-d05960d205ec",
        "3df6f0e4-f9b1-4e34-ad70-33206069b995",
        "f982cf56-c4ab-4229-b23c-d17377d000be",
        "6b9f53be-cf46-40e8-8627-6b60dc33def8",
        "c282ec76-ac18-4d4a-8a29-3b94f5c74813",
        "00000000-0000-0000-0000-000000000000",
    };

    for (uuids) |uuid| {
        try std.testing.expectFmt(uuid, "{}", .{try UUID.parse(uuid)});
    }
}

test "invalid UUID" {
    const uuids = [_][]const u8{
        "3df6f0e4-f9b1-4e34-ad70-33206069b99", // too short
        "3df6f0e4-f9b1-4e34-ad70-33206069b9912", // too long
        "3df6f0e4-f9b1-4e34-ad70_33206069b9912", // missing or invalid group separator
        "zdf6f0e4-f9b1-4e34-ad70-33206069b995", // invalid character
    };

    for (uuids) |uuid| {
        try std.testing.expectError(error.InvalidUUID, UUID.parse(uuid));
    }
}

comptime {
    refAllDeclsRecursive(@This(), true);
}

fn refAllDeclsRecursive(comptime T: type, comptime first: bool) void {
    comptime {
        if (!@import("builtin").is_test) return;

        inline for (std.meta.declarations(T)) |decl| {
            // don't analyze if the decl is not pub unless we are the first level of this call chain
            if (!first and !decl.is_pub) continue;

            if (std.mem.eql(u8, decl.name, "std")) continue;

            if (!@hasDecl(T, decl.name)) continue;

            defer _ = @field(T, decl.name);

            if (@TypeOf(@field(T, decl.name)) != type) continue;

            switch (@typeInfo(@field(T, decl.name))) {
                .Struct, .Enum, .Union, .Opaque => refAllDeclsRecursive(@field(T, decl.name), false),
                else => {},
            }
        }
        return;
    }
}
