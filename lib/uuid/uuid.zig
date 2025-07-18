// SPDX-License-Identifier: MIT AND BSD-2-Clause AND 0BSD
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>
// SPDX-FileCopyrightText: 2015 Jiri Svoboda (https://github.com/HelenOS/helenos)
// SPDX-FileCopyrightText: 2021 Dmitri Goutnik (https://github.com/dmgk/zig-uuid)

/// Defines a UUID (Universally Unique IDentifier) as defined by RFC 4122.
pub const UUID = extern struct {
    bytes: [16]u8,

    pub const nil: UUID = UUID.parse("00000000-0000-0000-0000-000000000000") catch unreachable;

    pub const omni: UUID = UUID.parse("ffffffff-ffff-ffff-ffff-ffffffffffff") catch unreachable;

    /// Generates a random version 4 UUID.
    pub fn generateV4(random: std.Random) UUID {
        var uuid: UUID = undefined;

        random.bytes(&uuid.bytes);

        // Version 4
        uuid.bytes[6] = (uuid.bytes[6] & 0x0f) | 0x40;

        // Variant 1
        uuid.bytes[8] = (uuid.bytes[8] & 0x3f) | 0x80;

        return uuid;
    }

    pub fn eql(a: UUID, b: UUID) bool {
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }

    pub const ParseError = error{InvalidUUID};

    /// Parses a UUID from its string representation.
    ///
    /// Expected format is `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`
    pub fn parse(buf: []const u8) ParseError!UUID {
        if (buf.len != uuid_buffer_length) return ParseError.InvalidUUID;

        var result: UUID = undefined;

        comptime var i: usize = 0;

        inline for (uuid_sections) |section| {
            if (section.proceeded_by_hyphen) {
                if (buf[i] != '-') return ParseError.InvalidUUID;
                i += 1;
            }

            const characters_needed = comptime section.characterWidthOfField();
            const ptr: *align(1) section.field_type = @ptrCast(&result.bytes[section.start_index]);

            ptr.* = std.fmt.parseUnsigned(
                section.field_type,
                buf[i..][0..characters_needed],
                16,
            ) catch return ParseError.InvalidUUID;

            i += characters_needed;
        }

        return result;
    }

    pub const uuid_buffer_length: usize = 36;

    pub fn format(uuid: UUID, writer: *std.Io.Writer) !void {
        inline for (uuid_sections) |section| {
            if (section.proceeded_by_hyphen) try writer.writeByte('-');

            const ptr: *align(1) const section.field_type = @ptrCast(&uuid.bytes[section.start_index]);

            try writer.printInt(
                ptr.*,
                16,
                .lower,
                .{ .width = section.characterWidthOfField(), .fill = '0' },
            );
        }
    }

    const UUIDSection = struct {
        field_type: type,
        start_index: usize,
        proceeded_by_hyphen: bool,

        inline fn characterWidthOfField(comptime uuid_section: UUIDSection) usize {
            return comptime switch (uuid_section.field_type) {
                u32 => 8,
                u16 => 4,
                u8 => 2,
                else => @compileError("Unsupported type '" ++ @typeName(uuid_section.field_type) ++ "'"),
            };
        }
    };

    const uuid_sections: []const UUIDSection = &.{
        .{ .field_type = u32, .start_index = 0, .proceeded_by_hyphen = false }, // time_low
        .{ .field_type = u16, .start_index = 4, .proceeded_by_hyphen = true }, // time_mid
        .{ .field_type = u16, .start_index = 6, .proceeded_by_hyphen = true }, // time_hi_and_version
        .{ .field_type = u8, .start_index = 8, .proceeded_by_hyphen = true }, // clock_seq_hi_and_reserved
        .{ .field_type = u8, .start_index = 9, .proceeded_by_hyphen = false }, // cloc_seq_low
        .{ .field_type = u8, .start_index = 10, .proceeded_by_hyphen = true }, // node[0]
        .{ .field_type = u8, .start_index = 11, .proceeded_by_hyphen = false }, // node[1]
        .{ .field_type = u8, .start_index = 12, .proceeded_by_hyphen = false }, // node[2]
        .{ .field_type = u8, .start_index = 13, .proceeded_by_hyphen = false }, // node[3]
        .{ .field_type = u8, .start_index = 14, .proceeded_by_hyphen = false }, // node[4]
        .{ .field_type = u8, .start_index = 15, .proceeded_by_hyphen = false }, // node[5]
    };

    comptime {
        core.testing.expectSize(UUID, 16);
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
        try std.testing.expectFmt(uuid, "{f}", .{try UUID.parse(uuid)});
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
    std.testing.refAllDeclsRecursive(@This());
}

const std = @import("std");
const core = @import("core");
