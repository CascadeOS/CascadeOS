// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const x86_64 = @import("../x86_64.zig");

const Idt = @This();

/// The number of interrupt handlers in the IDT.
pub const number_of_handlers = 256;

handlers: [number_of_handlers]Entry align(16) = std.mem.zeroes([number_of_handlers]Entry),

pub const Entry = extern struct {
    /// low 16-bits of ISR address
    pointer_low: u16,

    /// the code selector to switch to when the interrupt is recieved.
    code_selector: u16,

    options: Options,

    /// middle 16-bits of ISR address
    pointer_middle: u16,

    /// upper 32-bits of ISR address
    pointer_high: u32,

    _reserved: u32 = 0,

    pub const Options = packed struct(u16) {
        /// offset into the Interrupt Stack Table, zero means not used.
        ist: u3 = 0,

        _reserved1: u5 = 0,

        gate_type: GateType,

        _reserved2: u1 = 0,

        /// defines the privilege levels which are allowed to access this interrupt via the INT instruction.
        /// hardware interrupts ignore this mechanism.
        privilege_level: x86_64.PrivilegeLevel = .ring0,

        present: bool,

        pub const format = core.formatStructIgnoreReserved;
    };

    pub const GateType = enum(u4) {
        /// interrupts are automatically disabled upon entry and reenabled upon IRET
        interrupt = 0xE,

        trap = 0xF,
    };

    pub fn init(
        self: *Entry,
        code_selector: u16,
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

    pub fn setHandler(self: *Entry, handler: *const fn () callconv(.Naked) void) void {
        const addr = @intFromPtr(handler);
        self.pointer_low = @truncate(addr);
        self.pointer_middle = @truncate((addr >> 16));
        self.pointer_high = @truncate((addr >> 32));
    }

    pub fn setStack(self: *Entry, interrupt_stack: u3) void {
        self.options.ist = interrupt_stack +% 1;
    }

    comptime {
        core.testing.expectSize(@This(), @sizeOf(u64) * 2);
    }

    pub const format = core.formatStructIgnoreReserved;
};

pub fn load(self: *const Idt) void {
    const Idtr = packed struct {
        limit: u16,
        addr: u64,
    };

    const idtr = Idtr{
        .addr = @intFromPtr(self),
        .limit = @sizeOf(Idt) - 1,
    };

    asm volatile (
        \\  lidt (%[idtr_addr])
        :
        : [idtr_addr] "r" (&idtr),
    );
}
