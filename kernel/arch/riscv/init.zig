// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz

/// Attempt to register some form of init output.
pub fn registerInitOutput() void {
    const static = struct {
        var init_output_uart: Uart = undefined;
    };

    const spcr = kernel.acpi.getTable(kernel.acpi.tables.SPCR, 0) orelse return;
    defer spcr.deinit();
    std.debug.assert(spcr.table.base_address.address_space == .memory);

    static.init_output_uart = Uart.init(
        kernel.vmm.directMapFromPhysical(core.PhysicalAddress.fromInt(spcr.table.base_address.address)),
    );

    kernel.init.Output.registerOutput(.{
        .writeFn = struct {
            fn writeFn(context: *anyopaque, str: []const u8) void {
                const uart: *Uart = @ptrCast(@alignCast(context));
                uart.write(str);
            }
        }.writeFn,
        .remapFn = struct {
            fn remapFn(context: *anyopaque, _: *kernel.Task) anyerror!void {
                const uart: *Uart = @ptrCast(@alignCast(context));
                const physical_address = try kernel.vmm.physicalFromDirectMap(.fromPtr(@volatileCast(uart.ptr)));
                uart.ptr = kernel.vmm.nonCachedDirectMapFromPhysical(physical_address).toPtr(*volatile u8);
            }
        }.remapFn,
        .context = &static.init_output_uart,
    });
}

/// Prepares the provided `Executor` for the bootstrap executor.
pub fn prepareBootstrapExecutor(
    bootstrap_executor: *kernel.Executor,
) void {
    bootstrap_executor.arch = .{};
}

/// Load the provided `Executor` as the current executor.
pub fn loadExecutor(executor: *kernel.Executor) void {
    lib_riscv.registers.SupervisorScratch.write(@intFromPtr(executor));
}

/// A basic write only UART.
const Uart = struct {
    ptr: *volatile u8,

    pub fn init(address: core.VirtualAddress) Uart {
        return .{
            .ptr = address.toPtr(*volatile u8),
        };
    }

    pub fn write(self: Uart, bytes: []const u8) void {
        for (0..bytes.len) |i| {
            const byte = bytes[i];

            if (byte == '\n') {
                @branchHint(.unlikely);

                if (i != 0 and bytes[i - 1] != '\r') {
                    @branchHint(.likely);
                    self.ptr.* = '\r';
                }
            }

            self.ptr.* = byte;
        }
    }
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const riscv = @import("riscv.zig");
const lib_riscv = @import("riscv");
