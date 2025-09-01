// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub const bootstrap_allocator: cascade.mem.phys.FrameAllocator = .{
    .allocate = struct {
        fn allocate(context: *cascade.Context) !cascade.mem.phys.Frame {
            const non_empty_region: *FreePhysicalRegion =
                region: for (globals.free_physical_regions.slice()) |*region| {
                    if (region.first_free_frame_index < region.frame_count) break :region region;
                } else {
                    for (globals.free_physical_regions.constSlice()) |region| {
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
        fn deallocate(_: *cascade.Context, _: cascade.mem.phys.FrameList) void {
            @panic("deallocate not supported");
        }
    }.deallocate,
};

pub const FreePhysicalRegion = struct {
    /// The first frame of the region.
    start_physical_frame: cascade.mem.phys.Frame,

    /// Index of the first free frame in this region.
    first_free_frame_index: u32,

    /// Total number of frames in the region.
    frame_count: u32,

    pub const List = core.containers.BoundedArray(FreePhysicalRegion, max_regions);
    const max_regions: usize = 64;
};

pub const globals = struct {
    pub var free_physical_regions: FreePhysicalRegion.List = .{};
};

/// Initialize the bootstrap physical frame allocator that is used for allocating physical frames before the full memory
/// system is initialized.
pub fn initializeBootstrapFrameAllocator(_: *cascade.Context) void {
    var memory_map = boot.memoryMap(.forward) catch @panic("no memory map");
    while (memory_map.next()) |entry| {
        if (entry.type != .free) continue;

        globals.free_physical_regions.append(.{
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
        }) catch @panic("exceeded max number of physical regions");
    }
}

/// Initializes the normal physical frame allocator and the pages array.
///
/// Pulls all memory out of the bootstrap physical frame allocator and uses it to populate the normal allocator.
pub fn initializePhysicalMemory(
    context: *cascade.Context,
    number_of_usable_pages: usize,
    number_of_usable_regions: usize,
    pages_range: core.VirtualRange,
    memory_map: []const boot.MemoryMap.Entry,
) void {
    log.debug(
        context,
        "initializing pages array with {} usable pages ({f}) in {} regions",
        .{
            number_of_usable_pages,
            arch.paging.standard_page_size.multiplyScalar(number_of_usable_pages),
            number_of_usable_regions,
        },
    );

    const free_physical_regions = globals.free_physical_regions.constSlice();

    // ugly pointer stuff to setup the page and page region arrays
    const page_regions, const pages = blk: {
        var byte_ptr = pages_range.address.toPtr([*]u8);

        const page_regions_ptr: [*]Page.Region = @ptrCast(@alignCast(byte_ptr));
        const page_regions = page_regions_ptr[0..number_of_usable_regions];

        byte_ptr += @sizeOf(Page.Region) * number_of_usable_regions;
        byte_ptr = std.mem.alignPointer(byte_ptr, @alignOf(Page)).?;

        const page_ptr: [*]Page = @ptrCast(@alignCast(byte_ptr));
        const pages = page_ptr[0..number_of_usable_pages];

        break :blk .{ page_regions, pages };
    };

    var free_page_list: std.SinglyLinkedList = .{};

    var total_memory: core.Size = .zero;
    var free_memory: core.Size = .zero;
    var reserved_memory: core.Size = .zero;
    var reclaimable_memory: core.Size = .zero;
    var unavailable_memory: core.Size = .zero;

    var page_index: u32 = 0;
    var usable_range_index: u32 = 0;

    var free_region_index: usize = 0;

    for (memory_map) |entry| {
        total_memory.addInPlace(entry.range.size);

        switch (entry.type) {
            .free => {
                // free_memory incremented later after pulling it out of the bootstrap allocator
            },
            .in_use => {},
            .reserved => {
                reserved_memory.addInPlace(entry.range.size);
                continue; // these pages are never available for use
            },
            .bootloader_reclaimable, .acpi_reclaimable => reclaimable_memory.addInPlace(entry.range.size),
            .unusable, .unknown => {
                unavailable_memory.addInPlace(entry.range.size);
                continue; // these pages are never available for use
            },
        }

        std.debug.assert(entry.range.address.isAligned(arch.paging.standard_page_size));
        std.debug.assert(entry.range.size.isAligned(arch.paging.standard_page_size));

        var in_use_frames_left: u32 = if (entry.type == .free) blk: {
            // pull the free region out of the bootstrap allocator

            const free_bootstrap_region = free_physical_regions[free_region_index];

            free_region_index += 1;

            std.debug.assert(free_bootstrap_region.start_physical_frame.baseAddress().equal(entry.range.address));

            const in_use_frames = free_bootstrap_region.first_free_frame_index;

            const free_frames = free_bootstrap_region.frame_count - in_use_frames;
            free_memory.addInPlace(arch.paging.standard_page_size.multiplyScalar(free_frames));

            if (log.levelEnabled(.debug)) {
                if (in_use_frames == 0) {
                    log.debug(
                        context,
                        "pulled {} ({f}) free frames out of bootstrap frame allocator region",
                        .{
                            free_frames,
                            arch.paging.standard_page_size.multiplyScalar(free_frames),
                        },
                    );
                } else if (in_use_frames == free_bootstrap_region.frame_count) {
                    log.debug(
                        context,
                        "pulled {} ({f}) in use frames out of bootstrap frame allocator region",
                        .{
                            in_use_frames,
                            arch.paging.standard_page_size.multiplyScalar(in_use_frames),
                        },
                    );
                } else {
                    log.debug(
                        context,
                        "pulled {} ({f}) free frames and {} ({f}) in use frames out of bootstrap frame allocator region",
                        .{
                            free_frames,
                            arch.paging.standard_page_size.multiplyScalar(free_frames),
                            in_use_frames,
                            arch.paging.standard_page_size.multiplyScalar(in_use_frames),
                        },
                    );
                }
            }

            break :blk in_use_frames;
        } else @intCast(std.math.divExact(
            u64,
            entry.range.size.value,
            arch.paging.standard_page_size.value,
        ) catch std.debug.panic(
            "memory map entry size is not a multiple of page size: {f}",
            .{entry},
        ));

        const usable_pages_in_range: u32 = @intCast(std.math.divExact(
            usize,
            entry.range.size.value,
            arch.paging.standard_page_size.value,
        ) catch std.debug.panic(
            "memory map entry size is not a multiple of page size: {f}",
            .{entry},
        ));

        const start_frame: cascade.mem.phys.Frame = .fromAddress(entry.range.address);

        page_regions[usable_range_index] = .{
            .start_frame = start_frame,
            .number_of_frames = usable_pages_in_range,
            .start_index = page_index,
        };
        usable_range_index += 1;

        const range_start_phys_frame = @intFromEnum(start_frame);

        for (0..usable_pages_in_range) |range_i| {
            pages[page_index] = .{
                .physical_frame = @enumFromInt(range_start_phys_frame + range_i),
            };

            if (in_use_frames_left != 0) {
                in_use_frames_left -= 1;
            } else {
                free_page_list.prepend(&pages[page_index].node);
            }

            page_index += 1;
        }
    }
    std.debug.assert(page_index == number_of_usable_pages);
    std.debug.assert(usable_range_index == number_of_usable_regions);

    const used_memory = total_memory
        .subtract(free_memory)
        .subtract(reserved_memory)
        .subtract(reclaimable_memory)
        .subtract(unavailable_memory);

    log.debug(context, "total memory:         {f}", .{total_memory});
    log.debug(context, "  free memory:        {f}", .{free_memory});
    log.debug(context, "  used memory:        {f}", .{used_memory});
    log.debug(context, "  reserved memory:    {f}", .{reserved_memory});
    log.debug(context, "  reclaimable memory: {f}", .{reclaimable_memory});
    log.debug(context, "  unavailable memory: {f}", .{unavailable_memory});

    cascade.mem.phys.init.setPhysicalMemoryData(.{
        .page_regions = page_regions,
        .pages = pages,
        .free_page_list = free_page_list,
        .free_memory = free_memory.value,
        .total_memory = total_memory,
        .reserved_memory = reserved_memory,
        .reclaimable_memory = reclaimable_memory,
        .unavailable_memory = unavailable_memory,
    });
}

const arch = @import("arch");
const boot = @import("boot");
const cascade = @import("cascade");
const Page = cascade.mem.Page;

const core = @import("core");
const log = cascade.debug.log.scoped(.init_mem);
const std = @import("std");
