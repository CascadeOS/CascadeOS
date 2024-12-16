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
} || kernel.mem.physical.AllocatePageError;

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
        const physical_range = try kernel.mem.physical.allocatePage();
        errdefer kernel.mem.physical.deallocatePage(physical_range);

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
};

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");
const arch = @import("arch");
const boot = @import("boot");
const log = kernel.log.scoped(.mem);
