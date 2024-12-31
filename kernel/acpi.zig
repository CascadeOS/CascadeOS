// SPDX-License-Identifier: MIT AND BSD-2-Clause
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>
// SPDX-FileCopyrightText: 2019-2024 mintsuki and contributors (https://github.com/lowlevelmemes/acpi-shutdown-hack/blob/115c66d097e9d52015907a4ff27cd1ba34aee0d9/LICENSE)

/// Get the `n`th matching ACPI table if present.
///
/// Uses the `SIGNATURE_STRING: *const [4]u8` decl on the given `T` to find the table.
///
/// If the table is not valid, returns `null`.
pub fn getTable(comptime T: type, n: usize) ?*const T {
    const sdt_header = globals.sdt_header orelse return null;

    var iter = acpi.tableIterator(
        sdt_header,
        kernel.vmm.nonCachedDirectMapFromPhysical,
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
        const dsdt = kernel.vmm
            .nonCachedDirectMapFromPhysical(fadt.getDSDT())
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

    const PM1a_CNT = fadt.getPM1a_CNT();
    const PM1b_CNT_opt = fadt.getPM1b_CNT();

    if (fadt.SMI_CMD != 0 and fadt.ACPI_ENABLE != 0) {
        // we have SMM and we need to enable ACPI mode first
        try kernel.arch.io.writePort(u8, @intCast(fadt.SMI_CMD), fadt.ACPI_ENABLE);

        for (0..100) |_| {
            _ = try kernel.arch.io.readPort(u8, 0x80);
        }

        while (try readAddress(u16, PM1a_CNT) & SCI_EN == 0) {
            kernel.arch.spinLoopHint();
        }
    }

    try writeAddress(PM1a_CNT, SLP_TYPa | SLP_EN);

    if (PM1b_CNT_opt) |PM1b_CNT| {
        try writeAddress(PM1b_CNT, SLP_TYPb | SLP_EN);
    }

    for (0..100) |_| _ = try kernel.arch.io.readPort(u8, 0x80);
}

const ReadAddressError = error{
    UnsupportedAddressSpace,
    InvalidPort,
} || kernel.arch.io.PortError;

fn readAddress(comptime T: type, address: acpi.Address) ReadAddressError!T {
    switch (address.address_space) {
        .io => {
            const port = std.math.cast(
                kernel.arch.io.Port,
                address.address,
            ) orelse return ReadAddressError.InvalidPort;

            return kernel.arch.io.readPort(T, port);
        },
        else => return ReadAddressError.UnsupportedAddressSpace, // TODO: support more address spaces
    }
}

const WriteAddressError = error{
    UnsupportedAddressSpace,
    UnsupportedRegisterBitWidth,
    InvalidPort,
    ValueOutOfRange,
} || kernel.arch.io.PortError;

fn writeAddress(address: acpi.Address, value: u64) WriteAddressError!void {
    switch (address.address_space) {
        .io => {
            const port = std.math.cast(
                u16,
                address.address,
            ) orelse return WriteAddressError.InvalidPort;

            inline for (.{ 8, 16, 32 }) |bit_width| if (bit_width == address.register_bit_width) {
                const T = std.meta.Int(.unsigned, bit_width);

                try kernel.arch.io.writePort(
                    T,
                    port,
                    std.math.cast(
                        T,
                        value,
                    ) orelse return WriteAddressError.ValueOutOfRange,
                );

                return;
            };

            return WriteAddressError.UnsupportedPortSize; // TODO: support more register bit widths
        },
        else => return WriteAddressError.UnsupportedAddressSpace, // TODO: support more address spaces
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

const globals = struct {
    /// Initialized during `init.initializeACPITables`.
    ///
    /// Optional as panic calls `tryShutdown`, this might happen before `init.initializeACPITables` is called.
    var sdt_header: ?*const acpi.SharedHeader = null;
};

pub const init = struct {
    pub fn initializeACPITables() !void {
        const rsdp_address = kernel.boot.rsdp() orelse return error.RSDPNotProvided;

        const rsdp = switch (rsdp_address) {
            .physical => |addr| kernel.vmm.nonCachedDirectMapFromPhysical(addr).toPtr(*const acpi.RSDP),
            .virtual => |addr| addr.toPtr(*const acpi.RSDP),
        };
        if (!rsdp.isValid()) return error.InvalidRSDP;

        const sdt_header = kernel.vmm.nonCachedDirectMapFromPhysical(rsdp.sdtAddress()).toPtr(*const acpi.SharedHeader);

        if (!sdt_header.isValid()) return error.InvalidSDT;

        if (init_log.levelEnabled(.debug)) {
            var iter = acpi.tableIterator(
                sdt_header,
                kernel.vmm.nonCachedDirectMapFromPhysical,
            );

            init_log.debug("ACPI tables:", .{});

            while (iter.next()) |table| {
                if (table.isValid()) {
                    init_log.debug("  {s}", .{table.signatureAsString()});
                } else {
                    init_log.debug("  {s} - INVALID", .{table.signatureAsString()});
                }
            }
        }

        globals.sdt_header = sdt_header;
    }

    const init_log = kernel.debug.log.scoped(.init_acpi);
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const acpi = @import("acpi");
const log = kernel.debug.log.scoped(.acpi);
