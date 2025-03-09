// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>

// FIXME: we assume #address-cells and #size-cells are both two

pub const DeviceTree = @import("DeviceTree");

pub fn getDeviceTree() ?DeviceTree {
    const address = kernel.boot.deviceTreeBlob() orelse return null;
    const ptr = address.toPtr([*]align(8) const u8);
    return DeviceTree.fromPtr(ptr) catch |err| {
        log.warn("failed to parse device tree blob: {s}", .{@errorName(err)});
        return null;
    };
}

pub fn tryGetSerialOutput() ?uart.Uart {
    const output_uart = tryGetSerialOutputInner() catch |err| switch (err) {
        error.BadOffset => {
            log.warn("attempted to use a bad offset into the device tree", .{});
            return null;
        },
        error.Truncated => {
            log.warn("the device tree blob is truncated", .{});
            return null;
        },
        error.DivisorTooLarge => {
            log.warn("baud divisor too large", .{});
            return null;
        },
        error.SizeNotMultiple => {
            log.warn("the regs property size is not a multiple of the address-cells + size-cells", .{});
            return null;
        },
    } orelse return null;

    return output_uart;
}

fn tryGetSerialOutputInner() GetSerialOutputError!?uart.Uart {
    const dt = getDeviceTree() orelse return null;

    if (try getSerialOutputFromChosenNode(dt)) |output_uart| return output_uart;

    var iter = dt.compatibleMatchIterator({}, matchFunction);

    while (try iter.next(dt)) |compatible_match| {
        const func = compatible_lookup.get(compatible_match.compatible).?;
        if (try func(dt, compatible_match.node.node)) |output_uart| return output_uart;
    }

    return null;
}

fn getSerialOutputFromChosenNode(dt: DeviceTree) GetSerialOutputError!?uart.Uart {
    const chosen_node = (try DeviceTree.Node.root.firstMatchingSubnode(
        dt,
        .direct_children,
        .{ .name = "chosen" },
    )) orelse return null;

    const stdout_path_property = (try chosen_node.node.firstMatchingProperty(
        dt,
        .{ .name = "stdout-path" },
    )) orelse return null;

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
            return try getSerialOutputFn(dt, node.node);
        }
    }

    return null;
}

fn getSerialOutputFromNS16550a(dt: DeviceTree, node: DeviceTree.Node) GetSerialOutputError!?uart.Uart {
    const clock_frequency = blk: {
        const clock_frequency_property = (try node.firstMatchingProperty(
            dt,
            .{ .name = "clock-frequency" },
        )) orelse {
            log.warn("no clock-frequency property found for ns16550a", .{});
            return null;
        };
        break :blk clock_frequency_property.value.toU32();
    };
    const address = blk: {
        const reg_property = (try node.firstMatchingProperty(
            dt,
            .{ .name = "reg" },
        )) orelse {
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

    return .{
        .memory_16550 = (try uart.Memory16550.init(
            kernel.vmm.directMapFromPhysical(
                .fromInt(address),
            ).toPtr([*]volatile u8),
            .{
                .clock_frequency = @enumFromInt(clock_frequency),
                .baud_rate = .@"115200",
            },
        )) orelse return null,
    };
}

fn getSerialOutputFromPL011(dt: DeviceTree, node: DeviceTree.Node) GetSerialOutputError!?uart.Uart {
    const clock_frequency = clock_frequency: {
        const clocks_property = (try node.firstMatchingProperty(
            dt,
            .{ .name = "clocks" },
        )) orelse {
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

        const clock_frequency_property = (try clock_node.node.firstMatchingProperty(
            dt,
            .{ .name = "clock-frequency" },
        )) orelse {
            log.warn("no clock-frequency property found for pl011", .{});
            return null;
        };

        break :clock_frequency clock_frequency_property.value.toU32();
    };
    const address = blk: {
        const reg_property = (try node.firstMatchingProperty(
            dt,
            .{ .name = "reg" },
        )) orelse {
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

    return .{
        .pl011 = (try uart.PL011.init(
            kernel.vmm.directMapFromPhysical(
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
const GetSerialOutputFn = *const fn (dt: DeviceTree, node: DeviceTree.Node) GetSerialOutputError!?uart.Uart;

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const uart = kernel.init.Output.uart;
const log = kernel.debug.log.scoped(.devicetree);
