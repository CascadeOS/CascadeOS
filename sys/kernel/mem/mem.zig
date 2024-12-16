// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

pub const heap = @import("heap.zig");
pub const physical = @import("physical.zig");

pub const KernelMemoryRegion = @import("KernelMemoryRegion.zig");
pub const MapType = @import("MapType.zig");
pub const ResourceArena = @import("ResourceArena.zig");

pub const MapError = error{
    AlreadyMapped,

    /// This is used to surface errors from the underlying paging implementation that are architecture specific.
    MappingNotValid,
} || physical.AllocatePageError;

/// Maps a virtual range using the standard page size.
///
/// Physical pages are allocated for each page in the virtual range.
pub fn mapRange(
    page_table: *arch.paging.PageTable,
    virtual_range: core.VirtualRange,
    map_type: MapType,
) MapError!void {
    std.debug.assert(virtual_range.address.isAligned(arch.paging.standard_page_size));
    std.debug.assert(virtual_range.size.isAligned(arch.paging.standard_page_size));

    const last_virtual_address = virtual_range.last();
    var current_virtual_range = core.VirtualRange.fromAddr(
        virtual_range.address,
        arch.paging.standard_page_size,
    );

    errdefer {
        // Unmap all pages that have been mapped.
        while (current_virtual_range.address.greaterThanOrEqual(virtual_range.address)) {
            unmapRange(page_table, current_virtual_range, true);
            current_virtual_range.address.moveBackwardInPlace(arch.paging.standard_page_size);
        }
    }

    // Map all pages that were allocated.
    while (current_virtual_range.address.lessThanOrEqual(last_virtual_address)) {
        const physical_range = try physical.allocatePage();
        errdefer physical.deallocatePage(physical_range);

        try mapToPhysicalRange(
            page_table,
            current_virtual_range,
            physical_range,
            map_type,
        );

        current_virtual_range.address.moveForwardInPlace(arch.paging.standard_page_size);
    }

    // TODO: flush caches
}

/// Maps a virtual address range to a physical range using the standard page size.
pub fn mapToPhysicalRange(
    page_table: *arch.paging.PageTable,
    virtual_range: core.VirtualRange,
    physical_range: core.PhysicalRange,
    map_type: MapType,
) MapError!void {
    std.debug.assert(virtual_range.address.isAligned(arch.paging.standard_page_size));
    std.debug.assert(virtual_range.size.isAligned(arch.paging.standard_page_size));
    std.debug.assert(physical_range.address.isAligned(arch.paging.standard_page_size));
    std.debug.assert(physical_range.size.isAligned(arch.paging.standard_page_size));
    std.debug.assert(virtual_range.size.equal(virtual_range.size));

    try arch.paging.mapToPhysicalRange(
        page_table,
        virtual_range,
        physical_range,
        map_type,
    );

    // TODO: flush caches
}

/// Unmaps a virtual range.
///
/// **REQUIREMENTS**:
/// - `virtual_range.address` must be aligned to `arch.paging.standard_page_size`
/// - `virtual_range.size` must be aligned to `arch.paging.standard_page_size`
pub fn unmapRange(
    page_table: *arch.paging.PageTable,
    virtual_range: core.VirtualRange,
    free_backing_pages: bool,
) void {
    std.debug.assert(virtual_range.address.isAligned(arch.paging.standard_page_size));
    std.debug.assert(virtual_range.size.isAligned(arch.paging.standard_page_size));

    arch.paging.unmapRange(page_table, virtual_range, free_backing_pages);

    // TODO: flush caches
}

/// Returns the virtual address corresponding to this physical address in the direct map.
pub fn directMapFromPhysical(self: core.PhysicalAddress) core.VirtualAddress {
    return .{ .value = self.value + globals.direct_map.address.value };
}

/// Returns the virtual address corresponding to this physical address in the non-cached direct map.
pub fn nonCachedDirectMapFromPhysical(self: core.PhysicalAddress) core.VirtualAddress {
    return .{ .value = self.value + globals.non_cached_direct_map.address.value };
}

/// Returns a virtual range corresponding to this physical range in the direct map.
pub fn directMapFromPhysicalRange(self: core.PhysicalRange) core.VirtualRange {
    return .{
        .address = directMapFromPhysical(self.address),
        .size = self.size,
    };
}

/// Returns the physical range of the given direct map virtual range.
pub fn physicalRangeFromDirectMap(self: core.VirtualRange) error{AddressNotInDirectMap}!core.PhysicalRange {
    if (globals.direct_map.containsRange(self)) {
        return .{
            .address = .fromInt(self.address.value -% globals.direct_map.address.value),
            .size = self.size,
        };
    }
    return error.AddressNotInDirectMap;
}

/// Returns the physical address of the given kernel ELF section virtual address.
///
/// It is the caller's responsibility to ensure that the given virtual address is in the kernel ELF sections.
pub fn physicalFromKernelSectionUnsafe(self: core.VirtualAddress) core.PhysicalAddress {
    return .{ .value = self.value -% globals.physical_to_virtual_offset.value };
}

/// Returns the physical address of the given virtual address if it is in the direct map.
pub fn physicalFromDirectMap(self: core.VirtualAddress) error{AddressNotInDirectMap}!core.PhysicalAddress {
    if (globals.direct_map.contains(self)) {
        return .{ .value = self.value -% globals.direct_map.address.value };
    }
    return error.AddressNotInDirectMap;
}

pub fn getKernelRegion(range_type: KernelMemoryRegion.Type) ?core.VirtualRange {
    for (globals.regions.constSlice()) |region| {
        if (region.type == range_type) return region.range;
    }

    return null;
}

pub const Regions = std.BoundedArray(KernelMemoryRegion, std.meta.tags(KernelMemoryRegion.Type).len);

pub const globals = struct {
    /// The core page table.
    ///
    /// All other page tables start as a copy of this one.
    ///
    /// Initialized during `init.buildCorePageTable`.
    pub var core_page_table: arch.paging.PageTable = undefined;

    /// The virtual base address that the kernel was loaded at.
    pub var virtual_base_address: core.VirtualAddress = kernel.config.kernel_base_address;

    /// Offset from the virtual address of kernel sections to the physical address of the section.
    ///
    /// Initialized during `init.earlyPartialMemoryLayout`.
    pub var physical_to_virtual_offset: core.Size = undefined;

    /// The offset from the requested ELF virtual base address to the address that the kernel was actually loaded at.
    ///
    /// This is optional due to the small window on start up where the panic handler can run before this is set.
    ///
    /// Initialized during `init.earlyPartialMemoryLayout`.
    pub var virtual_offset: ?core.Size = null;

    /// Provides an identity mapping between virtual and physical addresses.
    ///
    /// Initialized during `init.earlyPartialMemoryLayout`.
    pub var direct_map: core.VirtualRange = undefined;

    /// Provides an identity mapping between virtual and physical addresses.
    ///
    /// Caching is disabled for this mapping.
    ///
    /// Initialized during `init.buildMemoryLayout`.
    pub var non_cached_direct_map: core.VirtualRange = undefined;

    /// The layout of the memory regions of the kernel.
    ///
    /// Initialized during `init.buildMemoryLayout`.
    pub var regions: Regions = undefined;
};

pub const init = struct {
    /// Ensures that the kernel base address, virtual offset and the direct map are set up.
    ///
    /// Called very early so cannot log.
    pub fn earlyPartialMemoryLayout() !void {
        const base_address = boot.kernelBaseAddress() orelse return error.NoKernelBaseAddress;
        globals.virtual_base_address = base_address.virtual;

        globals.virtual_offset = core.Size.from(
            base_address.virtual.value - kernel.config.kernel_base_address.value,
            .byte,
        );

        globals.physical_to_virtual_offset = core.Size.from(
            base_address.virtual.value - base_address.physical.value,
            .byte,
        );

        const direct_map_size = direct_map_size: {
            const last_memory_map_entry = last_memory_map_entry: {
                var memory_map_iterator = boot.memoryMap(.backward) orelse return error.NoMemoryMap;
                break :last_memory_map_entry memory_map_iterator.next() orelse return error.NoMemoryMapEntries;
            };

            var direct_map_size = core.Size.from(last_memory_map_entry.range.last().value, .byte);

            // We ensure that the lowest 4GiB are always mapped.
            const four_gib = core.Size.from(4, .gib);
            if (direct_map_size.lessThan(four_gib)) direct_map_size = four_gib;

            // We align the length of the direct map to `largest_page_size` to allow large pages to be used for the mapping.
            direct_map_size.alignForwardInPlace(arch.paging.largest_page_size);

            break :direct_map_size direct_map_size;
        };

        globals.direct_map = core.VirtualRange.fromAddr(
            boot.directMapAddress() orelse return error.DirectMapAddressNotProvided,
            direct_map_size,
        );
    }

    pub fn buildMemoryLayout() !void {
        log.debug("registering kernel sections", .{});
        try registerKernelSections();
        log.debug("registering direct maps", .{});
        try registerDirectMaps();
        log.debug("registering heaps", .{});
        try registerHeaps();

        if (log.levelEnabled(.debug)) {
            log.debug("kernel memory layout:", .{});

            for (globals.regions.constSlice()) |region| {
                log.debug("\t{}", .{region});
            }
        }
    }

    fn registerKernelSections() !void {
        const linker_symbols = struct {
            extern const __text_start: u8;
            extern const __text_end: u8;
            extern const __rodata_start: u8;
            extern const __rodata_end: u8;
            extern const __data_start: u8;
            extern const __data_end: u8;
        };

        const sdf_slice = try kernel.debug.sdfSlice();
        const sdf_range = core.VirtualRange.fromSlice(u8, sdf_slice);

        const sections: []const struct {
            core.VirtualAddress,
            core.VirtualAddress,
            KernelMemoryRegion.Type,
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

            try appendKernelRegion(.{
                .range = virtual_range,
                .type = region_type,
                .operation = .full_map,
            });
        }
    }

    fn registerDirectMaps() !void {
        const direct_map = globals.direct_map;

        // does the direct map range overlap a pre-existing region?
        for (globals.regions.constSlice()) |region| {
            if (region.range.containsRange(direct_map)) {
                log.err(
                    \\direct map overlaps another memory region:
                    \\  direct map: {}
                    \\  other region: {}
                , .{ direct_map, region });

                return error.DirectMapOverlapsRegion;
            }
        }

        try appendKernelRegion(.{
            .range = direct_map,
            .type = .direct_map,
            .operation = .full_map,
        });

        const non_cached_direct_map = findFreeRange(
            direct_map.size,
            arch.paging.largest_page_size,
        ) orelse return error.NoFreeRangeForDirectMap;

        globals.non_cached_direct_map = non_cached_direct_map;

        try appendKernelRegion(.{
            .range = non_cached_direct_map,
            .type = .non_cached_direct_map,
            .operation = .full_map,
        });
    }

    fn registerHeaps() !void {
        const size_of_top_level = arch.paging.init.sizeOfTopLevelEntry();

        const kernel_stacks_range = findFreeRange(size_of_top_level, size_of_top_level) orelse
            core.panic("no space in kernel memory layout for the kernel stacks", null);

        try appendKernelRegion(.{
            .range = kernel_stacks_range,
            .type = .kernel_stacks,
            .operation = .top_level_map,
        });

        const kernel_heap_range = findFreeRange(size_of_top_level, size_of_top_level) orelse
            core.panic("no space in kernel memory layout for the kernel heap", null);

        try appendKernelRegion(.{
            .range = kernel_heap_range,
            .type = .kernel_heap,
            .operation = .top_level_map,
        });
    }

    pub fn buildCorePageTable() !void {
        globals.core_page_table = arch.paging.PageTable.create(
            try physical.allocatePage(),
        );

        for (globals.regions.constSlice()) |region| {
            switch (region.operation) {
                .full_map => {
                    const physical_range = switch (region.type) {
                        .direct_map, .non_cached_direct_map => core.PhysicalRange.fromAddr(core.PhysicalAddress.zero, region.range.size),
                        .executable_section, .readonly_section, .sdf_section, .writeable_section => core.PhysicalRange.fromAddr(
                            core.PhysicalAddress.fromInt(
                                region.range.address.value - globals.physical_to_virtual_offset.value,
                            ),
                            region.range.size,
                        ),
                        .kernel_stacks => core.panic("kernel stack region is full mapped", null),
                        .kernel_heap => core.panic("kernel heap region is full mapped", null),
                    };

                    const map_type: MapType = switch (region.type) {
                        .executable_section => .{ .executable = true, .global = true },
                        .readonly_section, .sdf_section => .{ .global = true },
                        .writeable_section, .direct_map => .{ .writeable = true, .global = true },
                        .non_cached_direct_map => .{ .writeable = true, .global = true, .no_cache = true },
                        .kernel_stacks => core.panic("kernel stack region is full mapped", null),
                        .kernel_heap => core.panic("kernel heap region is full mapped", null),
                    };

                    arch.paging.init.mapToPhysicalRangeAllPageSizes(
                        globals.core_page_table,
                        region.range,
                        physical_range,
                        map_type,
                    );
                },
                .top_level_map => arch.paging.init.fillTopLevel(
                    globals.core_page_table,
                    region.range,
                    .{ .global = true, .writeable = true },
                ),
            }
        }

        globals.core_page_table.load();
    }

    fn appendKernelRegion(region: KernelMemoryRegion) !void {
        try globals.regions.append(region);
        sortMemoryLayout();
    }

    /// Sorts the kernel memory layout from lowest to highest address.
    fn sortMemoryLayout() void {
        std.mem.sort(KernelMemoryRegion, globals.regions.slice(), {}, struct {
            fn lessThanFn(context: void, region: KernelMemoryRegion, other_region: KernelMemoryRegion) bool {
                _ = context;
                return region.range.address.lessThan(other_region.range.address);
            }
        }.lessThanFn);
    }

    fn findFreeRange(size: core.Size, alignment: core.Size) ?core.VirtualRange {
        const regions = globals.regions.constSlice();

        var current_address = arch.paging.higher_half_start;
        current_address.alignForwardInPlace(alignment);

        var i: usize = 0;

        while (true) {
            const region = if (i < regions.len) regions[i] else {
                const size_of_free_range = core.Size.from(
                    (arch.paging.largest_higher_half_virtual_address.value) - current_address.value,
                    .byte,
                );

                if (size_of_free_range.lessThan(size)) return null;

                return core.VirtualRange.fromAddr(current_address, size);
            };

            const region_address = region.range.address;

            if (region_address.lessThanOrEqual(current_address)) {
                current_address = region.range.endBound();
                current_address.alignForwardInPlace(alignment);
                i += 1;
                continue;
            }

            const size_of_free_range = core.Size.from(
                (region_address.value - 1) - current_address.value,
                .byte,
            );

            if (size_of_free_range.lessThan(size)) {
                current_address = region.range.endBound();
                current_address.alignForwardInPlace(alignment);
                i += 1;
                continue;
            }

            return core.VirtualRange.fromAddr(current_address, size);
        }
    }
};

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");
const arch = @import("arch");
const boot = @import("boot");
const log = kernel.log.scoped(.mem);
