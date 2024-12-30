// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

//! Virtual memory management.

pub const MapType = @import("MapType.zig");

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

/// Returns the physical address of the given virtual address if it is in the direct map.
pub fn physicalFromDirectMap(self: core.VirtualAddress) error{AddressNotInDirectMap}!core.PhysicalAddress {
    if (globals.direct_map.contains(self)) {
        return .{ .value = self.value -% globals.direct_map.address.value };
    }
    return error.AddressNotInDirectMap;
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

pub const globals = struct {
    /// The core page table.
    ///
    /// All other page tables start as a copy of this one.
    ///
    /// Initialized during `init.buildCorePageTable`.
    pub var core_page_table: kernel.arch.paging.PageTable = undefined;

    /// The virtual base address that the kernel was loaded at.
    ///
    /// Initialized during `init.buildMemoryLayout`.
    pub var virtual_base_address: core.VirtualAddress = undefined;

    /// The offset from the requested ELF virtual base address to the address that the kernel was actually loaded at.
    ///
    /// Initialized during `init.buildMemoryLayout`.
    pub var virtual_offset: core.Size = undefined;

    /// Offset from the virtual address of kernel sections to the physical address of the section.
    ///
    /// Initialized during `init.buildMemoryLayout`.
    pub var physical_to_virtual_offset: core.Size = undefined;

    /// Provides an identity mapping between virtual and physical addresses.
    ///
    /// Initialized during `init.buildMemoryLayout`.
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

    const Regions = std.BoundedArray(KernelMemoryRegion, std.meta.tags(KernelMemoryRegion.Type).len);
};

pub const init = struct {
    pub fn buildMemoryLayout() !void {
        const base_address = kernel.boot.kernelBaseAddress() orelse return error.NoKernelBaseAddress;
        globals.virtual_base_address = base_address.virtual;

        globals.virtual_offset = core.Size.from(
            base_address.virtual.value - kernel.config.kernel_base_address.value,
            .byte,
        );

        globals.physical_to_virtual_offset = core.Size.from(
            base_address.virtual.value - base_address.physical.value,
            .byte,
        );

        try registerKernelSections();
        try registerDirectMaps();

        sortKernelMemoryRegions();
    }

    pub fn logMemoryLayout() void {
        if (!init_log.levelEnabled(.debug)) return;

        const base_address = kernel.boot.kernelBaseAddress() orelse unreachable;
        init_log.debug("limine base address:       {}", .{base_address});

        init_log.debug("virtual base address:       {}", .{globals.virtual_base_address});
        init_log.debug("virtual offset:             0x{x:0>16}", .{globals.virtual_offset.value});
        init_log.debug("physical to virtual offset: 0x{x:0>16}", .{globals.physical_to_virtual_offset.value});

        init_log.debug("kernel memory layout:", .{});

        for (globals.regions.constSlice()) |region| {
            init_log.debug("\t{}", .{region});
        }
    }

    pub fn buildCorePageTable() !void {
        globals.core_page_table = kernel.arch.paging.PageTable.create(
            try kernel.pmm.allocatePage(),
        );

        for (globals.regions.constSlice()) |region| {
            const physical_range = switch (region.type) {
                .direct_map,
                .non_cached_direct_map,
                => core.PhysicalRange.fromAddr(core.PhysicalAddress.zero, region.range.size),
                .executable_section,
                .readonly_section,
                .sdf_section,
                .writeable_section,
                => core.PhysicalRange.fromAddr(
                    core.PhysicalAddress.fromInt(
                        region.range.address.value - globals.physical_to_virtual_offset.value,
                    ),
                    region.range.size,
                ),
            };

            const map_type: MapType = switch (region.type) {
                .executable_section => .{ .executable = true, .global = true },
                .readonly_section, .sdf_section => .{ .global = true },
                .writeable_section, .direct_map => .{ .writeable = true, .global = true },
                .non_cached_direct_map => .{ .writeable = true, .global = true, .no_cache = true },
            };

            try kernel.arch.paging.init.mapToPhysicalRangeAllPageSizes(
                globals.core_page_table,
                region.range,
                physical_range,
                map_type,
            );
        }
    }

    fn sortKernelMemoryRegions() void {
        std.mem.sort(KernelMemoryRegion, globals.regions.slice(), {}, struct {
            fn lessThanFn(context: void, region: KernelMemoryRegion, other_region: KernelMemoryRegion) bool {
                _ = context;
                return region.range.address.lessThan(other_region.range.address);
            }
        }.lessThanFn);
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
                    .alignForward(kernel.arch.paging.standard_page_size),
            );

            try globals.regions.append(.{
                .range = virtual_range,
                .type = region_type,
            });
        }
    }

    fn registerDirectMaps() !void {
        const direct_map_size = direct_map_size: {
            const last_memory_map_entry = last_memory_map_entry: {
                var memory_map_iterator = kernel.boot.memoryMap(.backward) orelse return error.NoMemoryMap;
                break :last_memory_map_entry memory_map_iterator.next() orelse return error.NoMemoryMapEntries;
            };

            var direct_map_size = core.Size.from(last_memory_map_entry.range.last().value, .byte);

            // We ensure that the lowest 4GiB are always mapped.
            const four_gib = core.Size.from(4, .gib);
            if (direct_map_size.lessThan(four_gib)) direct_map_size = four_gib;

            // We align the length of the direct map to `largest_page_size` to allow large pages to be used for the mapping.
            direct_map_size.alignForwardInPlace(kernel.arch.paging.largest_page_size);

            break :direct_map_size direct_map_size;
        };

        globals.direct_map = core.VirtualRange.fromAddr(
            kernel.boot.directMapAddress() orelse return error.DirectMapAddressNotProvided,
            direct_map_size,
        );

        const direct_map = globals.direct_map;

        // does the direct map range overlap a pre-existing region?
        for (globals.regions.constSlice()) |region| {
            if (region.range.containsRange(direct_map)) {
                return error.DirectMapOverlapsRegion;
            }
        }

        try globals.regions.append(.{
            .range = direct_map,
            .type = .direct_map,
        });

        const non_cached_direct_map = findFreeRange(
            direct_map.size,
            kernel.arch.paging.largest_page_size,
        ) orelse return error.NoFreeRangeForDirectMap;

        globals.non_cached_direct_map = non_cached_direct_map;

        try globals.regions.append(.{
            .range = non_cached_direct_map,
            .type = .non_cached_direct_map,
        });
    }

    fn findFreeRange(size: core.Size, alignment: core.Size) ?core.VirtualRange {
        // needs the regions to be sorted
        sortKernelMemoryRegions();

        const regions = globals.regions.constSlice();

        var current_address = kernel.arch.paging.higher_half_start;
        current_address.alignForwardInPlace(alignment);

        var i: usize = 0;

        while (true) {
            const region = if (i < regions.len) regions[i] else {
                const size_of_free_range = core.Size.from(
                    (kernel.arch.paging.largest_higher_half_virtual_address.value) - current_address.value,
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

    const init_log = kernel.log.scoped(.init_vmm);
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const KernelMemoryRegion = @import("KernelMemoryRegion.zig");
