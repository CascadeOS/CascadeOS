// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

//! Virtual memory management.

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const log = kernel.log.scoped(.vmm);

/// The virtual base address that the kernel was loaded at.
///
/// Initialized during `init.captureKernelOffsets.
pub var kernel_virtual_base_address: core.VirtualAddress = undefined;

/// The offset from the requested ELF virtual base address to the address that the kernel was actually loaded at.
///
/// Initialized during `init.captureKernelOffsets`.
pub var kernel_virtual_offset: ?core.Size = null;

/// Offset from the virtual address of kernel sections to the physical address of the section.
///
/// Initialized during `init.captureKernelOffsets`.
pub var kernel_physical_to_virtual_offset: core.Size = undefined;

/// This direct map provides an identity mapping between virtual and physical addresses.
///
/// Initialized during `init.captureBootloaderDirectMap`.
pub var direct_map: core.VirtualRange = undefined;

/// Returns the virtual address corresponding to this physical address in the direct map.
pub fn directMapFromPhysical(self: core.PhysicalAddress) core.VirtualAddress {
    return .{ .value = self.value + direct_map.address.value };
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
    if (direct_map.containsRange(self)) {
        return .{
            .address = core.PhysicalAddress.fromInt(self.address.value -% direct_map.address.value),
            .size = self.size,
        };
    }
    return error.AddressNotInDirectMap;
}

pub const init = struct {
    pub fn earlyVmmInit() !void {
        log.debug("capturing kernel offsets", .{});
        try captureKernelOffsets();

        log.debug("capturing direct map", .{});
        try captureBootloaderDirectMap();
    }

    fn captureKernelOffsets() !void {
        const kernel_base_address = kernel.boot.kernelBaseAddress() orelse return error.KernelBaseAddressNotProvided;

        const kernel_virtual = kernel_base_address.virtual;
        const kernel_physical = kernel_base_address.physical;

        kernel_virtual_base_address = kernel_virtual;
        log.debug("kernel virtual base address: {}", .{kernel_virtual_base_address});
        log.debug("kernel physical base address: {}", .{kernel_physical});

        kernel_virtual_offset = core.Size.from(kernel_virtual.value - kernel.config.kernel_base_address.value, .byte);
        kernel_physical_to_virtual_offset = core.Size.from(kernel_virtual.value - kernel_physical.value, .byte);
        log.debug("kernel virtual offset: 0x{x}", .{kernel_virtual_offset.?.value});
        log.debug("kernel physical to virtual offset: 0x{x}", .{kernel_physical_to_virtual_offset.value});
    }

    fn captureBootloaderDirectMap() !void {
        const direct_map_size = try calculateSizeOfDirectMap();

        direct_map = try calculateDirectMapRange(direct_map_size);
        log.debug("direct map: {}", .{direct_map});
    }

    /// Calculates the size of the direct map.
    fn calculateSizeOfDirectMap() !core.Size {
        const last_memory_map_entry = blk: {
            var memory_map_iterator = kernel.boot.memoryMap(.backwards);
            while (memory_map_iterator.next()) |memory_map_entry| {
                if (memory_map_entry.type == .reserved_or_unusable and
                    memory_map_entry.range.address.equal(core.PhysicalAddress.fromInt(0x000000fd00000000)))
                {
                    // this is a qemu specific hack to not have a 1TiB direct map
                    // this `0xfd00000000` memory region is not listed in qemu's `info mtree` but the bootloader reports it
                    continue;
                }
                break :blk memory_map_entry;
            }
            return error.NoMemoryMapEntries;
        };

        var direct_map_size = core.Size.from(last_memory_map_entry.range.last().value, .byte);

        // We align the length of the direct map to `largest_page_size` to allow large pages to be used for the mapping.
        direct_map_size.alignForwardInPlace(kernel.arch.paging.all_page_sizes[kernel.arch.paging.all_page_sizes.len - 1]);

        // We ensure that the lowest 4GiB are always mapped.
        const four_gib = core.Size.from(4, .gib);
        if (direct_map_size.lessThan(four_gib)) direct_map_size = four_gib;

        log.debug("size of direct map: {}", .{direct_map_size});

        return direct_map_size;
    }

    fn calculateDirectMapRange(direct_map_size: core.Size) !core.VirtualRange {
        const direct_map_address = kernel.boot.directMapAddress() orelse return error.DirectMapAddressNotProvided;

        if (!direct_map_address.isAligned(kernel.arch.paging.standard_page_size)) {
            return error.DirectMapAddressNotAligned;
        }

        return core.VirtualRange.fromAddr(direct_map_address, direct_map_size);
    }
};
