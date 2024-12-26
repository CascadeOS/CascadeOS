// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

/// Returns the virtual address corresponding to this physical address in the direct map.
pub fn directMapFromPhysical(self: core.PhysicalAddress) core.VirtualAddress {
    return .{ .value = self.value + globals.direct_map.address.value };
}

pub const globals = struct {
    /// The virtual base address that the kernel was loaded at.
    ///
    /// Initialized during `init.earlyPartialMemoryLayout`.
    pub var virtual_base_address: core.VirtualAddress = undefined;

    /// The offset from the requested ELF virtual base address to the address that the kernel was actually loaded at.
    ///
    /// Initialized during `init.earlyPartialMemoryLayout`.
    pub var virtual_offset: core.Size = undefined;

    /// Offset from the virtual address of kernel sections to the physical address of the section.
    ///
    /// Initialized during `init.earlyPartialMemoryLayout`.
    pub var physical_to_virtual_offset: core.Size = undefined;

    /// Provides an identity mapping between virtual and physical addresses.
    ///
    /// Initialized during `init.earlyPartialMemoryLayout`.
    pub var direct_map: core.VirtualRange = undefined;
};

pub const init = struct {
    /// Ensures that the kernel base address, virtual offset and the direct map are set up.
    ///
    /// Called very early so cannot log.
    pub fn earlyPartialMemoryLayout() !void {
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
    }
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
