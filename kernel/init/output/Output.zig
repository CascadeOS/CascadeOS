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
            if (globals.framebuffer_output) |output| output.writeFn(output.context, bytes);
            if (globals.serial_output) |output| output.writeFn(output.context, bytes);
            return bytes.len;
        }
    }.writeFn,
){ .context = {} };

/// Allow outputs to remap themselves into the non-cached direct map or special heap.
pub fn remapOutputs(current_task: *kernel.Task) !void {
    if (globals.framebuffer_output) |output| try output.remapFn(output.context, current_task);
    if (globals.serial_output) |output| try output.remapFn(output.context, current_task);
}

pub fn registerOutputs() void {
    if (@import("framebuffer.zig").tryGetFramebufferOutput()) |output| {
        globals.framebuffer_output = output;
    }

    if (kernel.arch.init.tryGetSerialOutput()) |output| {
        globals.serial_output = output;
    }
}

pub fn tryGetSerialOutputFromAcpiTables() ?kernel.init.Output {
    const static = struct {
        var init_output_uart: uart.Uart = undefined;
    };

    blk: {
        if (tryGetSerialOutputFromSPCR()) |output_uart| {
            static.init_output_uart = output_uart;
            break :blk;
        }

        if (tryGetSerialOutputFromDBG2()) |output_uart| {
            static.init_output_uart = output_uart;
            break :blk;
        }

        return null;
    }

    return static.init_output_uart.output();
}

pub const globals = struct {
    pub var lock: kernel.sync.TicketSpinLock = .{};

    var framebuffer_output: ?Output = null;
    var serial_output: ?Output = null;
};

pub const uart = @import("uart.zig");

fn tryGetSerialOutputFromSPCR() ?uart.Uart {
    const output_uart = tryGetSerialOutputFromSPCRInner() catch |err| switch (err) {
        error.DivisorTooLarge => {
            log.warn("baud divisor from SPCR too large", .{});
            return null;
        },
    } orelse return null;

    return output_uart;
}

fn tryGetSerialOutputFromSPCRInner() uart.Baud.DivisorError!?uart.Uart {
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

fn tryGetSerialOutputFromDBG2() ?uart.Uart {
    const dbg2 = kernel.acpi.getTable(kernel.acpi.tables.DBG2, 0) orelse return null;
    defer dbg2.deinit();

    var devices: kernel.acpi.tables.DBG2.DebugDeviceIterator = dbg2.table.debugDevices();

    while (devices.next()) |device| {
        const address = blk: {
            var addresses = device.addresses();
            const first_address = addresses.next() orelse continue;
            break :blk first_address.address;
        };

        switch (device.portType()) {
            .serial => |subtype| switch (subtype) {
                .@"16550", .@"16550-GAS" => {
                    switch (address.address_space) {
                        .memory => return .{
                            .memory_16550 = (uart.Memory16550.init(
                                kernel.vmm.directMapFromPhysical(
                                    .fromInt(address.address),
                                ).toPtr([*]volatile u8),
                                null,
                            ) catch unreachable) orelse continue,
                        },
                        .io => return .{
                            .io_port_16550 = (uart.IoPort16550.init(
                                @intCast(address.address),
                                null,
                            ) catch unreachable) orelse continue,
                        },
                        else => {},
                    }
                },
                .@"16450" => {
                    switch (address.address_space) {
                        .memory => return .{
                            .memory_16450 = (uart.Memory16450.init(
                                kernel.vmm.directMapFromPhysical(
                                    .fromInt(address.address),
                                ).toPtr([*]volatile u8),
                                null,
                            ) catch unreachable) orelse continue,
                        },
                        .io => return .{
                            .io_port_16450 = (uart.IoPort16450.init(
                                @intCast(address.address),
                                null,
                            ) catch unreachable) orelse continue,
                        },
                        else => {},
                    }
                },
                .ArmPL011 => {
                    std.debug.assert(address.address_space == .memory);
                    std.debug.assert(address.access_size == .dword);

                    return .{
                        .pl011 = (uart.PL011.init(
                            kernel.vmm.directMapFromPhysical(
                                .fromInt(address.address),
                            ).toPtr([*]volatile u32),
                            null,
                        ) catch unreachable) orelse continue,
                    };
                },
                else => {}, // TODO: implement other serial subtypes
            },
            else => {}, // TODO: implement other port types
        }
    }

    return null;
}

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const log = kernel.debug.log.scoped(.init_output);
