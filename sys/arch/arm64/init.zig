// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

/// The entry point that is exported as `_start` and acts as fallback entry point for unknown bootloaders.
///
/// No bootloader is ever expected to call `_start` and instead should use bootloader specific entry points;
/// meaning this function is not expected to ever be called.
///
/// This function is required to disable interrupts and halt execution at a minimum but may perform any additional
/// debugging and error output if possible.
pub fn unknownBootloaderEntryPoint() callconv(.Naked) noreturn {
    @call(.always_inline, arch.interrupts.disableInterruptsAndHalt, .{});
    unreachable;
}

var opt_early_output_uart: ?Uart = null;

/// Attempt to set up some form of early output.
pub fn setupEarlyOutput() void {
    // TODO: we can't assume the UART is actually at this address unless we are on qemu virt.
    opt_early_output_uart = Uart.init(kernel.mem.directMapFromPhysical(core.PhysicalAddress.fromInt(0x09000000)));
}

/// Write to early output.
///
/// Cannot fail, any errors are ignored.
pub fn writeToEarlyOutput(bytes: []const u8) void {
    if (opt_early_output_uart) |early_output_uart| {
        early_output_uart.write(bytes);
    }
}

/// Prepares the provided `Executor` for the bootstrap executor.
pub fn prepareBootstrapExecutor(
    bootstrap_executor: *kernel.Executor,
) void {
    bootstrap_executor.arch = .{};
}

/// Load the provided `Executor` as the current executor.
pub fn loadExecutor(executor: *kernel.Executor) void {
    lib_arm64.registers.TPIDR_EL1.write(@intFromPtr(executor));
}

/// A basic write only UART.
const Uart = struct {
    ptr: *volatile u8,

    pub fn init(address: core.VirtualAddress) Uart {
        return .{
            .ptr = address.toPtr(*volatile u8),
        };
    }

    /// Write to the UART.
    pub fn write(self: Uart, bytes: []const u8) void {
        var previous_byte: u8 = 0;

        for (bytes) |byte| {
            defer previous_byte = byte;

            if (byte == '\n' and previous_byte != '\r') {
                // TODO: per branch cold
                self.ptr.* = '\r';
            }

            self.ptr.* = byte;
        }
    }
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const arm64 = @import("arm64.zig");
const arch = @import("arch");
const lib_arm64 = @import("lib_arm64");
