// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

// TODO: This is currently only used for GPT protective MBR. To add proper MBR support more work is needed here.

pub const MBR = extern struct {
    boot_code: [440]u8 align(1),
    mbr_disk_signature: u32 align(1),
    unknown: u16 align(1),
    record1: PartitonRecord align(1),
    record2: PartitonRecord align(1),
    record3: PartitonRecord align(1),
    record4: PartitonRecord align(1),
    signature: u16 align(1),

    pub const mbr_signature: u16 = 0xAA55;

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
    std.testing.refAllDeclsRecursive(@This());
}

const std = @import("std");
const core = @import("core");
