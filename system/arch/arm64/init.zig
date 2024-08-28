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
    // TODO: use the direct map to access the UART
    // opt_early_output_uart = Uart.init(0x09000000 + direct_map_offset);
}

/// Write to early output.
///
/// Cannot fail, any errors are ignored.
pub fn writeToEarlyOutput(bytes: []const u8) void {
    if (opt_early_output_uart) |early_output_uart| {
        early_output_uart.write(bytes);
    }
}

/// A basic write only UART.
const Uart = struct {
    address: *volatile u8,

    pub fn init(address: usize) Uart {
        return .{
            .address = @ptrFromInt(address),
        };
    }

    /// Write to the UART.
    pub fn write(self: Uart, bytes: []const u8) void {
        var previous_byte: u8 = 0;

        for (bytes) |byte| {
            defer previous_byte = byte;

            if (byte == '\n' and previous_byte != '\r') {
                // TODO: per branch cold
                self.address.* = '\r';
            }

            self.address.* = byte;
        }
    }
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const arm64 = @import("arm64.zig");
const arch = @import("arch");
