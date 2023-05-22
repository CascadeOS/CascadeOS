// SPDX-License-Identifier: MIT

const std = @import("std");

pub const arch = @import("arch/arch.zig");
pub const info = @import("info.zig");
pub const log = @import("log.zig");
pub const setup = @import("setup.zig");

pub const spec = @import("spec/spec.zig");

comptime {
    // ensure any architecture specific code is referenced
    _ = arch;
}

/// The signature of a panic implementation function.
pub const PanicFunction = *const fn (
    msg: []const u8,
    stack_trace: ?*const std.builtin.StackTrace,
    ret_addr: ?usize,
) noreturn;

/// Set the function pointer to the implementation of panic.
pub fn setPanicFunction(panic_fn: PanicFunction) void {
    panic_impl = panic_fn;
}

/// A function pointer to the current implementation of panic.
/// This will change from "`noOpPanic` -> early boot panic -> normal panic" during system setup.
var panic_impl: PanicFunction = noOpPanic;

/// A no-op panic used before any infrastructure is ready.
fn noOpPanic(
    msg: []const u8,
    stack_trace: ?*const std.builtin.StackTrace,
    ret_addr: ?usize,
) noreturn {
    _ = ret_addr;
    _ = stack_trace;
    _ = msg;
    while (true) {
        arch.interface.disableInterruptsAndHalt();
    }
}

/// Entry point from the Zig language upon a panic.
pub fn panic(
    msg: []const u8,
    stack_trace: ?*const std.builtin.StackTrace,
    ret_addr: ?usize,
) noreturn {
    @setCold(true);
    panic_impl(msg, stack_trace, ret_addr);
}

pub const std_options = struct {
    // ensure using `std.log` in the kernel is a compile error
    pub const log_level = @compileError("use `kernel.log` for logging in the kernel");

    // ensure using `std.log` in the kernel is a compile error
    pub const logFn = @compileError("use `kernel.log` for logging in the kernel");
};
