// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");

comptime {
    _ = &boot; // ensure any entry points or bootloader required symbols are referenced
}

pub const arch = @import("arch/arch.zig");
pub const boot = @import("boot.zig");
pub const Cpu = @import("Cpu.zig");
pub const debug = @import("debug.zig");
pub const info = @import("info.zig");
pub const log = @import("log.zig");
pub const pmm = @import("pmm.zig");
pub const vmm = @import("vmm.zig");
pub const sync = @import("sync/sync.zig");

/// Returns the virtual address corresponding to this physical address in the direct map.
pub fn directMapFromPhysical(self: core.PhysicalAddress) core.VirtualAddress {
    return .{ .value = self.value + info.direct_map.address.value };
}

/// Returns the virtual address corresponding to this physical address in the non-cached direct map.
pub fn nonCachedDirectMapFromPhysical(self: core.PhysicalAddress) core.VirtualAddress {
    return .{ .value = self.value + info.non_cached_direct_map.address.value };
}

/// Returns the physical address of the given virtual address if it is in one of the direct maps.
pub fn physicalFromDirectMaps(self: core.VirtualAddress) error{AddressNotInAnyDirectMap}!core.PhysicalAddress {
    if (info.direct_map.contains(self)) {
        return .{ .value = self.value -% info.direct_map.address.value };
    }
    if (info.non_cached_direct_map.contains(self)) {
        return .{ .value = self.value -% info.non_cached_direct_map.address.value };
    }
    return error.AddressNotInAnyDirectMap;
}

/// Returns the physical range of the given direct map virtual range.
pub fn physicalRangeFromDirectMaps(self: core.VirtualRange) error{AddressNotInAnyDirectMap}!core.PhysicalRange {
    if (info.direct_map.containsRange(self)) {
        return .{
            .address = core.PhysicalAddress.fromInt(self.address.value -% info.direct_map.address.value),
            .size = self.size,
        };
    }
    if (info.non_cached_direct_map.containsRange(self)) {
        return .{
            .address = core.PhysicalAddress.fromInt(self.address.value -% info.non_cached_direct_map.address.value),
            .size = self.size,
        };
    }
    return error.AddressNotInAnyDirectMap;
}

/// Returns the physical address of the given direct map virtual address.
///
/// It is the caller's responsibility to ensure that the given virtual address is in the direct map.
pub fn physicalFromDirectMapUnsafe(self: core.VirtualAddress) core.PhysicalAddress {
    return .{ .value = self.value -% info.direct_map.address.value };
}

/// Returns the physical range of the given direct map virtual range.
///
/// It is the caller's responsibility to ensure that the given virtual address is in the direct map.
pub fn physicalRangeFromDirectMapUnsafe(self: core.VirtualRange) core.PhysicalRange {
    return .{
        .address = core.PhysicalAddress.fromInt(self.address.value -% info.direct_map.address.value),
        .size = self.size,
    };
}

/// Returns the physical address of the given kernel ELF section virtual address.
///
/// It is the caller's responsibility to ensure that the given virtual address is in the kernel ELF sections.
pub fn physicalFromKernelSectionUnsafe(self: core.VirtualAddress) core.PhysicalAddress {
    return .{ .value = self.value -% info.kernel_physical_to_virtual_offset.value };
}

/// Returns a virtual range corresponding to this physical range in the direct map.
pub fn directMapFromPhysicalRange(self: core.PhysicalRange) core.VirtualRange {
    return .{
        .address = directMapFromPhysical(self.address),
        .size = self.size,
    };
}

pub const std_options: std.Options = .{
    .log_level = log.log_level,
    .logFn = log.stdLogImpl,
};

pub const panic = debug.zigPanic;
