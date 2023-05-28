// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");

pub const arch = @import("arch/arch.zig");
pub const boot = @import("boot/boot.zig");
pub const info = @import("info.zig");
pub const log = @import("log.zig");
pub const pmm = @import("pmm.zig");
pub const setup = @import("setup.zig");

comptime {
    // make sure any bootloader specific code that needs to be referenced is
    _ = boot;

    // ensure any architecture specific code that needs to be referenced is
    _ = arch;
}

pub const panic_implementation = struct {
    pub const PanicState = enum(u8) {
        no_op = 0,
        simple = 1,
        full = 2,
    };

    var state: PanicState = .no_op;

    /// Switches the panic state to the given state.
    /// Panics if the new state is less than the current state.
    pub fn switchTo(new_state: PanicState) void {
        if (@enumToInt(state) < @enumToInt(new_state)) {
            state = new_state;
            return;
        }

        core.panicFmt("cannot switch to {s} panic from {s} panic", .{ @tagName(new_state), @tagName(state) });
    }

    /// Entry point from the Zig language upon a panic.
    pub fn panic(
        msg: []const u8,
        stack_trace: ?*const std.builtin.StackTrace,
        ret_addr: ?usize,
    ) noreturn {
        @setCold(true);
        switch (state) {
            .no_op => arch.interrupts.disableInterruptsAndHalt(),
            .simple => simplePanic(msg, stack_trace, ret_addr),
            .full => panicImpl(msg, stack_trace, ret_addr),
        }
    }

    /// Prints the panic message then disables interrupts and halts.
    fn simplePanic(
        msg: []const u8,
        stack_trace: ?*const std.builtin.StackTrace,
        ret_addr: ?usize,
    ) noreturn {
        _ = ret_addr;
        _ = stack_trace;

        arch.setup.getEarlyOutputWriter().print("\nPANIC: {s}\n", .{msg}) catch unreachable;

        while (true) {
            arch.interrupts.disableInterruptsAndHalt();
        }
    }

    /// Prints the panic message, stack trace, and registers then disables interrupts and halts.
    fn panicImpl(
        msg: []const u8,
        stack_trace: ?*const std.builtin.StackTrace,
        ret_addr: ?usize,
    ) noreturn {
        // TODO: Implement `panicImpl`
        simplePanic(msg, stack_trace, ret_addr);
    }
};
