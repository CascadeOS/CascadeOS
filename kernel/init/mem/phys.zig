// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub const bootstrap_allocator: phys.FrameAllocator = .{
    .allocate = struct {
        fn allocate(context: *cascade.Context) !phys.Frame {
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
        fn deallocate(_: *cascade.Context, _: phys.FrameList) void {
            @panic("deallocate not supported");
        }
    }.deallocate,
};

pub const FreePhysicalRegion = struct {
    /// The first frame of the region.
    start_physical_frame: phys.Frame,

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

const arch = @import("arch");
const boot = @import("boot");
const cascade = @import("cascade");
const phys = cascade.mem.phys;

const core = @import("core");
const log = cascade.debug.log.scoped(.init_mem);
const std = @import("std");
