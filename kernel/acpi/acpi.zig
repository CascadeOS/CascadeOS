// SPDX-License-Identifier: MIT AND BSD-2-Clause
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>
// SPDX-FileCopyrightText: 2019-2024 mintsuki and contributors (https://github.com/lowlevelmemes/acpi-shutdown-hack/blob/115c66d097e9d52015907a4ff27cd1ba34aee0d9/LICENSE)

/// Get the `n`th matching ACPI table if present.
///
/// Uses the `SIGNATURE_STRING: *const [4]u8` decl on the given `T` to find the table.
pub fn getTable(comptime T: type, n: usize) ?AcpiTable(T) {
    if (!globals.acpi_tables_initialized) return null;

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

        const interrupts_enabled = kernel.arch.interrupts.areEnabled();
        kernel.arch.interrupts.disableInterrupts();
        defer if (interrupts_enabled) kernel.arch.interrupts.enableInterrupts();

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

        pub fn deinit(self: @This()) void {
            self.handle.unref() catch unreachable;
        }

        pub fn print(self: @This(), writer: std.io.AnyWriter, indent: usize) !void {
            _ = indent;

            try writer.print(
                "AcpiTable{{ signature: {s}, revision: {d} }}",
                .{ self.table.header.signatureAsString(), self.table.header.revision },
            );
        }

        pub inline fn format(
            self: @This(),
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = options;
            _ = fmt;
            return if (@TypeOf(writer) == std.io.AnyWriter)
                print(self, writer, 0)
            else
                print(self, writer.any(), 0);
        }
    };
}

const globals = struct {
    var acpi_tables_initialized: bool = false;
    var acpi_initialized: bool = false;
};

pub const init = struct {
    pub fn initializeACPITables() void {
        const static = struct {
            var buffer: [kernel.arch.paging.standard_page_size.value]u8 = undefined;
        };

        uacpi.setupEarlyTableAccess(&static.buffer) catch return; // suppress error to allow non-ACPI systems to boot

        globals.acpi_tables_initialized = true;
    }

    pub fn initialize() !void {
        init_log.debug("entering ACPI mode", .{});
        try uacpi.initialize(.{});

        try uacpi.FixedEvent.power_button.installHandler(
            void,
            earlyPowerButtonHandler,
            null,
        );

        init_log.debug("loading namespace", .{});
        try uacpi.namespaceLoad();

        if (kernel.config.cascade_target == .x64) {
            try uacpi.setInterruptModel(.ioapic);
        }

        init_log.debug("initializing namespace", .{});
        try uacpi.namespaceInitialize();

        globals.acpi_initialized = true;
    }

    pub fn finializeInitialization() !void {
        init_log.debug("finializing GPEs", .{});
        try uacpi.finializeGpeInitialization();
    }

    fn earlyPowerButtonHandler(_: ?*void) uacpi.InterruptReturn {
        init_log.warn("power button pressed", .{});
        tryShutdown() catch |err| {
            std.debug.panic("failed to shutdown: {s}", .{@errorName(err)});
        };
        @panic("shutdown failed");
    }

    const init_log = kernel.debug.log.scoped(.init_acpi);
};

const hack = struct {
    fn tryHackyShutdown() !void {
        // this is ported from https://github.com/lowlevelmemes/acpi-shutdown-hack/blob/trunk/acpi_shutdown_hack.c

        const acpi_table = getTable(tables.FADT, 0) orelse return error.FADTNotPresent;
        defer acpi_table.deinit();

        const fadt: *const tables.FADT = acpi_table.table;

        var s5_addr: [*]const u8 = blk: {
            const dsdt = kernel.vmm
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

    fn readAddress(comptime T: type, address: Address) ReadAddressError!T {
        switch (address.address_space) {
            .io => {
                const port = std.math.cast(
                    kernel.arch.io.Port,
                    address.address,
                ) orelse return ReadAddressError.InvalidPort;

                return kernel.arch.io.readPort(T, port);
            },
            else => return ReadAddressError.UnsupportedAddressSpace,
        }
    }

    const WriteAddressError = error{
        UnsupportedAddressSpace,
        UnsupportedRegisterBitWidth,
        InvalidPort,
        ValueOutOfRange,
    } || kernel.arch.io.PortError;

    fn writeAddress(address: Address, value: u64) WriteAddressError!void {
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

                return WriteAddressError.UnsupportedPortSize;
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

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const log = kernel.debug.log.scoped(.acpi);
const uacpi = @import("uacpi.zig");
