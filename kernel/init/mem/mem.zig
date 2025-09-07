// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const boot = @import("boot");
const cascade = @import("cascade");
const Page = cascade.mem.Page;
const core = @import("core");

pub const phys = @import("phys.zig");

const log = cascade.debug.log.scoped(.mem_init);

/// Determine the kernels various offsets and the direct map early in the boot process.
pub fn determineEarlyMemoryLayout() void {
    const base_address = boot.kernelBaseAddress() orelse @panic("no kernel base address");
    cascade.mem.globals.virtual_base_address = base_address.virtual;

    const virtual_offset = core.Size.from(
        base_address.virtual.value - cascade.config.kernel_base_address.value,
        .byte,
    );
    cascade.mem.globals.virtual_offset = virtual_offset;

    cascade.mem.globals.physical_to_virtual_offset = core.Size.from(
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

    cascade.mem.globals.direct_map = core.VirtualRange.fromAddr(
        boot.directMapAddress() orelse @panic("direct map address not provided"),
        direct_map_size,
    );
}

pub fn logEarlyMemoryLayout(context: *cascade.Context) void {
    if (!log.levelEnabled(.debug)) return;

    log.debug(context, "kernel memory offsets:", .{});

    log.debug(context, "  virtual base address:       {f}", .{cascade.mem.globals.virtual_base_address});
    log.debug(context, "  virtual offset:             0x{x:0>16}", .{cascade.mem.globals.virtual_offset.value});
    log.debug(context, "  physical to virtual offset: 0x{x:0>16}", .{cascade.mem.globals.physical_to_virtual_offset.value});
    log.debug(context, "  direct map:                 {f}", .{cascade.mem.globals.direct_map});
}

pub fn initializeMemorySystem(context: *cascade.Context) !void {
    var memory_map: MemoryMap = .{};

    const number_of_usable_pages, const number_of_usable_regions = try fillMemoryMap(
        context,
        &memory_map,
    );

    const kernel_regions = &cascade.mem.globals.regions;

    log.debug(context, "building kernel memory layout", .{});
    buildMemoryLayout(
        context,
        number_of_usable_pages,
        number_of_usable_regions,
        kernel_regions,
    );
    cascade.mem.globals.non_cached_direct_map = kernel_regions.find(.non_cached_direct_map).?.range;

    log.debug(context, "building core page table", .{});
    cascade.mem.globals.core_page_table = buildAndLoadCorePageTable(
        context,
        kernel_regions,
    );

    log.debug(context, "initializing physical memory", .{});
    phys.initializePhysicalMemory(
        context,
        number_of_usable_pages,
        number_of_usable_regions,
        kernel_regions.find(.pages).?.range,
        memory_map.constSlice(),
    );

    log.debug(context, "initializing caches", .{});
    try initializeCaches(context);

    log.debug(context, "initializing kernel and special heap", .{});
    try initializeHeaps(context, kernel_regions);

    log.debug(context, "initializing tasks", .{});
    try cascade.Task.init.initializeTasks(context, kernel_regions);

    log.debug(context, "initializing processes", .{});
    try cascade.Process.init.initializeProcesses(context);

    log.debug(context, "initializing pageable kernel address space", .{});
    try cascade.mem.globals.kernel_pageable_address_space.init(
        context,
        .{
            .name = try .fromSlice("pageable_kernel"),
            .range = kernel_regions.find(.pageable_kernel_address_space).?.range,
            .page_table = cascade.mem.globals.core_page_table,
            .environment = .kernel,
        },
    );
}

const MemoryMap = core.containers.BoundedArray(
    boot.MemoryMap.Entry,
    cascade.config.maximum_number_of_memory_map_entries,
);

fn fillMemoryMap(context: *cascade.Context, memory_map: *MemoryMap) !struct { usize, usize } {
    var memory_iter = boot.memoryMap(.forward) catch @panic("no memory map");

    var number_of_usable_pages: usize = 0;
    var number_of_usable_regions: usize = 0;

    log.debug(context, "bootloader provided memory map:", .{});

    while (memory_iter.next()) |entry| {
        log.debug(context, "\t{f}", .{entry});

        try memory_map.append(entry);

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

    log.debug(context, "usable pages in memory map: {d}", .{number_of_usable_pages});
    log.debug(context, "usable regions in memory map: {d}", .{number_of_usable_regions});

    return .{ number_of_usable_pages, number_of_usable_regions };
}

fn buildMemoryLayout(
    context: *cascade.Context,
    number_of_usable_pages: usize,
    number_of_usable_regions: usize,
    kernel_regions: *cascade.mem.KernelMemoryRegion.List,
) void {
    registerKernelSections(kernel_regions);
    registerDirectMaps(kernel_regions);
    registerHeaps(kernel_regions);
    registerPages(kernel_regions, number_of_usable_pages, number_of_usable_regions);

    kernel_regions.sort();

    if (log.levelEnabled(.debug)) {
        log.debug(context, "kernel memory layout:", .{});

        for (kernel_regions.constSlice()) |region| {
            log.debug(context, "\t{f}", .{region});
        }
    }
}

fn registerKernelSections(kernel_regions: *cascade.mem.KernelMemoryRegion.List) void {
    const linker_symbols = struct {
        extern const __text_start: u8;
        extern const __text_end: u8;
        extern const __rodata_start: u8;
        extern const __rodata_end: u8;
        extern const __data_start: u8;
        extern const __data_end: u8;
    };

    const sdf_slice = cascade.debug.sdfSlice() catch &.{};
    const sdf_range = core.VirtualRange.fromSlice(u8, sdf_slice);

    const sections: []const struct {
        core.VirtualAddress,
        core.VirtualAddress,
        cascade.mem.KernelMemoryRegion.Type,
    } = &.{
        .{
            core.VirtualAddress.fromPtr(&linker_symbols.__text_start),
            core.VirtualAddress.fromPtr(&linker_symbols.__text_end),
            .executable_section,
        },
        .{
            core.VirtualAddress.fromPtr(&linker_symbols.__rodata_start),
            core.VirtualAddress.fromPtr(&linker_symbols.__rodata_end),
            .readonly_section,
        },
        .{
            core.VirtualAddress.fromPtr(&linker_symbols.__data_start),
            core.VirtualAddress.fromPtr(&linker_symbols.__data_end),
            .writeable_section,
        },
        .{
            sdf_range.address,
            sdf_range.endBound(),
            .sdf_section,
        },
    };

    for (sections) |section| {
        const start_address = section[0];
        const end_address = section[1];
        const region_type = section[2];

        std.debug.assert(end_address.greaterThan(start_address));

        const virtual_range: core.VirtualRange = .fromAddr(
            start_address,
            core.Size.from(end_address.value - start_address.value, .byte)
                .alignForward(arch.paging.standard_page_size),
        );

        kernel_regions.append(.{
            .range = virtual_range,
            .type = region_type,
        });
    }
}

fn registerDirectMaps(kernel_regions: *cascade.mem.KernelMemoryRegion.List) void {
    const direct_map = cascade.mem.globals.direct_map;

    // does the direct map range overlap a pre-existing region?
    for (kernel_regions.constSlice()) |region| {
        if (region.range.fullyContainsRange(direct_map)) {
            std.debug.panic("direct map overlaps region: {f}", .{region});
            return error.DirectMapOverlapsRegion;
        }
    }

    kernel_regions.append(.{
        .range = direct_map,
        .type = .direct_map,
    });

    const non_cached_direct_map = kernel_regions.findFreeRange(
        direct_map.size,
        arch.paging.largest_page_size,
    ) orelse @panic("no free range for non-cached direct map");

    kernel_regions.append(.{
        .range = non_cached_direct_map,
        .type = .non_cached_direct_map,
    });
}

fn registerHeaps(kernel_regions: *cascade.mem.KernelMemoryRegion.List) void {
    const size_of_top_level = arch.paging.init.sizeOfTopLevelEntry();

    const kernel_heap_range = kernel_regions.findFreeRange(
        size_of_top_level,
        size_of_top_level,
    ) orelse
        @panic("no space in kernel memory layout for the kernel heap");

    kernel_regions.append(.{
        .range = kernel_heap_range,
        .type = .kernel_heap,
    });

    const special_heap_range = kernel_regions.findFreeRange(
        size_of_top_level,
        size_of_top_level,
    ) orelse
        @panic("no space in kernel memory layout for the special heap");

    kernel_regions.append(.{
        .range = special_heap_range,
        .type = .special_heap,
    });

    const kernel_stacks_range = kernel_regions.findFreeRange(
        size_of_top_level,
        size_of_top_level,
    ) orelse
        @panic("no space in kernel memory layout for the kernel stacks");

    kernel_regions.append(.{
        .range = kernel_stacks_range,
        .type = .kernel_stacks,
    });

    const pageable_kernel_address_space_range = kernel_regions.findFreeRange(
        size_of_top_level,
        size_of_top_level,
    ) orelse
        @panic("no space in kernel memory layout for the pageable kernel address space");

    kernel_regions.append(.{
        .range = pageable_kernel_address_space_range,
        .type = .pageable_kernel_address_space,
    });
}

fn registerPages(
    kernel_regions: *cascade.mem.KernelMemoryRegion.List,
    number_of_usable_pages: usize,
    number_of_usable_regions: usize,
) void {
    std.debug.assert(@alignOf(Page.Region) <= arch.paging.standard_page_size.value);

    const size_of_regions = core.Size.of(Page.Region)
        .multiplyScalar(number_of_usable_regions);

    const size_of_pages = core.Size.of(Page)
        .multiplyScalar(number_of_usable_pages);

    const range_size =
        size_of_regions
            .alignForward(.from(@alignOf(Page), .byte))
            .add(size_of_pages)
            .alignForward(arch.paging.standard_page_size);

    const pages_range = kernel_regions.findFreeRange(
        range_size,
        arch.paging.standard_page_size,
    ) orelse @panic("no space in kernel memory layout for the pages array");

    kernel_regions.append(.{
        .range = pages_range,
        .type = .pages,
    });
}

fn buildAndLoadCorePageTable(
    context: *cascade.Context,
    kernel_regions: *cascade.mem.KernelMemoryRegion.List,
) arch.paging.PageTable {
    const core_page_table = arch.paging.PageTable.create(
        phys.bootstrap_allocator.allocate(context) catch unreachable,
    );

    for (kernel_regions.constSlice()) |region| {
        log.debug(context, "mapping '{t}' into the core page table", .{region.type});

        const map_info = region.mapInfo();

        switch (map_info) {
            .top_level => arch.paging.init.fillTopLevel(
                context,
                core_page_table,
                region.range,
                phys.bootstrap_allocator,
            ) catch |err| {
                std.debug.panic("failed to fill top level for {f}: {t}", .{ region, err });
            },
            .full => |full| arch.paging.init.mapToPhysicalRangeAllPageSizes(
                context,
                core_page_table,
                region.range,
                full.physical_range,
                full.map_type,
                phys.bootstrap_allocator,
            ) catch |err| {
                std.debug.panic("failed to full map {f}: {t}", .{ region, err });
            },
            .back_with_frames => |map_type| {
                cascade.mem.mapRangeAndBackWithPhysicalFrames(
                    context,
                    core_page_table,
                    region.range,
                    map_type,
                    .kernel,
                    .keep,
                    phys.bootstrap_allocator,
                ) catch |err| {
                    std.debug.panic("failed to back with frames {f}: {t}", .{ region, err });
                };
            },
        }
    }

    log.debug(context, "loading core page table", .{});
    core_page_table.load();

    return core_page_table;
}

/// Initializes the caches used by the memory subsystem.
fn initializeCaches(context: *cascade.Context) !void {
    cascade.mem.resource_arena.globals.tag_cache.init(context, .{
        .name = try .fromSlice("boundary tag"),
        .slab_source = .pmm,
    });

    cascade.mem.cache.globals.slab_cache.init(context, .{
        .name = try .fromSlice("slab"),
        .slab_source = .pmm,
    });

    cascade.mem.cache.globals.large_object_cache.init(context, .{
        .name = try .fromSlice("large object"),
        .slab_source = .pmm,
    });

    cascade.mem.AddressSpace.AnonymousMap.globals.anonymous_map_cache.init(context, .{
        .name = try .fromSlice("anonymous map"),
    });

    cascade.mem.AddressSpace.AnonymousPage.globals.anonymous_page_cache.init(context, .{
        .name = try .fromSlice("anonymous page"),
    });

    cascade.mem.AddressSpace.Entry.globals.entry_cache.init(context, .{
        .name = try .fromSlice("address space entry"),
    });
}

fn initializeHeaps(
    context: *cascade.Context,
    kernel_regions: *const cascade.mem.KernelMemoryRegion.List,
) !void {
    // heap
    {
        try cascade.mem.heap.globals.heap_address_space_arena.init(
            context,
            .{
                .name = try .fromSlice("heap_address_space"),
                .quantum = arch.paging.standard_page_size.value,
            },
        );

        try cascade.mem.heap.globals.heap_page_arena.init(
            context,
            .{
                .name = try .fromSlice("heap_page"),
                .quantum = arch.paging.standard_page_size.value,
                .source = cascade.mem.heap.globals.heap_address_space_arena.createSource(.{
                    .custom_import = cascade.mem.heap.allocator_impl.heapPageArenaImport,
                    .custom_release = cascade.mem.heap.allocator_impl.heapPageArenaRelease,
                }),
            },
        );

        try cascade.mem.heap.globals.heap_arena.init(
            context,
            .{
                .name = try .fromSlice("heap"),
                .quantum = cascade.mem.heap.allocator_impl.heap_arena_quantum,
                .source = cascade.mem.heap.globals.heap_page_arena.createSource(.{}),
            },
        );

        const heap_range = kernel_regions.find(.kernel_heap).?.range;

        cascade.mem.heap.globals.heap_address_space_arena.addSpan(
            context,
            heap_range.address.value,
            heap_range.size.value,
        ) catch |err| {
            std.debug.panic("failed to add heap range to `heap_address_space_arena`: {t}", .{err});
        };
    }

    // special heap
    {
        try cascade.mem.heap.globals.special_heap_address_space_arena.init(
            context,
            .{
                .name = try .fromSlice("special_heap_address_space"),
                .quantum = arch.paging.standard_page_size.value,
            },
        );

        const special_heap_range = kernel_regions.find(.special_heap).?.range;

        cascade.mem.heap.globals.special_heap_address_space_arena.addSpan(
            context,
            special_heap_range.address.value,
            special_heap_range.size.value,
        ) catch |err| {
            std.debug.panic(
                "failed to add special heap range to `special_heap_address_space_arena`: {t}",
                .{err},
            );
        };
    }
}
