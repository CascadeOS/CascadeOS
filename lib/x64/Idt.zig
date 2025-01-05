// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>

const Idt = @This();

/// The number of interrupt handlers in the IDT.
pub const number_of_handlers = 256;

handlers: [number_of_handlers]Entry align(16) = std.mem.zeroes([number_of_handlers]Entry),

pub const Entry = extern struct {
    /// Low 16-bits of ISR address
    pointer_low: u16,

    /// The code selector to switch to when the interrupt is recieved.
    code_selector: x64.Gdt.Selector,

    options: Options,

    /// Middle 16-bits of ISR address
    pointer_middle: u16,

    /// Upper 32-bits of ISR address
    pointer_high: u32,

    _reserved: u32 = 0,

    pub const Options = packed struct(u16) {
        /// Offset into the Interrupt Stack Table, zero means not used.
        ist: u3 = 0,

        _reserved1: u5 = 0,

        gate_type: GateType,

        _reserved2: u1 = 0,

        /// Defines the privilege levels which are allowed to access this interrupt via the INT instruction.
        ///
        /// Hardware interrupts ignore this mechanism.
        privilege_level: x64.PrivilegeLevel = .ring0,

        present: bool,
    };

    pub const GateType = enum(u4) {
        /// Interrupts are automatically disabled upon entry and reenabled upon IRET
        interrupt = 0xE,

        trap = 0xF,
    };

    pub fn init(
        self: *Entry,
        code_selector: x64.Gdt.Selector,
        gate_type: GateType,
        handler: *const fn () callconv(.Naked) void,
    ) void {
        self.* = .{
            .pointer_low = undefined,
            .code_selector = code_selector,
            .options = .{
                .gate_type = gate_type,
                .present = true,
            },
            .pointer_middle = undefined,
            .pointer_high = undefined,
        };
        self.setHandler(handler);
    }

    /// Sets the interrupt handler for this interrupt.
    pub fn setHandler(self: *Entry, handler: *const fn () callconv(.Naked) void) void {
        const address = @intFromPtr(handler);
        self.pointer_low = @truncate(address);
        self.pointer_middle = @truncate(address >> 16);
        self.pointer_high = @truncate(address >> 32);
    }

    /// Sets the interrupt stack table (IST) index for this interrupt.
    pub fn setStack(self: *Entry, interrupt_stack: u3) void {
        self.options.ist = interrupt_stack +% 1;
    }

    comptime {
        core.testing.expectSize(@This(), @sizeOf(u64) * 2);
    }
};

pub fn load(self: *const Idt) void {
    const Idtr = packed struct {
        limit: u16,
        address: u64,
    };

    const idtr = Idtr{
        .address = @intFromPtr(self),
        .limit = @sizeOf(Idt) - 1,
    };

    asm volatile (
        \\  lidt (%[idtr_address])
        :
        : [idtr_address] "r" (&idtr),
    );
}

comptime {
    std.testing.refAllDeclsRecursive(@This());
}

const core = @import("core");
const std = @import("std");

const x64 = @import("x64");
