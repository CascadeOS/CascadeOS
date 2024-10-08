// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

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

pub const Region = struct {
    range: core.VirtualRange,
    type: Type,

    operation: Operation,

    pub const Type = enum {
        writeable_section,
        readonly_section,
        executable_section,
        sdf_section,

        direct_map,
        non_cached_direct_map,

    pub const Operation = enum {
        full_map,
        top_level_map,
    };

    pub fn print(region: Region, writer: std.io.AnyWriter, indent: usize) !void {
        try writer.writeAll("Region{ ");
        try region.range.print(writer, indent);
        try writer.writeAll(" - ");
        try writer.writeAll(@tagName(region.type));
        try writer.writeAll(" }");
    }

    pub inline fn format(
        region: Region,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        _ = fmt;
        return if (@TypeOf(writer) == std.io.AnyWriter)
            print(region, writer, 0)
        else
            print(region, writer.any(), 0);
    }

    fn __helpZls() void {
        Region.print(undefined, @as(std.fs.File.Writer, undefined), 0);
    }
};

pub const globals = struct {
    /// The virtual base address that the kernel was loaded at.
    pub var virtual_base_address: core.VirtualAddress = kernel.config.kernel_base_address;

    /// Offset from the virtual address of kernel sections to the physical address of the section.
    ///
    /// Initialized during `init.earlyBuildMemoryLayout`.
    pub var physical_to_virtual_offset: core.Size = undefined;

    /// The offset from the requested ELF virtual base address to the address that the kernel was actually loaded at.
    ///
    /// This is optional due to the small window on start up where the panic handler can run before this is set.
    ///
    /// Initialized during `init.earlyBuildMemoryLayout`.
    pub var virtual_offset: ?core.Size = null;

    /// Provides an identity mapping between virtual and physical addresses.
    ///
    /// Initialized during `init.earlyBuildMemoryLayout`.
    pub var direct_map: core.VirtualRange = undefined;

    /// Provides an identity mapping between virtual and physical addresses.
    ///
    /// Caching is disabled for this mapping.
    ///
    /// Initialized during `init.finishBuildMemoryLayout`.
    pub var non_cached_direct_map: core.VirtualRange = undefined;

    pub var layout: std.BoundedArray(Region, std.meta.tags(Region.Type).len) = .{};
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
