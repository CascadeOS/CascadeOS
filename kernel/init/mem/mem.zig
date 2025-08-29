// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub const bootstrap_allocator: phys.FrameAllocator = .{
    .allocate = struct {
        fn allocate(context: *cascade.Context) !phys.Frame {
            const non_empty_region: *Region =
                region: for (globals.regions.slice()) |*region| {
                    if (region.first_free_frame_index < region.frame_count) break :region region;
                } else {
                    for (globals.regions.constSlice()) |region| {
                        log.warn(context, "  region: {}", .{region});
                    }

                    @panic("no empty region in bootstrap physical frame allocator");
                };

            const first_free_frame_index = non_empty_region.first_free_frame_index;
            non_empty_region.first_free_frame_index = first_free_frame_index + 1;

            return @enumFromInt(@intFromEnum(non_empty_region.start_physical_frame) + first_free_frame_index);
        }
    }.allocate,
    .deallocate = struct {
        fn deallocate(_: *cascade.Context, _: phys.FrameList) void {
            @panic("deallocate not supported");
        }
    }.deallocate,
};

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

/// Initialize the bootstrap physical frame allocator that is used for allocating physical frames before the full memory
/// system is initialized.
pub fn initializeBootstrapFrameAllocator(_: *cascade.Context) void {
    var memory_map = boot.memoryMap(.forward) catch @panic("no memory map");
    while (memory_map.next()) |entry| {
        if (entry.type != .free) continue;

        globals.regions.append(.{
            .start_physical_frame = .fromAddress(entry.range.address),
            .first_free_frame_index = 0,
            .frame_count = @intCast(std.math.divExact(
                usize,
                entry.range.size.value,
                arch.paging.standard_page_size.value,
            ) catch std.debug.panic(
                "memory map entry size is not a multiple of page size: {f}",
                .{entry},
            )),
        }) catch @panic("exceeded max number of regions");
    }
}

pub fn initializeMemorySystem(context: *cascade.Context) !void {
    const static = struct {
        var memory_map: core.containers.BoundedArray(
            boot.MemoryMap.Entry,
            cascade.config.maximum_number_of_memory_map_entries,
        ) = .{};
    };

    if (log.levelEnabled(.debug)) {
        var memory_map = boot.memoryMap(.forward) catch @panic("no memory map");

        log.debug(context, "bootloader provided memory map:", .{});
        while (memory_map.next()) |entry| {
            log.debug(context, "\t{f}", .{entry});
        }
    }

    var memory_iter = boot.memoryMap(.forward) catch @panic("no memory map");

    var number_of_usable_pages: usize = 0;
    var number_of_usable_regions: usize = 0;

    while (memory_iter.next()) |entry| {
        try static.memory_map.append(entry);

        if (!entry.type.isUsable()) continue;
        if (entry.range.size.value == 0) continue;

        number_of_usable_regions += 1;

        number_of_usable_pages += std.math.divExact(
            usize,
            entry.range.size.value,
            arch.paging.standard_page_size.value,
        ) catch std.debug.panic(
            "memory map entry size is not a multiple of page size: {f}",
            .{entry},
        );
    }

    try cascade.mem.initialization.initializeMemorySystem(context, .{
        .number_of_usable_pages = number_of_usable_pages,
        .number_of_usable_regions = number_of_usable_regions,
        .memory_map = static.memory_map.constSlice(),
        .regions = &globals.regions,
    });
}

pub const Region = struct {
    /// The first frame of the region.
    start_physical_frame: phys.Frame,

    /// Index of the first free frame in this region.
    first_free_frame_index: u32,

    /// Total number of frames in the region.
    frame_count: u32,

    pub const List = core.containers.BoundedArray(Region, max_regions);
    const max_regions: usize = 64;
};

const globals = struct {
    var regions: Region.List = .{};
};

const arch = @import("arch");
const boot = @import("boot");
const cascade = @import("cascade");
const phys = cascade.mem.phys;

const core = @import("core");
const log = cascade.debug.log.scoped(.init_mem);
const std = @import("std");
