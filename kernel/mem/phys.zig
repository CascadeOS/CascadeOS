// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub const allocator: FrameAllocator = .{
    .allocate = allocate,
    .deallocate = deallocate,
};

pub const Frame = enum(u32) {
    _,

    /// Returns the base address of the given physical frame.
    pub fn baseAddress(self: Frame) core.PhysicalAddress {
        return .fromInt(@intFromEnum(self) * kernel.arch.paging.standard_page_size.value);
    }

    /// Returns the physical frame that contains the given physical address.
    pub fn fromAddress(physical_address: core.PhysicalAddress) Frame {
        return @enumFromInt(physical_address.value / kernel.arch.paging.standard_page_size.value);
    }
};

pub const FrameAllocator = struct {
    allocate: Allocate,
    deallocate: Deallocate,

    pub const AllocateError = error{FramesExhausted};

    pub const Allocate = *const fn () AllocateError!Frame;
    pub const Deallocate = *const fn (Frame) void;
};

fn allocate() FrameAllocator.AllocateError!Frame {
    const node = globals.free_page_list.pop() orelse return error.FramesExhausted;

    _ = globals.free_memory.fetchSub(
        kernel.arch.paging.standard_page_size.value,
        .release,
    );

    const page: *kernel.mem.Page = .fromFreeListNode(node);

    page.state = .in_use;

    if (core.is_debug) {
        const virtual_range = core.VirtualRange.fromAddr(
            kernel.mem.directMapFromPhysical(page.physical_frame.baseAddress()),
            kernel.arch.paging.standard_page_size,
        );

        @memset(virtual_range.toByteSlice(), undefined);
    }

    return page.physical_frame;
}

fn deallocate(frame: Frame) void {
    const page = kernel.mem.pageFromFrame(frame) orelse std.debug.panic("page not found for frame: {}", .{frame});
    std.debug.assert(page.state == .in_use);

    page.state = .{ .free = .{} };
    globals.free_page_list.push(&page.state.free.free_list_node);

    _ = globals.free_memory.fetchAdd(kernel.arch.paging.standard_page_size.value, .release);
}

const globals = struct {
    /// The list of free pages.
    ///
    /// Initialized during `init.initializePhysicalMemory`.
    var free_page_list: containers.AtomicSinglyLinkedLIFO = .empty;

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
};

pub const init = struct {
    var regions: std.BoundedArray(Region, max_regions) = .{};
    const max_regions: usize = 64;

    /// Initializes the normal physical frame allocator.
    ///
    /// Pulls all memory out of the bootstrap physical frame allocator and uses it to populate the normal allocator.
    pub fn initializePhysicalMemory() void {
        var iter = kernel.boot.memoryMap(.forward) catch @panic("no memory map");

        var total_memory: core.Size = .zero;
        var free_memory: core.Size = .zero;
        var reserved_memory: core.Size = .zero;
        var reclaimable_memory: core.Size = .zero;
        var unavailable_memory: core.Size = .zero;

        while (iter.next()) |entry| {
            total_memory.addInPlace(entry.range.size);

            switch (entry.type) {
                .free => {
                    std.debug.assert(entry.range.address.isAligned(kernel.arch.paging.standard_page_size));
                    std.debug.assert(entry.range.size.isAligned(kernel.arch.paging.standard_page_size));

                    const bootstrap_region = regions.orderedRemove(0);
                    std.debug.assert(bootstrap_region.start_physical_frame.baseAddress().equal(entry.range.address));

                    const free_frames = bootstrap_region.frame_count - bootstrap_region.first_free_frame_index;

                    if (free_frames == 0) {
                        init_log.debug(
                            "pulled {} ({}) used frames out of bootstrap frame allocator region",
                            .{
                                bootstrap_region.frame_count - free_frames,
                                kernel.arch.paging.standard_page_size.multiplyScalar(bootstrap_region.frame_count - free_frames),
                            },
                        );
                        continue;
                    }

                    if (free_frames == bootstrap_region.frame_count) {
                        init_log.debug(
                            "pulled {} ({}) free frames out of bootstrap frame allocator region",
                            .{
                                free_frames,
                                kernel.arch.paging.standard_page_size.multiplyScalar(free_frames),
                            },
                        );
                    } else {
                        init_log.debug(
                            "pulled {} ({}) free frames and {} ({}) used frames out of bootstrap frame allocator region",
                            .{
                                free_frames,
                                kernel.arch.paging.standard_page_size.multiplyScalar(free_frames),
                                bootstrap_region.frame_count - free_frames,
                                kernel.arch.paging.standard_page_size.multiplyScalar(bootstrap_region.frame_count - free_frames),
                            },
                        );
                    }

                    free_memory.addInPlace(kernel.arch.paging.standard_page_size.multiplyScalar(free_frames));

                    const first_free_frame: Frame = @enumFromInt(
                        @intFromEnum(bootstrap_region.start_physical_frame) + bootstrap_region.first_free_frame_index,
                    );

                    var page_index = kernel.mem.pageIndexFromFrame(first_free_frame).?;

                    for (0..free_frames) |_| {
                        kernel.mem.globals.pages[page_index].state = .{ .free = .{} };
                        globals.free_page_list.push(&kernel.mem.globals.pages[page_index].state.free.free_list_node);
                        page_index += 1;
                    }
                },
                .in_use => {},
                .reserved => reserved_memory.addInPlace(entry.range.size),
                .bootloader_reclaimable, .acpi_reclaimable => reclaimable_memory.addInPlace(entry.range.size),
                .unusable, .unknown => unavailable_memory.addInPlace(entry.range.size),
            }
        }

        const used_memory = total_memory
            .subtract(free_memory)
            .subtract(reserved_memory)
            .subtract(reclaimable_memory)
            .subtract(unavailable_memory);

        init_log.debug("total memory:         {}", .{total_memory});
        init_log.debug("  free memory:        {}", .{free_memory});
        init_log.debug("  used memory:        {}", .{used_memory});
        init_log.debug("  reserved memory:    {}", .{reserved_memory});
        init_log.debug("  reclaimable memory: {}", .{reclaimable_memory});
        init_log.debug("  unavailable memory: {}", .{unavailable_memory});

        globals.total_memory = total_memory;
        globals.free_memory.store(free_memory.value, .release);
        globals.reserved_memory = reserved_memory;
        globals.reclaimable_memory = reclaimable_memory;
        globals.unavailable_memory = unavailable_memory;
    }

    pub const bootstrap_allocator: FrameAllocator = .{
        .allocate = struct {
            fn allocate() !Frame {
                const non_empty_region: *Region = region: for (regions.slice()) |*region| {
                    if (region.first_free_frame_index < region.frame_count) break :region region;
                } else {
                    for (regions.constSlice()) |region| {
                        init_log.warn("  region: {}", .{region});
                    }

                    @panic("no empty region in bootstrap physical frame allocator");
                };

                const first_free_frame_index = non_empty_region.first_free_frame_index;
                non_empty_region.first_free_frame_index = first_free_frame_index + 1;

                return @enumFromInt(@intFromEnum(non_empty_region.start_physical_frame) + first_free_frame_index);
            }
        }.allocate,
        .deallocate = struct {
            fn deallocate(_: Frame) void {
                @panic("deallocate not supported");
            }
        }.deallocate,
    };

    pub fn initializeBootstrapFrameAllocator() void {
        var memory_iter = kernel.boot.memoryMap(.forward) catch @panic("no memory map");

        init_log.debug("bootloader provided memory map:", .{});

        while (memory_iter.next()) |entry| {
            init_log.debug("\t{}", .{entry});
            if (entry.type != .free) continue;

            regions.append(.{
                .start_physical_frame = .fromAddress(entry.range.address),
                .first_free_frame_index = 0,
                .frame_count = @intCast(std.math.divExact(
                    usize,
                    entry.range.size.value,
                    kernel.arch.paging.standard_page_size.value,
                ) catch std.debug.panic(
                    "memory map entry size is not a multiple of page size: {}",
                    .{entry},
                )),
            }) catch @panic("exceeded max number of regions");
        }

        if (init_log.levelEnabled(.debug)) {
            var frames_available: usize = 0;
            for (regions.slice()) |region| {
                frames_available += region.frame_count;
            }
            init_log.debug(
                "bootstrap physical frame allocator initalized with {} free frames ({})",
                .{ frames_available, kernel.arch.paging.standard_page_size.multiplyScalar(frames_available) },
            );
        }
    }

    const Region = struct {
        /// The first frame of the region.
        start_physical_frame: Frame,

        /// Index of the first free frame in this region.
        first_free_frame_index: u32,

        /// Total number of frames in the region.
        frame_count: u32,
    };

    const init_log = kernel.debug.log.scoped(.init_mem_phys);
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const log = kernel.debug.log.scoped(.mem_phys);
const containers = @import("containers");
