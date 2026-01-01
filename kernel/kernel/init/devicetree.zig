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

pub fn tryGetSerialOutput(current_task: Task.Current) ?uart.Uart {
    const output_uart = tryGetSerialOutputInner(current_task) catch |err| switch (err) {
        error.BadOffset => {
            log.warn(current_task, "attempted to use a bad offset into the device tree", .{});
            return null;
        },
        error.Truncated => {
            log.warn(current_task, "the device tree blob is truncated", .{});
            return null;
        },
        error.DivisorTooLarge => {
            log.warn(current_task, "baud divisor too large", .{});
            return null;
        },
        error.SizeNotMultiple => {
            log.warn(current_task, "the regs property size is not a multiple of the address-cells + size-cells", .{});
            return null;
        },
    } orelse return null;

    return output_uart;
}

fn tryGetSerialOutputInner(current_task: Task.Current) GetSerialOutputError!?uart.Uart {
    const dt = getDeviceTree(current_task) orelse return null;

    if (try getSerialOutputFromChosenNode(current_task, dt)) |output_uart| return output_uart;

    var iter = try dt.nodeCompatibleMatchIteratorAdvanced(
        .root,
        .all_children,
        {},
        matchFunction,
    );

    while (try iter.next(dt)) |compatible_match| {
        const func = compatible_lookup.get(compatible_match.compatible).?;
        if (try func(current_task, dt, compatible_match.node.node)) |output_uart| return output_uart;
    }

    return null;
}

fn getDeviceTree(current_task: Task.Current) ?DeviceTree {
    const address = boot.deviceTreeBlob() orelse return null;
    const ptr = address.toPtr([*]align(8) const u8);
    return DeviceTree.fromPtr(ptr) catch |err| {
        log.warn(current_task, "failed to parse device tree blob: {t}", .{err});
        return null;
    };
}

fn getSerialOutputFromChosenNode(current_task: Task.Current, dt: DeviceTree) GetSerialOutputError!?uart.Uart {
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
            log.warn(current_task, "the chosen nodes stdout-path property is not a valid path", .{});
            return null;
        },
    }) orelse return null;

    var compatible_iter = try node.node.compatibleIterator(dt);

    while (try compatible_iter.next()) |compatible| {
        if (compatible_lookup.get(compatible)) |getSerialOutputFn| {
            return try getSerialOutputFn(current_task, dt, node.node);
        }
    }

    return null;
}

fn getSerialOutputFromNS16550a(current_task: Task.Current, dt: DeviceTree, node: DeviceTree.Node) GetSerialOutputError!?uart.Uart {
    const clock_frequency = blk: {
        var property_iter = try node.propertyIterator(
            dt,
            .{ .name = "clock-frequency" },
        );

        const clock_frequency_property = if (try property_iter.next()) |prop| prop else {
            log.warn(current_task, "no clock-frequency property found for ns16550a", .{});
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
            log.warn(current_task, "no reg property found for ns16550a", .{});
            return null;
        };

        // FIXME: rather than assume address-cells and size-cells are both two, we should actually look at the parent
        var reg_iter = try reg_property.value.regIterator(2, 2);

        const reg = reg_iter.next() orelse {
            log.warn(current_task, "no reg property found for ns16550a", .{});
            return null;
        };
        break :blk reg.address;
    };

    return .{
        .memory_16550 = (try uart.Memory16550.create(
            kernel.mem.directMapFromPhysical(
                .fromInt(address),
            ).toPtr([*]volatile u8),
            .{
                .clock_frequency = @enumFromInt(clock_frequency),
                .baud_rate = .@"115200",
            },
        )) orelse return null,
    };
}

fn getSerialOutputFromPL011(current_task: Task.Current, dt: DeviceTree, node: DeviceTree.Node) GetSerialOutputError!?uart.Uart {
    const clock_frequency = clock_frequency: {
        var property_iter = try node.propertyIterator(
            dt,
            .{ .name = "clocks" },
        );

        const clocks_property = if (try property_iter.next()) |prop| prop else {
            log.warn(current_task, "no clocks property found for pl011", .{});
            return null;
        };

        // there are multiple clocks, but the first one happens to be the one we want
        var clocks_iter = try clocks_property.value.pHandleListIterator();
        const clock_phandle = clocks_iter.next() orelse {
            log.warn(current_task, "no clocks phandle found for pl011", .{});
            return null;
        };

        const clock_node = (try clock_phandle.node(dt)) orelse {
            log.warn(current_task, "no clock node found for pl011", .{});
            return null;
        };

        property_iter = try clock_node.node.propertyIterator(
            dt,
            .{ .name = "clock-frequency" },
        );

        const clock_frequency_property = if (try property_iter.next()) |prop| prop else {
            log.warn(current_task, "no clock-frequency property found for pl011", .{});
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
            log.warn(current_task, "no reg property found for pl011", .{});
            return null;
        };

        // FIXME: rather than assume address-cells and size-cells are both two, we should actually look at the parent
        var reg_iter = try reg_property.value.regIterator(2, 2);

        const reg = reg_iter.next() orelse {
            log.warn(current_task, "no reg property found for pl011", .{});
            return null;
        };
        break :blk reg.address;
    };

    return .{
        .pl011 = (try uart.PL011.create(
            kernel.mem.directMapFromPhysical(
                .fromInt(address),
            ).toPtr([*]volatile u32),
            .{
                .clock_frequency = @enumFromInt(clock_frequency),
                .baud_rate = .@"115200",
            },
        )) orelse return null,
    };
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
    uart.Baud.DivisorError;
const GetSerialOutputFn = *const fn (
    current_task: Task.Current,
    dt: DeviceTree,
    node: DeviceTree.Node,
) GetSerialOutputError!?uart.Uart;
