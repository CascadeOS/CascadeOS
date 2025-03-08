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
    } orelse return null;

    return output_uart;
}

fn tryGetSerialOutputInner() GetSerialOutputError!?uart.Uart {
    const dt = getDeviceTree() orelse return null;

    if (try getSerialOutputFromChosenNode(dt)) |output_uart| return output_uart;

    // TODO: doing a iteration per supported UART is not ideal
    for (compatible_lookup.keys()) |key| {
        if (try dt.findNodeWithCompatible(key)) |node_with_name| {
            const func = compatible_lookup.get(key).?;
            if (try func(dt, node_with_name.node)) |output_uart| return output_uart;
        }
    }

    return null;
}

fn getSerialOutputFromChosenNode(dt: DeviceTree) GetSerialOutputError!?uart.Uart {
    const chosen_node = blk: {
        var iter = try DeviceTree.Node.root.iterateSubnodes(
            dt,
            .direct_children,
            .{ .name = "chosen" },
        );
        break :blk (try iter.next()) orelse return null;
    };

    const stdout_path_property = blk: {
        var iter = try chosen_node.node.propertyIterator(dt, .{ .name = "stdout-path" });
        break :blk (try iter.next()) orelse return null;
    };

    const stdout_path = stdout_path_property.value.toString();

    const node = (dt.nodeFromPath(stdout_path) catch |err| switch (err) {
        error.BadOffset, error.Truncated => |e| return e,
        error.NonExistentAlias => {
            log.warn("the chosen nodes stdout-path property refers to a non-existent alias", .{});
            return null;
        },
        error.BadPath => {
            log.warn("the chosen nodes stdout-path property is not a valid path", .{});
            return null;
        },
    }) orelse return null;

    const compatible_property = blk: {
        var iter = try node.node.propertyIterator(dt, .{ .name = "compatible" });
        break :blk (try iter.next()) orelse return null;
    };

    var compatible_list = compatible_property.value.stringListIterator();
    while (try compatible_list.next()) |compatible| {
        if (compatible_lookup.get(compatible)) |getSerialOutputFn| {
            return getSerialOutputFn(dt, node.node);
        }
    }

    return null;
}

fn getSerialOutputFromNS16550a(dt: DeviceTree, node: DeviceTree.Node) GetSerialOutputError!?uart.Uart {
    const clock_frequency = blk: {
        var iter = try node.propertyIterator(dt, .{ .name = "clock-frequency" });
        const clock_frequency_property = (try iter.next()) orelse {
            log.warn("no clock-frequency property found for ns16550a", .{});
            return null;
        };
        break :blk clock_frequency_property.value.toU32();
    };
    const address = blk: {
        var iter = try node.propertyIterator(dt, .{ .name = "reg" });
        const reg_property = (try iter.next()) orelse {
            log.warn("no reg property found for ns16550a", .{});
            return null;
        };
        // FIXME: remove this once zig-devicetree has support for integer property iteration
        const ptr: *align(1) const u64 = @ptrCast(reg_property.value._raw);
        break :blk std.mem.bigToNative(u64, ptr.*);
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
    const address = blk: {
        var iter = try node.propertyIterator(dt, .{ .name = "reg" });
        const reg_property = (try iter.next()) orelse {
            log.warn("no reg property found for pl011", .{});
            return null;
        };
        // FIXME: remove this once zig-devicetree has support for integer property iteration
        const ptr: *align(1) const u64 = @ptrCast(reg_property.value._raw);
        break :blk std.mem.bigToNative(u64, ptr.*);
    };
    const clock_frequency = clock_frequency: {
        const clocks_property = blk: {
            var iter = try node.propertyIterator(dt, .{ .name = "clocks" });
            break :blk (try iter.next()) orelse {
                log.warn("no clocks property found for pl011", .{});
                return null;
            };
        };
        // there are multiple clocks, but the first one happens to be the one we want
        const clock_phandle = clocks_property.value.toPHandle();
        const clock_node = (try clock_phandle.node(dt)) orelse {
            log.warn("no clock node found for pl011", .{});
            return null;
        };

        var iter = try clock_node.node.propertyIterator(dt, .{ .name = "clock-frequency" });
        const clock_frequency_property = (try iter.next()) orelse {
            log.warn("no clock-frequency property found for ns16550a", .{});
            return null;
        };
        break :clock_frequency clock_frequency_property.value.toU32();
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

const compatible_lookup = std.StaticStringMap(GetSerialOutputFn).initComptime(.{
    .{ "ns16550a", getSerialOutputFromNS16550a },
    .{ "arm,pl011", getSerialOutputFromPL011 },
});

const GetSerialOutputError = DeviceTree.IteratorError || uart.Baud.DivisorError;
const GetSerialOutputFn = *const fn (dt: DeviceTree, node: DeviceTree.Node) GetSerialOutputError!?uart.Uart;

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const uart = kernel.init.Output.uart;
const log = kernel.debug.log.scoped(.devicetree);
