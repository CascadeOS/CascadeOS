// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const Task = cascade.Task;
const mem = cascade.mem;
const core = @import("core");

pub const Page = @import("Page.zig");

pub const allocator: FrameAllocator = .{
    .allocate = allocate,
    .deallocate = deallocate,
};

pub const Frame = enum(u32) {
    _,

    /// Returns the base address of the given physical frame.
    pub fn baseAddress(frame: Frame) core.PhysicalAddress {
        return .fromInt(@intFromEnum(frame) * arch.paging.standard_page_size.value);
    }

    /// Returns the physical frame that contains the given physical address.
    pub fn fromAddress(physical_address: core.PhysicalAddress) Frame {
        return @enumFromInt(physical_address.value / arch.paging.standard_page_size.value);
    }

    pub fn page(frame: Frame) ?*Page {
        const index = frame.pageIndex() orelse return null;
        return &globals.pages[@intFromEnum(index)];
    }

    pub fn pageIndex(frame: Frame) ?Page.Index {
        const region_index = std.sort.binarySearch(
            Page.Region,
            globals.page_regions,
            frame,
            struct {
                fn compare(inner_frame: Frame, region: Page.Region) std.math.Order {
                    return region.compareContainsFrame(inner_frame);
                }
            }.compare,
        ) orelse return null;
        const region = globals.page_regions[region_index];

        const offset_into_region = @intFromEnum(frame) - @intFromEnum(region.start_frame);
        if (core.is_debug) std.debug.assert(offset_into_region < region.number_of_frames);

        const index = region.start_index + offset_into_region;
        if (core.is_debug) std.debug.assert(index < globals.pages.len);

        return @enumFromInt(index);
    }
};

pub const FrameAllocator = struct {
    allocate: Allocate,
    deallocate: Deallocate,

    pub const AllocateError = error{FramesExhausted};

    pub const Allocate = *const fn (current_task: Task.Current) AllocateError!Frame;
    pub const Deallocate = *const fn (current_task: Task.Current, frame_list: FrameList) void;
};

pub const FrameList = struct {
    first_node: ?*std.SinglyLinkedList.Node = null,
    last_node: ?*std.SinglyLinkedList.Node = null,
    count: usize = 0,

    pub fn push(frame_list: *FrameList, frame: Frame) void {
        const page = frame.page() orelse std.debug.panic("page not found for frame: {}", .{frame});
        const node = &page.node;

        node.next = null;

        frame_list.last_node = node;
        if (frame_list.first_node) |first_node| {
            first_node.next = node;
        } else {
            frame_list.first_node = node;
        }

        frame_list.count += 1;
    }
};

fn allocate(_: Task.Current) FrameAllocator.AllocateError!Frame {
    const node = globals.free_page_list.popFirst() orelse return error.FramesExhausted;

    _ = globals.free_memory.fetchSub(
        arch.paging.standard_page_size.value,
        .release,
    );

    const page: *cascade.mem.Page = .fromNode(node);

    if (core.is_debug) {
        const virtual_range = core.VirtualRange.fromAddr(
            cascade.mem.directMapFromPhysical(page.physical_frame.baseAddress()),
            arch.paging.standard_page_size,
        );

        @memset(virtual_range.toByteSlice(), undefined);
    }

    return page.physical_frame;
}

fn deallocate(_: Task.Current, frame_list: FrameList) void {
    if (frame_list.count == 0) {
        @branchHint(.unlikely);
        return;
    }

    globals.free_page_list.prependList(frame_list.first_node.?, frame_list.last_node.?);

    _ = globals.free_memory.fetchAdd(
        arch.paging.standard_page_size.multiplyScalar(frame_list.count).value,
        .release,
    );
}

const globals = struct {
    /// The list of free pages.
    ///
    /// Initialized during `init.initializePhysicalMemory`.
    var free_page_list: core.containers.AtomicSinglyLinkedList = .{};

    /// The free physical memory.
    ///
    /// Updates to this value are eventually consistent.
    ///
    /// Initialized during `init.initializePhysicalMemory`.
    var free_memory: std.atomic.Value(u64) = undefined;

    /// The total physical memory.
    ///
    /// Does not change during the lifetime of the system.
    ///
    /// Initialized during `init.initializePhysicalMemory`.
    var total_memory: core.Size = undefined;

    /// The reserved physical memory.
    ///
    /// Does not change during the lifetime of the system.
    ///
    /// Initialized during `init.initializePhysicalMemory`.
    var reserved_memory: core.Size = undefined;

    /// The reclaimable physical memory.
    ///
    /// Will be reduced when the memory is reclaimed. // TODO: reclaim memory
    ///
    /// Initialized during `init.initializePhysicalMemory`.
    var reclaimable_memory: core.Size = undefined;

    /// The unavailable physical memory.
    ///
    /// Does not change during the lifetime of the system.
    ///
    /// Initialized during `init.initializePhysicalMemory`.
    var unavailable_memory: core.Size = undefined;

    /// A `Page` for each usable physical page.
    ///
    /// Initialized during `init.initializePhysicalMemory`.
    var pages: []Page = undefined;

    /// A `Page.Region` for each range of usable physical pages in the `pages` array.
    ///
    /// Initialized during `init.initializePhysicalMemory`.
    var page_regions: []Page.Region = undefined;
};

pub const init = struct {
    const boot = @import("boot");
    const init_log = cascade.debug.log.scoped(.mem_init);

    pub const bootstrap_allocator: FrameAllocator = .{
        .allocate = struct {
            fn allocate(current_task: Task.Current) !Frame {
                const non_empty_region: *FreePhysicalRegion =
                    region: for (init_globals.free_physical_regions.slice()) |*region| {
                        if (region.first_free_frame_index < region.frame_count) break :region region;
                    } else {
                        for (init_globals.free_physical_regions.constSlice()) |region| {
                            init_log.warn(current_task, "  region: {}", .{region});
                        }

                        @panic("no empty region in bootstrap physical frame allocator");
                    };

                const first_free_frame_index = non_empty_region.first_free_frame_index;
                non_empty_region.first_free_frame_index = first_free_frame_index + 1;

                return @enumFromInt(@intFromEnum(non_empty_region.start_physical_frame) + first_free_frame_index);
            }
        }.allocate,
        .deallocate = struct {
            fn deallocate(_: Task.Current, _: FrameList) void {
                @panic("deallocate not supported");
            }
        }.deallocate,
    };

    /// Initialize the bootstrap physical frame allocator that is used for allocating physical frames before the full memory
    /// system is initialized.
    pub fn initializeBootstrapFrameAllocator(_: Task.Current) void {
        var memory_map = boot.memoryMap(.forward) catch @panic("no memory map");
        while (memory_map.next()) |entry| {
            if (entry.type != .free) continue;

            init_globals.free_physical_regions.append(.{
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
        current_task: Task.Current,
        number_of_usable_pages: usize,
        number_of_usable_regions: usize,
        pages_range: core.VirtualRange,
        memory_map: []const boot.MemoryMap.Entry,
    ) void {
        init_log.debug(
            current_task,
            "initializing pages array with {} usable pages ({f}) in {} regions",
            .{
                number_of_usable_pages,
                arch.paging.standard_page_size.multiplyScalar(number_of_usable_pages),
                number_of_usable_regions,
            },
        );

        const free_physical_regions = init_globals.free_physical_regions.constSlice();

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
        globals.page_regions = page_regions;
        globals.pages = pages;

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

            if (core.is_debug) {
                std.debug.assert(entry.range.address.isAligned(arch.paging.standard_page_size));
                std.debug.assert(entry.range.size.isAligned(arch.paging.standard_page_size));
            }

            var in_use_frames_left: u32 = if (entry.type == .free) blk: {
                // pull the free region out of the bootstrap allocator

                const free_bootstrap_region = free_physical_regions[free_region_index];

                free_region_index += 1;

                if (core.is_debug) std.debug.assert(free_bootstrap_region.start_physical_frame.baseAddress().equal(entry.range.address));

                const in_use_frames = free_bootstrap_region.first_free_frame_index;

                const free_frames = free_bootstrap_region.frame_count - in_use_frames;
                free_memory.addInPlace(arch.paging.standard_page_size.multiplyScalar(free_frames));

                if (init_log.levelEnabled(.debug)) {
                    if (in_use_frames == 0) {
                        init_log.debug(
                            current_task,
                            "pulled {} ({f}) free frames out of bootstrap frame allocator region",
                            .{
                                free_frames,
                                arch.paging.standard_page_size.multiplyScalar(free_frames),
                            },
                        );
                    } else if (in_use_frames == free_bootstrap_region.frame_count) {
                        init_log.debug(
                            current_task,
                            "pulled {} ({f}) in use frames out of bootstrap frame allocator region",
                            .{
                                in_use_frames,
                                arch.paging.standard_page_size.multiplyScalar(in_use_frames),
                            },
                        );
                    } else {
                        init_log.debug(
                            current_task,
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

            const start_frame: Frame = .fromAddress(entry.range.address);

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
        if (core.is_debug) {
            std.debug.assert(page_index == number_of_usable_pages);
            std.debug.assert(usable_range_index == number_of_usable_regions);
        }

        globals.free_page_list.first.store(free_page_list.first, .release);
        globals.free_memory.store(free_memory.value, .release);
        globals.total_memory = total_memory;
        globals.reserved_memory = reserved_memory;
        globals.reclaimable_memory = reclaimable_memory;
        globals.unavailable_memory = unavailable_memory;

        const used_memory = total_memory
            .subtract(free_memory)
            .subtract(reserved_memory)
            .subtract(reclaimable_memory)
            .subtract(unavailable_memory);

        init_log.debug(current_task, "total memory:         {f}", .{total_memory});
        init_log.debug(current_task, "  free memory:        {f}", .{free_memory});
        init_log.debug(current_task, "  used memory:        {f}", .{used_memory});
        init_log.debug(current_task, "  reserved memory:    {f}", .{reserved_memory});
        init_log.debug(current_task, "  reclaimable memory: {f}", .{reclaimable_memory});
        init_log.debug(current_task, "  unavailable memory: {f}", .{unavailable_memory});
    }

    const FreePhysicalRegion = struct {
        /// The first frame of the region.
        start_physical_frame: Frame,

        /// Index of the first free frame in this region.
        first_free_frame_index: u32,

        /// Total number of frames in the region.
        frame_count: u32,

        pub const List = core.containers.BoundedArray(FreePhysicalRegion, max_regions);
        const max_regions: usize = 64;
    };

    const init_globals = struct {
        /// The physical regions used by the bootstrap allocator.
        ///
        /// Initialized during `init.initializeBootstrapFrameAllocator`.
        var free_physical_regions: FreePhysicalRegion.List = .{};
    };
};
