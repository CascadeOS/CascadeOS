// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

// FIXME: we assume #address-cells and #size-cells are both two

const std = @import("std");

const arch = @import("arch");
const boot = @import("boot");
const kernel = @import("kernel");
const Task = kernel.Task;
const uart = kernel.init.Output.uart;
const core = @import("core");
pub const DeviceTree = @import("DeviceTree");

const log = kernel.debug.log.scoped(.devicetree);

pub fn tryGetSerialOutput(memory_system_available: bool) ?uart.Uart {
    return tryGetSerialOutputInner(memory_system_available) catch |err| {
        switch (err) {
            error.BadOffset => {
                log.warn("attempted to use a bad offset into the device tree", .{});
            },
            error.Truncated => {
                log.warn("the device tree blob is truncated", .{});
            },
            error.DivisorTooLarge => {
                log.warn("baud divisor too large", .{});
            },
            error.SizeNotMultiple => {
                log.warn("the regs property size is not a multiple of the address-cells + size-cells", .{});
            },
            error.NoError => {},
            else => log.err("failed to initialize serial output: {}", .{err}),
        }

        return null;
    };
}

fn tryGetSerialOutputInner(memory_system_available: bool) !uart.Uart {
    const dt = getDeviceTree() orelse return error.NoError;

    if (try getSerialOutputFromChosenNode(dt, memory_system_available)) |output_uart| return output_uart;

    var iter = try dt.nodeCompatibleMatchIteratorAdvanced(
        .root,
        .all_children,
        {},
        matchFunction,
    );

    while (try iter.next(dt)) |compatible_match| {
        const func = compatible_lookup.get(compatible_match.compatible).?;
        if (try func(dt, compatible_match.node.node, memory_system_available)) |output_uart| return output_uart;
    }

    return error.NoError;
}

fn getDeviceTree() ?DeviceTree {
    const address = boot.deviceTreeBlob() orelse return null;
    const ptr = address.toPtr([*]align(8) const u8);
    return DeviceTree.fromPtr(ptr) catch |err| {
        log.warn("failed to parse device tree blob: {t}", .{err});
        return null;
    };
}

fn getSerialOutputFromChosenNode(dt: DeviceTree, memory_system_available: bool) GetSerialOutputError!?uart.Uart {
    const chosen_node = blk: {
        var node_iter = try dt.nodeIterator(
            .root,
            .direct_children,
            .{ .name = "chosen" },
        );
        break :blk (try node_iter.next(dt)) orelse return null;
    };

    const stdout_path_property = blk: {
        var property_iter = try chosen_node.node.propertyIterator(
            dt,
            .{ .name = "stdout-path" },
        );
        break :blk (try property_iter.next()) orelse return null;
    };

    const stdout_path = stdout_path_property.value.toString();

    const node = (dt.nodeFromPath(stdout_path) catch |err| switch (err) {
        error.BadOffset, error.Truncated => |e| return e,
        error.BadPath => {
            log.warn("the chosen nodes stdout-path property is not a valid path", .{});
            return null;
        },
    }) orelse return null;

    var compatible_iter = try node.node.compatibleIterator(dt);

    while (try compatible_iter.next()) |compatible| {
        if (compatible_lookup.get(compatible)) |getSerialOutputFn| {
            return try getSerialOutputFn(dt, node.node, memory_system_available);
        }
    }

    return null;
}

fn getSerialOutputFromNS16550a(dt: DeviceTree, node: DeviceTree.Node, memory_system_available: bool) GetSerialOutputError!?uart.Uart {
    if (!memory_system_available) return null;

    const clock_frequency = blk: {
        var property_iter = try node.propertyIterator(
            dt,
            .{ .name = "clock-frequency" },
        );

        const clock_frequency_property = if (try property_iter.next()) |prop| prop else {
            log.warn("no clock-frequency property found for ns16550a", .{});
            return null;
        };

        break :blk clock_frequency_property.value.toU32();
    };
    const address = blk: {
        var property_iter = try node.propertyIterator(
            dt,
            .{ .name = "reg" },
        );

        const reg_property = if (try property_iter.next()) |prop| prop else {
            log.warn("no reg property found for ns16550a", .{});
            return null;
        };

        // FIXME: rather than assume address-cells and size-cells are both two, we should actually look at the parent
        var reg_iter = try reg_property.value.regIterator(2, 2);

        const reg = reg_iter.next() orelse {
            log.warn("no reg property found for ns16550a", .{});
            return null;
        };
        break :blk reg.address;
    };

    const register_range = try kernel.mem.heap.allocateSpecial(
        uart.Memory16550.register_region_size,
        .fromAddr(
            .fromInt(address),
            uart.Memory16550.register_region_size,
        ),
        .{
            .type = .kernel,
            .protection = .read_write,
            .cache = .uncached,
        },
    );
    errdefer kernel.mem.heap.deallocateSpecial(register_range);

    if (try uart.Memory16550.create(
        register_range.address.toPtr([*]volatile u8),
        .{
            .clock_frequency = @enumFromInt(clock_frequency),
            .baud_rate = .@"115200",
        },
    )) |device| {
        return .{ .memory_16550 = device };
    }

    // TODO: duplicating this is annoying, but there is no `nulldefer`
    kernel.mem.heap.deallocateSpecial(register_range);

    return null;
}

fn getSerialOutputFromPL011(dt: DeviceTree, node: DeviceTree.Node, memory_system_available: bool) GetSerialOutputError!?uart.Uart {
    if (!memory_system_available) return null;

    const clock_frequency = clock_frequency: {
        var property_iter = try node.propertyIterator(
            dt,
            .{ .name = "clocks" },
        );

        const clocks_property = if (try property_iter.next()) |prop| prop else {
            log.warn("no clocks property found for pl011", .{});
            return null;
        };

        // there are multiple clocks, but the first one happens to be the one we want
        var clocks_iter = try clocks_property.value.pHandleListIterator();
        const clock_phandle = clocks_iter.next() orelse {
            log.warn("no clocks phandle found for pl011", .{});
            return null;
        };

        const clock_node = (try clock_phandle.node(dt)) orelse {
            log.warn("no clock node found for pl011", .{});
            return null;
        };

        property_iter = try clock_node.node.propertyIterator(
            dt,
            .{ .name = "clock-frequency" },
        );

        const clock_frequency_property = if (try property_iter.next()) |prop| prop else {
            log.warn("no clock-frequency property found for pl011", .{});
            return null;
        };

        break :clock_frequency clock_frequency_property.value.toU32();
    };
    const address = blk: {
        var property_iter = try node.propertyIterator(
            dt,
            .{ .name = "reg" },
        );

        const reg_property = if (try property_iter.next()) |prop| prop else {
            log.warn("no reg property found for pl011", .{});
            return null;
        };

        // FIXME: rather than assume address-cells and size-cells are both two, we should actually look at the parent
        var reg_iter = try reg_property.value.regIterator(2, 2);

        const reg = reg_iter.next() orelse {
            log.warn("no reg property found for pl011", .{});
            return null;
        };
        break :blk reg.address;
    };

    const register_range = try kernel.mem.heap.allocateSpecial(
        uart.PL011.register_region_size,
        .fromAddr(
            .fromInt(address),
            uart.PL011.register_region_size,
        ),
        .{
            .type = .kernel,
            .protection = .read_write,
            .cache = .uncached,
        },
    );
    errdefer kernel.mem.heap.deallocateSpecial(register_range);

    if (try uart.PL011.create(
        register_range.address.toPtr([*]volatile u32),
        .{
            .clock_frequency = @enumFromInt(clock_frequency),
            .baud_rate = .@"115200",
        },
    )) |device| {
        return .{ .pl011 = device };
    }

    // TODO: duplicating this is annoying, but there is no `nulldefer`
    kernel.mem.heap.deallocateSpecial(register_range);

    return null;
}

fn matchFunction(_: void, compatible: [:0]const u8) bool {
    return compatible_lookup.get(compatible) != null;
}

const compatible_lookup = std.StaticStringMap(GetSerialOutputFn).initComptime(.{
    .{ "ns16550a", getSerialOutputFromNS16550a },
    .{ "arm,pl011", getSerialOutputFromPL011 },
});

const GetSerialOutputError = DeviceTree.IteratorError ||
    DeviceTree.Property.Value.ListIteratorError ||
    uart.Baud.DivisorError ||
    kernel.mem.heap.AllocateError;
const GetSerialOutputFn = *const fn (dt: DeviceTree, node: DeviceTree.Node, memory_system_available: bool) GetSerialOutputError!?uart.Uart;
