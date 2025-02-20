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
        var init_output_uart: uart.Uart = undefined;
    };

    blk: {
        const maybe_output_uart: ?uart.Uart = tryGetOutputFromSPCR() catch |err| maybe_output_uart: switch (err) {
            error.DivisorTooLarge => {
                log.warn("baud divisor from SPCR too large", .{});
                break :maybe_output_uart null;
            },
        };
        if (maybe_output_uart) |output_uart| {
            static.init_output_uart = output_uart;
            break :blk;
        }

        return null;
    }

    return static.init_output_uart.output();
}

fn tryGetOutputFromSPCR() uart.Baud.DivisorError!?uart.Uart {
    const spcr = kernel.acpi.getTable(kernel.acpi.tables.SPCR, 0) orelse return null;
    defer spcr.deinit();

    const baud_rate: ?uart.Baud.BaudRate = switch (spcr.table.configured_baud_rate) {
        .as_is => null,
        .@"9600" => .@"9600",
        .@"19200" => .@"19200",
        .@"57600" => .@"57600",
        .@"115200" => .@"115200",
    };

    if (spcr.table.header.revision < 2) {
        switch (spcr.table.interface_type.revision_1) {
            .@"16550" => {
                const baud: ?uart.Baud = if (baud_rate) |br| .{
                    .clock_frequency = .@"1.8432 MHz", // TODO: we assume the clock frequency is 1.8432 MHz
                    .baud_rate = br,
                } else null;

                switch (spcr.table.base_address.address_space) {
                    .memory => return .{
                        .memory_16550 = try uart.Memory16550.init(
                            kernel.vmm.directMapFromPhysical(
                                .fromInt(spcr.table.base_address.address),
                            ).toPtr([*]volatile u8),
                            baud,
                        ) orelse return null,
                    },
                    .io => return .{
                        .io_port_16550 = try uart.IoPort16550.init(
                            @intCast(spcr.table.base_address.address),
                            baud,
                        ) orelse return null,
                    },
                    else => return null,
                }
            },
            .@"16450" => {
                const baud: ?uart.Baud = if (baud_rate) |br| .{
                    .clock_frequency = .@"1.8432 MHz", // TODO: we assume the clock frequency is 1.8432 MHz
                    .baud_rate = br,
                } else null;

                switch (spcr.table.base_address.address_space) {
                    .memory => return .{
                        .memory_16450 = try uart.Memory16450.init(
                            kernel.vmm.directMapFromPhysical(
                                .fromInt(spcr.table.base_address.address),
                            ).toPtr([*]volatile u8),
                            baud,
                        ) orelse return null,
                    },
                    .io => return .{
                        .io_port_16450 = try uart.IoPort16450.init(
                            @intCast(spcr.table.base_address.address),
                            baud,
                        ) orelse return null,
                    },
                    else => return null,
                }
            },
        }
    }

    switch (spcr.table.interface_type.revision_2_or_higher) {
        .@"16550" => {
            const baud: ?uart.Baud = if (baud_rate) |br| .{
                .clock_frequency = .@"1.8432 MHz", // TODO: we assume the clock frequency is 1.8432 MHz
                .baud_rate = br,
            } else null;

            switch (spcr.table.base_address.address_space) {
                .memory => return .{
                    .memory_16550 = try uart.Memory16550.init(
                        kernel.vmm.directMapFromPhysical(
                            .fromInt(spcr.table.base_address.address),
                        ).toPtr([*]volatile u8),
                        baud,
                    ) orelse return null,
                },
                .io => return .{
                    .io_port_16550 = try uart.IoPort16550.init(
                        @intCast(spcr.table.base_address.address),
                        baud,
                    ) orelse return null,
                },
                else => return null,
            }
        },
        .@"16450" => {
            const baud: ?uart.Baud = if (baud_rate) |br| .{
                .clock_frequency = .@"1.8432 MHz", // TODO: we assume the clock frequency is 1.8432 MHz
                .baud_rate = br,
            } else null;

            switch (spcr.table.base_address.address_space) {
                .memory => return .{
                    .memory_16450 = try uart.Memory16450.init(
                        kernel.vmm.directMapFromPhysical(
                            .fromInt(spcr.table.base_address.address),
                        ).toPtr([*]volatile u8),
                        baud,
                    ) orelse return null,
                },
                .io => return .{
                    .io_port_16450 = try uart.IoPort16450.init(
                        @intCast(spcr.table.base_address.address),
                        baud,
                    ) orelse return null,
                },
                else => return null,
            }
        },
        .ArmPL011 => {
            const baud: ?uart.Baud = if (baud_rate) |br| .{
                .clock_frequency = .@"24 MHz", // TODO: we assume the clock frequency is 24 MHz
                .baud_rate = br,
            } else null;

            std.debug.assert(spcr.table.base_address.address_space == .memory);
            std.debug.assert(spcr.table.base_address.access_size == .dword);

            return .{
                .pl011 = try uart.PL011.init(
                    kernel.vmm.directMapFromPhysical(
                        .fromInt(spcr.table.base_address.address),
                    ).toPtr([*]volatile u32),
                    baud,
                ) orelse return null,
            };
        },
        else => return null, // TODO: implement other UARTs
    }
}

pub const globals = struct {
    pub var lock: kernel.sync.TicketSpinLock = .{};

    var outputs: std.BoundedArray(
        Output,
        maximum_number_of_outputs,
    ) = .{};
};

const maximum_number_of_outputs = 8;

pub const uart = @import("uart.zig");

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const log = kernel.debug.log.scoped(.init_output);
