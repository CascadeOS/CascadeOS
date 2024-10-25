// SPDX-License-Identifier: MIT AND BSD-2-Clause
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>
// SPDX-FileCopyrightText: 2019-2024 mintsuki and contributors (https://github.com/lowlevelmemes/acpi-shutdown-hack/blob/115c66d097e9d52015907a4ff27cd1ba34aee0d9/LICENSE)

/// Get the `n`th matching ACPI table if present.
///
/// Uses the `SIGNATURE_STRING: *const [4]u8` decl on the given `T` to find the table.
///
/// If the table is not valid, returns `null`.
pub fn getTable(comptime T: type, n: usize) ?*const T {
    var iter = acpi.tableIterator(
        globals.sdt_header,
        kernel.memory_layout.directMapFromPhysical,
    );

    var i: usize = 0;

    while (iter.next()) |header| {
        if (!header.signatureIs(T.SIGNATURE_STRING)) {
            continue;
        }

        if (i != n) {
            i += 1;
            continue;
        }

        if (!header.isValid()) {
            log.warn("invalid table: {s}", .{header.signatureAsString()});
            return null;
        }

        return @ptrCast(header);
    }

    return null;
}

pub fn tryShutdown() !void {
    // this is ported from https://github.com/lowlevelmemes/acpi-shutdown-hack/blob/trunk/acpi_shutdown_hack.c

    const fadt = getTable(acpi.FADT, 0) orelse return error.FADTNotPresent;

    var s5_addr: [*]const u8 = blk: {
        const dsdt = kernel.memory_layout
            .directMapFromPhysical(fadt.getDSDT())
            .toPtr(*acpi.DSDT);
        if (!dsdt.header.signatureIs(acpi.DSDT.SIGNATURE_STRING)) return error.DSDTNotPresent;

        const definition_block = dsdt.definitionBlock();

        const s5_offset = std.mem.indexOf(
            u8,
            definition_block,
            "_S5_",
        ) orelse return error.S5NotPresent;

        break :blk definition_block[s5_offset..].ptr;
    };

    s5_addr += 4; // skip the last part of NameSeg

    if (s5_addr[0] != 0x12) return error.S5NotPackageOp; // TODO: this code only supports PackageOp
    s5_addr += 1;

    s5_addr += ((s5_addr[0] & 0xc0) >> 6) + 1; // skip PkgLength

    if (s5_addr[0] < 2) return error.S5NotEnoughElements;
    s5_addr += 1;

    const SLP_TYPa: u16 = blk: {
        var value: u64 = 0;
        s5_addr += parseInteger(s5_addr, &value) orelse return error.FailedToParseSLP_TYPa;
        break :blk @intCast(value << 10);
    };

    const SLP_TYPb: u16 = blk: {
        var value: u64 = 0;
        s5_addr += parseInteger(s5_addr, &value) orelse return error.FailedToParseSLP_TYPb;
        break :blk @intCast(value << 10);
    };

    const SCI_EN: u8 = 1;
    const SLP_EN = @as(u16, 1) << 13;

    const PM1a_CNT_BLK: u16 = if (fadt.X_PM1a_CNT_BLK.address != 0) blk: {
        if (fadt.X_PM1a_CNT_BLK.address_space != .io) return error.X_PM1a_CNT_BLK_NotIO;
        break :blk @intCast(fadt.X_PM1a_CNT_BLK.address);
    } else @intCast(fadt.PM1a_CNT_BLK);

    const PM1b_CNT_BLK_opt: ?u16 = if (fadt.X_PM1b_CNT_BLK.address != 0) blk: {
        if (fadt.X_PM1b_CNT_BLK.address_space != .io) return error.X_PM1b_CNT_BLK_NotIO;
        break :blk @intCast(fadt.X_PM1b_CNT_BLK.address);
    } else if (fadt.PM1b_CNT_BLK != 0)
        @intCast(fadt.PM1b_CNT_BLK)
    else
        null;

    if (fadt.SMI_CMD != 0 and fadt.ACPI_ENABLE != 0) {
        // we have SMM and we need to enable ACPI mode first
        arch.jank.outb(@intCast(fadt.SMI_CMD), fadt.ACPI_ENABLE);

        for (0..100) |_| _ = arch.jank.inb(0x80);

        while (arch.jank.inw(PM1a_CNT_BLK) & SCI_EN == 0) arch.spinLoopHint();
    }

    arch.jank.outw(PM1a_CNT_BLK, SLP_TYPa | SLP_EN);

    if (PM1b_CNT_BLK_opt) |PM1b_CNT_BLK| {
        arch.jank.outw(PM1b_CNT_BLK, SLP_TYPb | SLP_EN);
    }

    for (0..100) |_| _ = arch.jank.inb(0x80);
}

const WriteAddressError = error{
    UnsupportedAddressSpace,
    UnsupportedRegisterBitWidth,
    InvalidIoPort,
    ValueOutOfRange,
};

fn writeAddress(address: acpi.Address, value: u64) WriteAddressError!void {
    switch (address.address_space) {
        .io => {
            const port = cast(
                u16,
                address.address,
            ) orelse return WriteAddressError.InvalidIoPort;

            switch (address.register_bit_width) {
                8 => arch.jank.outb(
                    port,
                    cast(
                        u8,
                        value,
                    ) orelse return WriteAddressError.ValueOutOfRange,
                ),
                16 => arch.jank.outw(
                    port,
                    cast(
                        u16,
                        value,
                    ) orelse return WriteAddressError.ValueOutOfRange,
                ),
                else => return WriteAddressError.UnsupportedRegisterBitWidth, // TODO: support more register bit widths
            }
        },
        else => return WriteAddressError.UnsupportedAddressSpace, // TODO: support more address spaces
    }
}

const ReadAddressError = error{
    UnsupportedAddressSpace,
    UnsupportedRegisterBitWidth,
    InvalidIoPort,
};

fn readAddress(comptime T: type, address: acpi.Address) ReadAddressError!T {
    switch (address.address_space) {
        .io => {
            const port = cast(
                u16,
                address.address,
            ) orelse return ReadAddressError.InvalidIoPort;

            return switch (address.register_bit_width) {
                8 => arch.jank.inb(port),
                16 => arch.jank.inw(port),
                else => ReadAddressError.UnsupportedRegisterBitWidth, // TODO: support more register bit widths
            };
        },
        else => return ReadAddressError.UnsupportedAddressSpace, // TODO: support more address spaces
    }
}

fn parseInteger(s5_addr: [*]const u8, value: *u64) ?u8 {
    var addr = s5_addr;

    const op = addr[0];
    addr += 1;

    switch (op) {
        0x0 => {
            // ZeroOp
            value.* = 0;
            return 1;
        },
        0x1 => {
            // OneOp
            value.* = 1;
            return 1;
        },
        0xFF => {
            // OnesOp
            value.* = ~@as(u64, 0);
            return 1;
        },
        0xA => {
            // ByteConst
            value.* = addr[0];
            return 2; // 1 Type Byte, 1 Data Byte
        },
        0xB => {
            // WordConst
            value.* =
                addr[0] |
                (@as(u16, addr[1]) << 8);
            return 3; // 1 Type Byte, 2 Data Bytes
        },
        0xC => {
            // DWordConst
            value.* =
                addr[0] |
                (@as(u32, addr[1]) << 8) |
                (@as(u32, addr[2]) << 16) |
                (@as(u32, addr[3]) << 24);
            return 5; // 1 Type Byte, 4 Data Bytes
        },
        0xE => {
            // DWordConst
            value.* =
                addr[0] |
                (@as(u64, addr[1]) << 8) |
                (@as(u64, addr[2]) << 16) |
                (@as(u64, addr[3]) << 24) |
                (@as(u64, addr[4]) << 32) |
                (@as(u64, addr[5]) << 40) |
                (@as(u64, addr[6]) << 48) |
                (@as(u64, addr[7]) << 56);
            return 9; // 1 Type Byte, 8 Data Bytes
        },
        else => return null, // not an integer
    }
}

pub const globals = struct {
    /// Initialized during `init.initializeACPITables`.
    pub var sdt_header: *const acpi.SharedHeader = undefined;
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const arch = @import("arch");
const acpi = @import("acpi");
const log = kernel.log.scoped(.acpi);
const cast = std.math.cast;
