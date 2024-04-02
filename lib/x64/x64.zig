// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");

const x64 = @This();

pub usingnamespace @import("instructions.zig");
pub usingnamespace @import("registers.zig");

pub const cpu_id = @import("cpu_id.zig");
pub const Gdt = @import("Gdt.zig").Gdt;
pub const Hpet = @import("Hpet.zig");
pub const Idt = @import("Idt.zig");
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

/// Remaps the PIC interrupts to 0x20-0x2f and masks all of them.
pub fn disablePic() void {
    const PRIMARY_COMMAND_PORT = 0x20;
    const PRIMARY_DATA_PORT = 0x21;
    const SECONDARY_COMMAND_PORT = 0xA0;
    const SECONDARY_DATA_PORT = 0xA1;

    const CMD_INIT = 0x11;
    const MODE_8086: u8 = 0x01;

    // Tell each PIC that we're going to send it a three-byte initialization sequence on its data port.
    x64.portWriteU8(PRIMARY_COMMAND_PORT, CMD_INIT);
    x64.portWriteU8(0x80, 0); // wait
    x64.portWriteU8(SECONDARY_COMMAND_PORT, CMD_INIT);
    x64.portWriteU8(0x80, 0); // wait

    // Remap master PIC to 0x20
    x64.portWriteU8(PRIMARY_DATA_PORT, 0x20);
    x64.portWriteU8(0x80, 0); // wait

    // Remap slave PIC to 0x28
    x64.portWriteU8(SECONDARY_DATA_PORT, 0x28);
    x64.portWriteU8(0x80, 0); // wait

    // Configure chaining between master and slave
    x64.portWriteU8(PRIMARY_DATA_PORT, 4);
    x64.portWriteU8(0x80, 0); // wait
    x64.portWriteU8(SECONDARY_DATA_PORT, 2);
    x64.portWriteU8(0x80, 0); // wait

    // Set our mode.
    x64.portWriteU8(PRIMARY_DATA_PORT, MODE_8086);
    x64.portWriteU8(0x80, 0); // wait
    x64.portWriteU8(SECONDARY_DATA_PORT, MODE_8086);
    x64.portWriteU8(0x80, 0); // wait

    // Mask all interrupts
    x64.portWriteU8(PRIMARY_DATA_PORT, 0xFF);
    x64.portWriteU8(0x80, 0); // wait
    x64.portWriteU8(SECONDARY_DATA_PORT, 0xFF);
    x64.portWriteU8(0x80, 0); // wait
}

comptime {
    refAllDeclsRecursive(@This());
}

// Copy of `std.testing.refAllDeclsRecursive`, being in the file give access to private decls.
fn refAllDeclsRecursive(comptime T: type) void {
    if (!@import("builtin").is_test) return;

    inline for (switch (@typeInfo(T)) {
        .Struct => |info| info.decls,
        .Enum => |info| info.decls,
        .Union => |info| info.decls,
        .Opaque => |info| info.decls,
        else => @compileError("Expected struct, enum, union, or opaque type, found '" ++ @typeName(T) ++ "'"),
    }) |decl| {
        if (@TypeOf(@field(T, decl.name)) == type) {
            switch (@typeInfo(@field(T, decl.name))) {
                .Struct, .Enum, .Union, .Opaque => refAllDeclsRecursive(@field(T, decl.name)),
                else => {},
            }
        }
        _ = &@field(T, decl.name);
    }
}
