// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>

pub const instructions = @import("instructions.zig");
pub const registers = @import("registers.zig");

pub const cpu_id = @import("cpu_id.zig");
pub const Gdt = @import("Gdt.zig").Gdt;
pub const Hpet = @import("Hpet.zig");
pub const Idt = @import("Idt.zig");
pub const IOAPIC = @import("IOAPIC.zig");
pub const LAPIC = @import("LAPIC.zig").LAPIC;
pub const InterruptVector = @import("InterruptVector.zig").InterruptVector;
pub const PageFaultErrorCode = @import("PageFaultErrorCode.zig").PageFaultErrorCode;
pub const PageTable = @import("PageTable.zig").PageTable;
pub const Tss = @import("Tss.zig").Tss;

pub const PrivilegeLevel = enum(u2) {
    ring0 = 0,
    ring1 = 1,
    ring2 = 2,
    ring3 = 3,
};

pub const MemoryType = enum(u8) {
    /// All accesses are uncacheable.
    ///
    /// Write combining is not allowed.
    ///
    /// Speculative accesses are not allowed
    unchacheable = 0x0,

    /// All accesses are uncacheable.
    ///
    /// Write combining is allowed.
    ///
    /// Speculative reads are allowed
    write_combining = 0x1,

    /// Reads allocate cache lines on a cache miss.
    ///
    /// Cache lines are not allocated on a write miss.
    ///
    /// Write hits update the cache and main memory.
    write_through = 0x4,

    /// Reads allocate cache lines on a cache miss.
    ///
    /// All writes update main memory.
    ///
    /// Cache lines are not allocated on a write miss.
    ///
    /// Write hits invalidate the cache line and update main memory.
    write_protected = 0x5,

    /// Reads allocate cache lines on a cache miss, and can allocate to either the shared, exclusive, or modified
    /// state
    ///
    /// Writes allocate to the modified state on a cache miss.
    write_back = 0x6,

    _,
};

/// Remaps the PIC interrupts to 0x20-0x2f and masks all of them.
pub fn disablePic() void {
    const portWriteU8 = instructions.portWriteU8;

    const PRIMARY_COMMAND_PORT = 0x20;
    const PRIMARY_DATA_PORT = 0x21;
    const SECONDARY_COMMAND_PORT = 0xA0;
    const SECONDARY_DATA_PORT = 0xA1;

    const CMD_INIT = 0x11;
    const MODE_8086: u8 = 0x01;

    // Tell each PIC that we're going to send it a three-byte initialization sequence on its data port.
    portWriteU8(PRIMARY_COMMAND_PORT, CMD_INIT);
    portWriteU8(0x80, 0); // wait
    portWriteU8(SECONDARY_COMMAND_PORT, CMD_INIT);
    portWriteU8(0x80, 0); // wait

    // Remap master PIC to 0x20
    portWriteU8(PRIMARY_DATA_PORT, 0x20);
    portWriteU8(0x80, 0); // wait

    // Remap slave PIC to 0x28
    portWriteU8(SECONDARY_DATA_PORT, 0x28);
    portWriteU8(0x80, 0); // wait

    // Configure chaining between master and slave
    portWriteU8(PRIMARY_DATA_PORT, 4);
    portWriteU8(0x80, 0); // wait
    portWriteU8(SECONDARY_DATA_PORT, 2);
    portWriteU8(0x80, 0); // wait

    // Set our mode.
    portWriteU8(PRIMARY_DATA_PORT, MODE_8086);
    portWriteU8(0x80, 0); // wait
    portWriteU8(SECONDARY_DATA_PORT, MODE_8086);
    portWriteU8(0x80, 0); // wait

    // Mask all interrupts
    portWriteU8(PRIMARY_DATA_PORT, 0xFF);
    portWriteU8(0x80, 0); // wait
    portWriteU8(SECONDARY_DATA_PORT, 0xFF);
    portWriteU8(0x80, 0); // wait
}

comptime {
    refAllDeclsRecursive(@This());
}

fn refAllDeclsRecursive(comptime T: type) void {
    if (!@import("builtin").is_test) return;
    @setEvalBranchQuota(1_000_000);

    inline for (comptime std.meta.declarations(T)) |decl| {
        // FIXME: have to skip `PageTable` due to hitting a `@compileError` for `std.atomic.Value.fence`
        if (std.mem.eql(u8, decl.name, "PageTable")) continue;

        if (@TypeOf(@field(T, decl.name)) == type) {
            switch (@typeInfo(@field(T, decl.name))) {
                .@"struct", .@"enum", .@"union", .@"opaque" => refAllDeclsRecursive(@field(T, decl.name)),
                else => {},
            }
        }
        _ = &@field(T, decl.name);
    }
}

const std = @import("std");
const core = @import("core");

const x64 = @This();
