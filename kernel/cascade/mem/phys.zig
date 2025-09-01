// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

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
        std.debug.assert(offset_into_region < region.number_of_frames);

        const index = region.start_index + offset_into_region;
        std.debug.assert(index < globals.pages.len);

        return @enumFromInt(index);
    }
};

pub const FrameAllocator = struct {
    allocate: Allocate,
    deallocate: Deallocate,

    pub const AllocateError = error{FramesExhausted};

    pub const Allocate = *const fn (context: *cascade.Context) AllocateError!Frame;
    pub const Deallocate = *const fn (context: *cascade.Context, frame_list: FrameList) void;
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

fn allocate(_: *cascade.Context) FrameAllocator.AllocateError!Frame {
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

fn deallocate(_: *cascade.Context, frame_list: FrameList) void {
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
    /// Initialized during `init.initializeFrameAllocator`.
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

pub const initialization = struct {
    /// Initializes the normal physical frame allocator and the pages array.
    ///
    /// Pulls all memory out of the bootstrap physical frame allocator and uses it to populate the normal allocator.
    pub fn initializePhysicalMemory(
        context: *cascade.Context,
        number_of_usable_pages: usize,
        number_of_usable_regions: usize,
        kernel_regions: *mem.KernelMemoryRegion.List,
        memory_map: []const init.exports.boot.MemoryMapEntry,
        free_physical_regions: []const init.mem.phys.FreePhysicalRegion,
    ) void {
        init_log.debug(
            context,
            "initializing pages array with {} usable pages ({f}) in {} regions",
            .{
                number_of_usable_pages,
                arch.paging.standard_page_size.multiplyScalar(number_of_usable_pages),
                number_of_usable_regions,
            },
        );

        const pages_range = kernel_regions.find(.pages).?.range;

        // ugly pointer stuff to setup the page and page region arrays
        {
            var byte_ptr = pages_range.address.toPtr([*]u8);

            const page_regions_ptr: [*]Page.Region = @ptrCast(@alignCast(byte_ptr));
            globals.page_regions = page_regions_ptr[0..number_of_usable_regions];

            byte_ptr += @sizeOf(Page.Region) * number_of_usable_regions;
            byte_ptr = std.mem.alignPointer(byte_ptr, @alignOf(Page)).?;

            const page_ptr: [*]Page = @ptrCast(@alignCast(byte_ptr));
            globals.pages = page_ptr[0..number_of_usable_pages];
        }

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

                if (init_log.levelEnabled(.debug)) {
                    if (in_use_frames == 0) {
                        init_log.debug(
                            context,
                            "pulled {} ({f}) free frames out of bootstrap frame allocator region",
                            .{
                                free_frames,
                                arch.paging.standard_page_size.multiplyScalar(free_frames),
                            },
                        );
                    } else if (in_use_frames == free_bootstrap_region.frame_count) {
                        init_log.debug(
                            context,
                            "pulled {} ({f}) in use frames out of bootstrap frame allocator region",
                            .{
                                in_use_frames,
                                arch.paging.standard_page_size.multiplyScalar(in_use_frames),
                            },
                        );
                    } else {
                        init_log.debug(
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

            const start_frame: Frame = .fromAddress(entry.range.address);

            globals.page_regions[usable_range_index] = .{
                .start_frame = start_frame,
                .number_of_frames = usable_pages_in_range,
                .start_index = page_index,
            };
            usable_range_index += 1;

            const range_start_phys_frame = @intFromEnum(start_frame);

            for (0..usable_pages_in_range) |range_i| {
                globals.pages[page_index] = .{
                    .physical_frame = @enumFromInt(range_start_phys_frame + range_i),
                };

                if (in_use_frames_left != 0) {
                    in_use_frames_left -= 1;
                } else {
                    globals.free_page_list.prepend(&globals.pages[page_index].node);
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

        init_log.debug(context, "total memory:         {f}", .{total_memory});
        init_log.debug(context, "  free memory:        {f}", .{free_memory});
        init_log.debug(context, "  used memory:        {f}", .{used_memory});
        init_log.debug(context, "  reserved memory:    {f}", .{reserved_memory});
        init_log.debug(context, "  reclaimable memory: {f}", .{reclaimable_memory});
        init_log.debug(context, "  unavailable memory: {f}", .{unavailable_memory});

        globals.total_memory = total_memory;
        globals.free_memory.store(free_memory.value, .release);
        globals.reserved_memory = reserved_memory;
        globals.reclaimable_memory = reclaimable_memory;
        globals.unavailable_memory = unavailable_memory;
    }

    const init_log = cascade.debug.log.scoped(.init_mem_phys);
};

const arch = @import("arch");
const init = @import("init");
const cascade = @import("cascade");
const mem = cascade.mem;

const core = @import("core");
const log = cascade.debug.log.scoped(.mem_phys);
const std = @import("std");
