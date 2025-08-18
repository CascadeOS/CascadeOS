// SPDX-License-Identifier: MIT AND BSD-2-Clause
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>
// SPDX-FileCopyrightText: 2019-2023 mintsuki and contributors (https://github.com/lowlevelmemes/acpi-shutdown-hack/blob/115c66d097e9d52015907a4ff27cd1ba34aee0d9/LICENSE)

/// Get the `n`th matching ACPI table if present.
///
/// Uses the `SIGNATURE_STRING: *const [4]u8` decl on the given `T` to find the table.
pub fn getTable(comptime T: type, n: usize) ?AcpiTable(T) {
    if (!globals.early_initialization_complete) return null;

    var table = uacpi.Table.findBySignature(T.SIGNATURE_STRING) catch null orelse return null;

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const found_next = table.nextWithSameSignature() catch return null;
        if (!found_next) return null;
    }

    return .{
        .table = @ptrCast(@alignCast(table.table.ptr)),
        .handle = table,
    };
}

pub fn tryShutdown() !void {
    if (globals.acpi_initialized) {
        try uacpi.prepareForSleep(.S5);

        const interrupts_enabled = arch.interrupts.areEnabled();
        arch.interrupts.disable();
        defer if (interrupts_enabled) arch.interrupts.enable();

        try uacpi.sleep(.S5);
    }

    try hack.tryHackyShutdown();
}

pub const Address = @import("Address.zig").Address;
pub const tables = @import("tables/tables.zig");

pub fn AcpiTable(comptime T: type) type {
    return struct {
        table: *const T,

        handle: uacpi.Table,

        const AcpiTableT = @This();

        pub fn deinit(acpi_table: AcpiTableT) void {
            acpi_table.handle.unref() catch unreachable;
        }

        pub inline fn format(acpi_table: AcpiTableT, writer: *std.Io.Writer) !void {
            try writer.print(
                "AcpiTable{{ signature: {s}, revision: {d} }}",
                .{ acpi_table.table.header.signatureAsString(), acpi_table.table.header.revision },
            );
        }
    };
}

pub const globals = struct {
    /// Pointer to the RSDP table.
    ///
    /// Set by `earlyInitialize`, only valid if `early_initialization_complete` is true.
    pub var rsdp: *const tables.RSDP = undefined;

    /// If this is true, the ACPI tables have been initialized and the RSDP pointer is valid.
    var early_initialization_complete: bool = false;

    var acpi_initialized: bool = false;
};

pub const init = struct {
    pub fn earlyInitialize(rsdp_address: core.Address) !void {
        const static = struct {
            var buffer: [arch.paging.standard_page_size.value]u8 = undefined;
        };

        globals.rsdp = switch (rsdp_address) {
            // using `directMapFromPhysical` as the non-cached direct map is not yet initialized
            .physical => |addr| kernel.mem.directMapFromPhysical(addr).toPtr(*const tables.RSDP),
            .virtual => |addr| addr.toPtr(*const tables.RSDP),
        };
        if (!globals.rsdp.isValid()) return error.InvalidRSDP;

        try uacpi.setupEarlyTableAccess(&static.buffer);
        globals.early_initialization_complete = true;
    }

    pub fn initialize(context: *kernel.Task.Context) !void {
        init_log.debug(context, "entering ACPI mode", .{});
        try uacpi.initialize(.{});

        try uacpi.FixedEvent.power_button.installHandler(
            void,
            earlyPowerButtonHandler,
            null,
        );

        init_log.debug(context, "loading namespace", .{});
        try uacpi.namespaceLoad();

        if (arch.current_arch == .x64) {
            try uacpi.setInterruptModel(.ioapic);
        }

        init_log.debug(context, "initializing namespace", .{});
        try uacpi.namespaceInitialize();

        globals.acpi_initialized = true;
    }

    pub fn finializeInitialization(context: *kernel.Task.Context) !void {
        init_log.debug(context, "finializing GPEs", .{});
        try uacpi.finializeGpeInitialization();
    }

    fn earlyPowerButtonHandler(_: ?*void) uacpi.InterruptReturn {
        init_log.warn(.current(), "power button pressed", .{});
        tryShutdown() catch |err| {
            std.debug.panic("failed to shutdown: {t}", .{err});
        };
        @panic("shutdown failed");
    }

    pub fn logAcpiTables(context: *kernel.Task.Context) !void {
        // this function uses `directMapFromPhysical` as the non-cached direct map is not yet initialized

        if (!init_log.levelEnabled(.debug)) return;

        const sdt_header = kernel.mem.directMapFromPhysical(globals.rsdp.sdtAddress())
            .toPtr(*const tables.SharedHeader);

        if (!sdt_header.isValid()) return error.InvalidSDT;

        var iter = tableIterator(sdt_header);

        init_log.debug(context, "ACPI tables:", .{});

        while (iter.next()) |table| {
            if (table.isValid()) {
                init_log.debug(context, "  {s}", .{table.signatureAsString()});
            } else {
                init_log.debug(context, "  {s} - INVALID", .{table.signatureAsString()});
            }
        }
    }

    fn tableIterator(
        sdt_header: *const tables.SharedHeader,
    ) TableIterator {
        const sdt_ptr: [*]const u8 = @ptrCast(sdt_header);

        const is_xsdt = sdt_header.signatureIs("XSDT");
        std.debug.assert(is_xsdt or sdt_header.signatureIs("RSDT")); // Invalid SDT signature.

        return .{
            .ptr = sdt_ptr + @sizeOf(tables.SharedHeader),
            .end_ptr = sdt_ptr + sdt_header.length,
            .is_xsdt = is_xsdt,
        };
    }

    const TableIterator = struct {
        ptr: [*]const u8,
        end_ptr: [*]const u8,

        is_xsdt: bool,

        pub fn next(table_iterator: *TableIterator) ?*const tables.SharedHeader {
            // this function uses `directMapFromPhysical` as the non-cached direct map is not yet initialized

            const opt_phys_addr = if (table_iterator.is_xsdt)
                table_iterator.nextTablePhysicalAddressImpl(u64)
            else
                table_iterator.nextTablePhysicalAddressImpl(u32);

            return kernel.mem
                .directMapFromPhysical(opt_phys_addr orelse return null)
                .toPtr(*const tables.SharedHeader);
        }

        fn nextTablePhysicalAddressImpl(table_iterator: *TableIterator, comptime T: type) ?core.PhysicalAddress {
            if (@intFromPtr(table_iterator.ptr) + @sizeOf(T) >= @intFromPtr(table_iterator.end_ptr)) return null;

            const physical_address = std.mem.readInt(T, @ptrCast(table_iterator.ptr), .little);

            table_iterator.ptr += @sizeOf(T);

            return core.PhysicalAddress.fromInt(physical_address);
        }
    };

    const init_log = kernel.debug.log.scoped(.init_acpi);
};

const hack = struct {
    fn tryHackyShutdown() !void {
        if (arch.current_arch != .x64) return; // this code uses io ports

        // this is ported from https://github.com/lowlevelmemes/acpi-shutdown-hack/blob/trunk/acpi_shutdown_hack.c

        const acpi_table = getTable(tables.FADT, 0) orelse return error.FADTNotPresent;
        defer acpi_table.deinit();

        const fadt: *const tables.FADT = acpi_table.table;

        var s5_addr: [*]const u8 = blk: {
            const dsdt = kernel.mem
                .nonCachedDirectMapFromPhysical(fadt.getDSDT())
                .toPtr(*tables.DSDT);
            if (!dsdt.header.signatureIs(tables.DSDT.SIGNATURE_STRING)) return error.DSDTNotPresent;

            const definition_block = dsdt.definitionBlock();

            const s5_offset = std.mem.indexOf(
                u8,
                definition_block,
                "_S5_",
            ) orelse return error.S5NotPresent;

            break :blk definition_block[s5_offset..].ptr;
        };

        s5_addr += 4; // skip the last part of NameSeg

        if (s5_addr[0] != 0x12) return error.S5NotPackageOp;
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
        const SLP_EN: u16 = 1 << 13;

        const PM1a_CNT = fadt.getPM1a_CNT();
        const PM1b_CNT_opt = fadt.getPM1b_CNT();

        if (fadt.SMI_CMD != 0 and fadt.ACPI_ENABLE != 0) {
            // we have SMM and we need to enable ACPI mode first
            const smi: arch.io.Port = try .from(fadt.SMI_CMD);
            smi.write(u8, fadt.ACPI_ENABLE);

            for (0..100) |_| {
                _ = port_0x80.read(u8);
            }

            while (try readAddress(u16, PM1a_CNT) & SCI_EN == 0) {
                arch.spinLoopHint();
            }
        }

        try writeAddress(PM1a_CNT, SLP_TYPa | SLP_EN);

        if (PM1b_CNT_opt) |PM1b_CNT| {
            try writeAddress(PM1b_CNT, SLP_TYPb | SLP_EN);
        }

        for (0..100) |_| _ = port_0x80.read(u8);
    }

    const port_0x80 = arch.io.Port.from(0x80) catch unreachable;

    const ReadAddressError = error{
        UnsupportedAddressSpace,
    } || arch.io.Port.FromError;

    fn readAddress(comptime T: type, address: Address) ReadAddressError!T {
        switch (address.address_space) {
            .io => {
                const port: arch.io.Port = try .from(address.address);
                return port.read(T);
            },
            else => return ReadAddressError.UnsupportedAddressSpace,
        }
    }

    const WriteAddressError = error{
        UnsupportedAddressSpace,
        UnsupportedRegisterBitWidth,
        ValueOutOfRange,
    } || arch.io.Port.FromError;

    fn writeAddress(address: Address, value: u64) WriteAddressError!void {
        switch (address.address_space) {
            .io => {
                const port: arch.io.Port = try .from(address.address);

                inline for (.{ 8, 16, 32 }) |bit_width| if (bit_width == address.register_bit_width) {
                    const T = std.meta.Int(.unsigned, bit_width);

                    port.write(T, std.math.cast(
                        T,
                        value,
                    ) orelse return WriteAddressError.ValueOutOfRange);

                    return;
                };

                return WriteAddressError.UnsupportedRegisterBitWidth;
            },
            else => return WriteAddressError.UnsupportedAddressSpace,
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
};

comptime {
    _ = @import("uacpi_kernel_api.zig"); // ensure kernel api is exported
}

const arch = @import("arch");
const kernel = @import("kernel");

const core = @import("core");
const log = kernel.debug.log.scoped(.acpi);
const std = @import("std");
const uacpi = @import("uacpi.zig");
