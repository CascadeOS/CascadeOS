// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");

// TODO: This is currently only used for GPT protective MBR. To add proper MBR support more work is needed here.

pub const MBR = extern struct {
    boot_code: [440]u8 align(1) = [_]u8{0} ** 440,
    mbr_disk_signature: u32 align(1) = 0,
    unknown: u16 align(1) = 0,
    record1: PartitonRecord align(1) = .{},
    record2: PartitonRecord align(1) = .{},
    record3: PartitonRecord align(1) = .{},
    record4: PartitonRecord align(1) = .{},
    signature: u16 align(1) = signature,

    pub const signature: u16 = 0xAA55;

    pub const PartitonRecord = packed struct(u128) {
        boot_indicator: u8 = 0,
        starting_chs: u24 = 0,
        os_type: u8 = 0,
        ending_chs: u24 = 0,
        starting_lba: u32 = 0,
        size_in_lba: u32 = 0,
    };

    comptime {
        core.testing.expectSize(@This(), 512);
    }
};

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
