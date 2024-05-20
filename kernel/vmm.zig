// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

//! Virtual memory management.

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const log = kernel.log.scoped(.vmm);

/// The memory layout of the kernel.
///
/// Initialized during `init.buildMemoryLayout`.
var memory_layout: MemoryLayout = undefined;

/// The offset from the requested ELF virtual base address to the address that the kernel was actually loaded at.
///
/// This is optional due to the small window on start up where the panic handler can run before this is set.
pub fn virtualOffset() ?core.Size {
    return memory_layout.virtual_offset;
}

/// Provides an identity mapping between virtual and physical addresses.
///
/// Initialized during `init.buildMemoryLayout`.
var direct_map_range: core.VirtualRange = undefined;

/// Returns the virtual address corresponding to this physical address in the direct map.
pub fn directMapFromPhysical(self: core.PhysicalAddress) core.VirtualAddress {
    return .{ .value = self.value + direct_map_range.address.value };
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
    if (direct_map_range.containsRange(self)) {
        return .{
            .address = core.PhysicalAddress.fromInt(self.address.value -% direct_map_range.address.value),
            .size = self.size,
        };
    }
    return error.AddressNotInDirectMap;
}

pub const init = struct {
    pub fn buildEarlyMemoryLayout() !void {
        log.debug("building early kernel memory layout", .{});

        const base_address = kernel.boot.kernelBaseAddress() orelse return error.KernelBaseAddressNotProvided;

        log.debug("kernel virtual base address: {}", .{base_address.virtual});
        log.debug("kernel physical base address: {}", .{base_address.physical});

        const virtual_offset = core.Size.from(base_address.virtual.value - kernel.config.kernel_base_address.value, .byte);
        const physical_to_virtual_offset = core.Size.from(base_address.virtual.value - base_address.physical.value, .byte);
        log.debug("kernel virtual offset: 0x{x}", .{virtual_offset.value});
        log.debug("kernel physical to virtual offset: 0x{x}", .{physical_to_virtual_offset.value});

        memory_layout = .{
            .virtual_base_address = base_address.virtual,
            .virtual_offset = virtual_offset,
            .physical_to_virtual_offset = physical_to_virtual_offset,
        };

        try registerKernelSections();

        try calculateAndRegisterDirectMap();

        memory_layout.sortMemoryLayout();

        if (log.levelEnabled(.debug)) {
            log.debug("early kernel memory layout:", .{});

            for (memory_layout.layout.constSlice()) |region| {
                log.debug("\t{}", .{region});
            }
        }
    }


    /// Registers the kernel sections in the memory layout.
    fn registerKernelSections() !void {
        const linker_symbols = struct {
            extern const __text_start: u8;
            extern const __text_end: u8;
            extern const __rodata_start: u8;
            extern const __rodata_end: u8;
            extern const __data_start: u8;
            extern const __data_end: u8;
        };

        const sdf_slice = kernel.debug.sdfSlice();
        const sdf_range = core.VirtualRange.fromSlice(u8, sdf_slice);

        const sections: []const struct {
            core.VirtualAddress,
            core.VirtualAddress,
            MemoryLayout.Region.Type,
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

            core.assert(end_address.greaterThan(start_address));

            const virtual_range = core.VirtualRange.fromAddr(
                start_address,
                core.Size
                    .from(end_address.value - start_address.value, .byte)
                    .alignForward(kernel.arch.paging.standard_page_size),
            );

            memory_layout.registerRegion(.{ .range = virtual_range, .type = region_type });
        }
    }

    fn calculateAndRegisterDirectMap() !void {
        const candidate_direct_map_range = core.VirtualRange.fromAddr(
            kernel.boot.directMapAddress() orelse return error.DirectMapAddressNotProvided,
            try calculateSizeOfDirectMap(),
        );

        // does the candidate range overlap a pre-existing region?
        for (memory_layout.layout.constSlice()) |region| {
            if (region.range.containsRange(candidate_direct_map_range)) {
                log.err(
                    \\direct map overlaps a pre-existing memory region:
                    \\  direct map: {}
                    \\  other region: {}
                , .{ candidate_direct_map_range, region });

                return error.DirectMapOverlapsRegion;
            }
        }

        direct_map_range = candidate_direct_map_range;
        memory_layout.registerRegion(.{ .range = candidate_direct_map_range, .type = .direct_map });
    }

    /// Calculates the size of the direct map.
    fn calculateSizeOfDirectMap() !core.Size {
        const last_memory_map_entry = blk: {
            var memory_map_iterator = kernel.boot.memoryMap(.backwards);
            while (memory_map_iterator.next()) |memory_map_entry| {
                if (memory_map_entry.range.address.equal(core.PhysicalAddress.fromInt(0x000000fd00000000))) {
                    log.debug("skipping weird QEMU memory map entry: {}", .{memory_map_entry});
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

        return direct_map_size;
    }
};

const MemoryLayout = struct {
    /// The virtual base address that the kernel was loaded at.
    virtual_base_address: core.VirtualAddress = undefined,

    /// The offset from the requested ELF virtual base address to the address that the kernel was actually loaded at.
    ///
    /// This is optional due to the small window on start up where the panic handler can run before this is set.
    virtual_offset: ?core.Size = null,

    /// Offset from the virtual address of kernel sections to the physical address of the section.
    physical_to_virtual_offset: core.Size = undefined,

    layout: std.BoundedArray(Region, std.meta.tags(Region.Type).len) = .{},

    /// Registers a kernel memory region.
    pub fn registerRegion(self: *MemoryLayout, region: Region) void {
        self.layout.append(region) catch unreachable;
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
