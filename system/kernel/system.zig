// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

/// Array of all executors.
///
/// Initialized during init and never modified again.
pub var executors: []kernel.Executor = &.{};

/// The memory layout of the kernel.
///
/// Initialized during `init.buildMemoryLayout`.
pub var memory_layout: MemoryLayout = .{};

pub const MemoryLayout = struct {
    /// The virtual base address that the kernel was loaded at.
    virtual_base_address: core.VirtualAddress = kernel.config.kernel_base_address,

    /// The offset from the requested ELF virtual base address to the address that the kernel was actually loaded at.
    ///
    /// This is optional due to the small window on start up where the panic handler can run before this is set.
    virtual_offset: ?core.Size = null,

    /// Offset from the virtual address of kernel sections to the physical address of the section.
    physical_to_virtual_offset: ?core.Size = null,

    /// Provides an identity mapping between virtual and physical addresses.
    ///
    /// Initialized during `init.buildMemoryLayout`.
    direct_map: core.VirtualRange = undefined,

    /// Provides an identity mapping between virtual and physical addresses.
    ///
    /// Caching is disabled for this mapping.
    ///
    /// Initialized during `init.buildMemoryLayout`.
    non_cached_direct_map: core.VirtualRange = undefined,

    layout: std.BoundedArray(Region, std.meta.tags(Region.Type).len) = .{},

    /// Registers a kernel memory region.
    pub fn registerRegion(self: *MemoryLayout, region: Region) void {
        self.layout.append(region) catch core.panic("failed to register region", @errorReturnTrace());
    }

    /// Sorts the kernel memory layout from lowest to highest address.
    pub fn sortMemoryLayout(self: *MemoryLayout) void {
        std.mem.sort(Region, self.layout.slice(), {}, struct {
            fn lessThanFn(context: void, region: Region, other_region: Region) bool {
                _ = context;
                return region.range.address.lessThan(other_region.range.address);
            }
        }.lessThanFn);
    }

    pub const Region = struct {
        range: core.VirtualRange,
        type: Type,

        pub const Type = enum {
            writeable_section,
            readonly_section,
            executable_section,
            sdf_section,

            direct_map,
            non_cached_direct_map,
        };

        pub fn print(region: Region, writer: std.io.AnyWriter, indent: usize) !void {
            try writer.writeAll("MemoryLayout.Region{ ");
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
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
