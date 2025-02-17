// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>

const Output = @This();

writeFn: *const fn (context: *anyopaque, str: []const u8) void,

/// Called to allow the output to remap itself into the non-cached direct map or special heap after they have been
/// initialized.
remapFn: *const fn (context: *anyopaque, current_task: *kernel.Task) anyerror!void,

context: *anyopaque,

pub const writer = std.io.GenericWriter(
    void,
    error{},
    struct {
        fn writeFn(_: void, bytes: []const u8) error{}!usize {
            for (globals.outputs.constSlice()) |output| {
                output.writeFn(output.context, bytes);
            }
            return bytes.len;
        }
    }.writeFn,
){ .context = {} };

/// Allow outputs to remap themselves into the non-cached direct map or special heap.
pub fn remapOutputs(current_task: *kernel.Task) !void {
    for (globals.outputs.constSlice()) |output| {
        try output.remapFn(output.context, current_task);
    }
}

pub fn registerOutputs() void {
    const registerOutput = struct {
        fn registerOutput(output: Output) void {
            globals.outputs.append(output) catch @panic("exceeded maximum number of init outputs");
        }
    }.registerOutput;

    if (@import("framebuffer.zig").tryGetOutput()) |output| registerOutput(output);

    if (kernel.arch.init.tryGetOutput()) |output| registerOutput(output);
}

pub fn tryGetOutputFromAcpiTables() ?kernel.init.Output {
    // TODO: DBG2 https://github.com/MicrosoftDocs/windows-driver-docs/blob/staging/windows-driver-docs-pr/bringup/acpi-debug-port-table.md

    const static = struct {
        var init_output_uart: Uart = undefined;
    };

    const spcr = kernel.acpi.getTable(kernel.acpi.tables.SPCR, 0) orelse return null;
    defer spcr.deinit();
    std.debug.assert(spcr.table.base_address.address_space == .memory);

    static.init_output_uart = Uart.init(kernel.vmm.directMapFromPhysical(.fromInt(spcr.table.base_address.address)));
    return static.init_output_uart.output();
}

pub const globals = struct {
    pub var lock: kernel.sync.TicketSpinLock = .{};

    var outputs: std.BoundedArray(
        Output,
        maximum_number_of_outputs,
    ) = .{};
};

const maximum_number_of_outputs = 8;

/// A basic write only UART.
///
/// TODO: a write only implementation covering memory mapped 16550, io port 16550 and Arm PL011
/// [PC16550D Universal Asynchronous Receiver/Transmitter with FIFOs](https://media.digikey.com/pdf/Data%20Sheets/Texas%20Instruments%20PDFs/PC16550D.pdf)
/// [or this one](https://caro.su/msx/ocm_de1/16550.pdf)
const Uart = struct {
    ptr: *volatile u8,

    pub fn init(address: core.VirtualAddress) Uart {
        return .{
            .ptr = address.toPtr(*volatile u8),
        };
    }

    pub fn output(self: *Uart) kernel.init.Output {
        return .{
            .writeFn = struct {
                fn writeFn(context: *anyopaque, str: []const u8) void {
                    const uart: *Uart = @ptrCast(@alignCast(context));
                    for (0..str.len) |i| {
                        const byte = str[i];

                        if (byte == '\n') {
                            @branchHint(.unlikely);

                            if (i != 0 and str[i - 1] != '\r') {
                                @branchHint(.likely);
                                uart.ptr.* = '\r';
                            }
                        }

                        uart.ptr.* = byte;
                    }
                }
            }.writeFn,
            .remapFn = struct {
                fn remapFn(context: *anyopaque, _: *kernel.Task) anyerror!void {
                    const uart: *Uart = @ptrCast(@alignCast(context));
                    const physical_address = try kernel.vmm.physicalFromDirectMap(.fromPtr(@volatileCast(uart.ptr)));
                    uart.ptr = kernel.vmm.nonCachedDirectMapFromPhysical(physical_address).toPtr(*volatile u8);
                }
            }.remapFn,
            .context = self,
        };
    }
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
