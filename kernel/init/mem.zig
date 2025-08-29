// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

/// Determine the kernels various offsets and the direct map early in the boot process.
pub fn determineEarlyMemoryLayout() cascade.mem.initialization.EarlyMemoryLayout {
    const base_address = boot.kernelBaseAddress() orelse @panic("no kernel base address");

    const virtual_offset = core.Size.from(
        base_address.virtual.value - cascade.config.kernel_base_address.value,
        .byte,
    );

    const physical_to_virtual_offset = core.Size.from(
        base_address.virtual.value - base_address.physical.value,
        .byte,
    );

    const direct_map_size = direct_map_size: {
        const last_memory_map_entry = last_memory_map_entry: {
            var memory_map_iterator = boot.memoryMap(.backward) catch @panic("no memory map");
            break :last_memory_map_entry memory_map_iterator.next() orelse @panic("no memory map entries");
        };

        var direct_map_size = core.Size.from(last_memory_map_entry.range.last().value, .byte);

        // We ensure that the lowest 4GiB are always mapped.
        const four_gib = core.Size.from(4, .gib);
        if (direct_map_size.lessThan(four_gib)) direct_map_size = four_gib;

        // We align the length of the direct map to `largest_page_size` to allow large pages to be used for the mapping.
        direct_map_size.alignForwardInPlace(arch.paging.largest_page_size);

        break :direct_map_size direct_map_size;
    };

    const direct_map = core.VirtualRange.fromAddr(
        boot.directMapAddress() orelse @panic("direct map address not provided"),
        direct_map_size,
    );

    const early_memory_layout: cascade.mem.initialization.EarlyMemoryLayout = .{
        .virtual_base_address = base_address.virtual,
        .virtual_offset = virtual_offset,
        .physical_to_virtual_offset = physical_to_virtual_offset,
        .direct_map = direct_map,
    };

    cascade.mem.initialization.setEarlyMemoryLayout(early_memory_layout);

    return early_memory_layout;
}

pub fn logEarlyMemoryLayout(context: *cascade.Context, early_memory_layout: cascade.mem.initialization.EarlyMemoryLayout) void {
    if (!log.levelEnabled(.debug)) return;

    log.debug(context, "kernel memory offsets:", .{});

    log.debug(context, "  virtual base address:       {f}", .{early_memory_layout.virtual_base_address});
    log.debug(context, "  virtual offset:             0x{x:0>16}", .{early_memory_layout.virtual_offset.value});
    log.debug(context, "  physical to virtual offset: 0x{x:0>16}", .{early_memory_layout.physical_to_virtual_offset.value});
    log.debug(context, "  direct map:                 {f}", .{early_memory_layout.direct_map});
}

const arch = @import("arch");
const boot = @import("boot");
const cascade = @import("cascade");

const core = @import("core");
const log = cascade.debug.log.scoped(.init_mem);
const std = @import("std");
