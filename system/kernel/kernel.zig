// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

pub const config = @import("config.zig");
pub const debug = @import("debug.zig");
pub const Executor = @import("Executor.zig");
pub const log = @import("log.zig");
pub const Stack = @import("Stack.zig");
pub const system = @import("system.zig");

/// Returns the virtual address corresponding to this physical address in the direct map.
pub fn directMapFromPhysical(self: core.PhysicalAddress) core.VirtualAddress {
    return .{ .value = self.value + system.memory_layout.direct_map.address.value };
}

/// Returns the virtual address corresponding to this physical address in the non-cached direct map.
pub fn nonCachedDirectMapFromPhysical(self: core.PhysicalAddress) core.VirtualAddress {
    return .{ .value = self.value + system.memory_layout.non_cached_direct_map.address.value };
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
    if (system.memory_layout.direct_map.containsRange(self)) {
        return .{
            .address = .fromInt(self.address.value -% system.memory_layout.direct_map.address.value),
            .size = self.size,
        };
    }
    return error.AddressNotInDirectMap;
}

/// Returns the physical address of the given kernel ELF section virtual address.
///
/// It is the caller's responsibility to ensure that the given virtual address is in the kernel ELF sections.
pub fn physicalFromKernelSectionUnsafe(self: core.VirtualAddress) core.PhysicalAddress {
    return .{ .value = self.value -% system.memory_layout.physical_to_virtual_offset.value };
}

/// Returns the physical address of the given virtual address if it is in the direct map.
pub fn physicalFromDirectMap(self: core.VirtualAddress) error{AddressNotInDirectMap}!core.PhysicalAddress {
    if (system.memory_layout.direct_map.contains(self)) {
        return .{ .value = self.value -% system.memory_layout.direct_map.address.value };
    }
    return error.AddressNotInDirectMap;
}

const std = @import("std");
const core = @import("core");
