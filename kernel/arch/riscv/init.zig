// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");
const riscv = @import("riscv.zig");

var early_output_uart: ?Uart = null;

/// Attempt to set up some form of early output.
pub fn setupEarlyOutput() void {
    if (kernel.boot.directMapAddress()) |direct_map_address| {
        early_output_uart = Uart.init(0x10000000 + direct_map_address.value); // TODO: Actually detect the UART
    }
}

/// Acquire a writer for the early output setup by `setupEarlyOutput`.
pub fn getEarlyOutput() ?Uart.Writer {
    return if (early_output_uart) |output| output.writer() else null;
}

/// Prepares the provided `Cpu` for the bootstrap CPU.
pub fn prepareBootstrapCpu(
    bootstrap_cpu: *kernel.Cpu,
) void {
    bootstrap_cpu.arch = .{};
}

/// Load the provided `Cpu` as the current CPU.
pub fn loadCpu(cpu: *kernel.Cpu) void {
    riscv.SupervisorScratch.write(@intFromPtr(cpu));
}

/// A basic write only UART.
pub const Uart = struct {
    address: *volatile u8,

    pub fn init(address: usize) Uart {
        return .{
            .address = @ptrFromInt(address),
        };
    }

    pub const Writer = std.io.Writer(Uart, error{}, writerImpl);
    pub inline fn writer(self: Uart) Writer {
        return .{ .context = self };
    }

    /// The impl function driving the `std.io.Writer`
    fn writerImpl(self: Uart, bytes: []const u8) error{}!usize {
        var previous_byte: u8 = 0;

        for (bytes) |byte| {
            defer previous_byte = byte;

            if (byte == '\n' and previous_byte != '\r') {
                // TODO: per branch cold
                self.address.* = '\r';
            }

            self.address.* = byte;
        }

        return bytes.len;
    }
};
