// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz

/// Attempt to set up some form of early output.
pub fn setupEarlyOutput() void {
    // TODO: we can't assume the UART is actually at this address unless we are on qemu virt.
    globals.opt_early_output_uart = Uart.init(kernel.vmm.directMapFromPhysical(core.PhysicalAddress.fromInt(0x09000000)));
}

/// Write to early output.
///
/// Cannot fail, any errors are ignored.
pub fn writeToEarlyOutput(bytes: []const u8) void {
    if (globals.opt_early_output_uart) |early_output_uart| {
        early_output_uart.write(bytes);
    }
}

const globals = struct {
    var opt_early_output_uart: ?Uart = null;
};

/// A basic write only UART.
const Uart = struct {
    ptr: *volatile u8,

    pub fn init(address: core.VirtualAddress) Uart {
        return .{
            .ptr = address.toPtr(*volatile u8),
        };
    }

    pub fn write(self: Uart, bytes: []const u8) void {
        var previous_byte: u8 = 0;

        for (bytes) |byte| {
            defer previous_byte = byte;

            if (byte == '\n' and previous_byte != '\r') {
                @branchHint(.unlikely);
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
const lib_arm64 = @import("arm64");
