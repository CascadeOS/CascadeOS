// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
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

pub const globals = struct {
    /// The list of free pages.
    ///
    /// Initialized during `init.mem.phys.initializePhysicalMemory`.
    pub var free_page_list: core.containers.AtomicSinglyLinkedList = .{};

    /// The free physical memory.
    ///
    /// Updates to this value are eventually consistent.
    ///
    /// Initialized during `init.mem.phys.initializePhysicalMemory`.
    pub var free_memory: std.atomic.Value(u64) = undefined;

    /// The total physical memory.
    ///
    /// Does not change during the lifetime of the system.
    ///
    /// Initialized during `init.mem.phys.initializePhysicalMemory`.
    pub var total_memory: core.Size = undefined;

    /// The reserved physical memory.
    ///
    /// Does not change during the lifetime of the system.
    ///
    /// Initialized during `init.mem.phys.initializePhysicalMemory`.
    pub var reserved_memory: core.Size = undefined;

    /// The reclaimable physical memory.
    ///
    /// Will be reduced when the memory is reclaimed. // TODO: reclaim memory
    ///
    /// Initialized during `init.mem.phys.initializePhysicalMemory`.
    pub var reclaimable_memory: core.Size = undefined;

    /// The unavailable physical memory.
    ///
    /// Does not change during the lifetime of the system.
    ///
    /// Initialized during `init.mem.phys.initializePhysicalMemory`.
    pub var unavailable_memory: core.Size = undefined;

    /// A `Page` for each usable physical page.
    ///
    /// Initialized during `init.mem.phys.initializePhysicalMemory`.
    pub var pages: []Page = undefined;

    /// A `Page.Region` for each range of usable physical pages in the `pages` array.
    ///
    /// Initialized during `init.mem.phys.initializePhysicalMemory`.
    pub var page_regions: []Page.Region = undefined;
};
