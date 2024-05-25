// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

//! Virtual memory management.

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const log = kernel.log.scoped(.vmm);

pub const DirectMapPool = @import("DirectMapPool.zig").DirectMapPool;

/// The memory layout of the kernel.
///
/// Initialized during `init.buildMemoryLayout`.
pub var memory_layout: MemoryLayout = undefined;

/// The kernel page table.
///
/// Initialized during `init.initVmm`.
pub var kernel_page_table: *kernel.arch.paging.PageTable = undefined;

/// Switches to the given page table.
///
/// The page table must be mapped into the direct map.
pub fn switchToPageTable(page_table: *const kernel.arch.paging.PageTable) void {
    const physical_address =
        physicalFromDirectMap(core.VirtualAddress.fromPtr(page_table)) catch
        core.panicFmt("page table {*} is not in the direct map", .{page_table});

    kernel.arch.paging.switchToPageTable(physical_address);
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

/// Returns the physical address of the given kernel ELF section virtual address.
///
/// It is the caller's responsibility to ensure that the given virtual address is in the kernel ELF sections.
pub fn physicalFromKernelSectionUnsafe(self: core.VirtualAddress) core.PhysicalAddress {
    return .{ .value = self.value -% memory_layout.physical_to_virtual_offset.value };
}

/// Returns the physical address of the given virtual address if it is in the direct map.
pub fn physicalFromDirectMap(self: core.VirtualAddress) error{AddressNotInDirectMap}!core.PhysicalAddress {
    if (direct_map_range.contains(self)) {
        return .{ .value = self.value -% direct_map_range.address.value };
    }
    return error.AddressNotInDirectMap;
}

/// Maps a virtual range using the standard page size.
///
/// Physical pages are allocated for each page in the virtual range.
pub fn mapRange(page_table: *kernel.arch.paging.PageTable, virtual_range: core.VirtualRange, map_type: MapType) !void {
    core.debugAssert(virtual_range.address.isAligned(kernel.arch.paging.standard_page_size));
    core.debugAssert(virtual_range.size.isAligned(kernel.arch.paging.standard_page_size));

    const last_virtual_address = virtual_range.last();
    var current_virtual_range = core.VirtualRange.fromAddr(
        virtual_range.address,
        kernel.arch.paging.standard_page_size,
    );

    errdefer {
        // Unmap all pages that have been mapped.
        while (current_virtual_range.address.greaterThanOrEqual(virtual_range.address)) {
            unmapRange(page_table, current_virtual_range);
            current_virtual_range.address.moveBackwardInPlace(kernel.arch.paging.standard_page_size);
        }
    }

    // Map all pages that were allocated.
    while (current_virtual_range.address.lessThanOrEqual(last_virtual_address)) {
        const physical_range = try kernel.pmm.allocatePage();

        try mapToPhysicalRange(
            page_table,
            current_virtual_range,
            physical_range,
            map_type,
        );

        current_virtual_range.address.moveForwardInPlace(kernel.arch.paging.standard_page_size);
    }
}

/// Maps a virtual address range to a physical range using the standard page size.
pub fn mapToPhysicalRange(
    page_table: *kernel.arch.paging.PageTable,
    virtual_range: core.VirtualRange,
    physical_range: core.PhysicalRange,
    map_type: MapType,
) !void {
    core.debugAssert(virtual_range.address.isAligned(kernel.arch.paging.standard_page_size));
    core.debugAssert(virtual_range.size.isAligned(kernel.arch.paging.standard_page_size));
    core.debugAssert(physical_range.address.isAligned(kernel.arch.paging.standard_page_size));
    core.debugAssert(physical_range.size.isAligned(kernel.arch.paging.standard_page_size));
    core.debugAssert(virtual_range.size.equal(virtual_range.size));

    log.debug(
        "mapping: {} to {} with type: {}",
        .{ virtual_range, physical_range, map_type },
    );

    return kernel.arch.paging.mapToPhysicalRange(
        page_table,
        virtual_range,
        physical_range,
        map_type,
    );
}

/// Unmaps a virtual range.
///
/// **REQUIREMENTS**:
/// - `virtual_range.address` must be aligned to `kernel.arch.paging.standard_page_size`
/// - `virtual_range.size` must be aligned to `kernel.arch.paging.standard_page_size`
pub fn unmapRange(
    page_table: *kernel.arch.paging.PageTable,
    virtual_range: core.VirtualRange,
) void {
    core.debugAssert(virtual_range.address.isAligned(kernel.arch.paging.standard_page_size));
    core.debugAssert(virtual_range.size.isAligned(kernel.arch.paging.standard_page_size));

    log.debug("unmapping: {}", .{virtual_range});

    return kernel.arch.paging.unmapRange(page_table, virtual_range);
}

pub const MapType = struct {
    /// Accessible from userspace.
    user: bool = false,

    /// A global mapping that is not flushed on context switch.
    global: bool = false,

    /// Writeable.
    writeable: bool = false,

    /// Executable.
    executable: bool = false,

    /// Uncached.
    no_cache: bool = false,

    pub fn equal(a: MapType, b: MapType) bool {
        return a.user == b.user and
            a.global == b.global and
            a.writeable == b.writeable and
            a.executable == b.executable and
            a.no_cache == b.no_cache;
    }

    pub fn print(value: MapType, writer: std.io.AnyWriter, indent: usize) !void {
        _ = indent;

        try writer.writeAll("Type{ ");

        const buffer: []const u8 = &[_]u8{
            if (value.user) 'U' else 'K',
            if (value.writeable) 'W' else 'R',
            if (value.executable) 'X' else '-',
            if (value.global) 'G' else '-',
            if (value.no_cache) 'C' else '-',
        };

        try writer.writeAll(buffer);
        try writer.writeAll(" }");
    }

    pub inline fn format(
        region: MapType,
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
        MapType.print(undefined, @as(std.fs.File.Writer, undefined), 0);
    }
};

pub const init = struct {
    pub fn buildMemoryLayout() !void {
        log.debug("building kernel memory layout", .{});

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
        try registerDirectMap();
        try registerHeaps();

        memory_layout.sortMemoryLayout();

        if (log.levelEnabled(.debug)) {
            log.debug("kernel memory layout:", .{});

            for (memory_layout.layout.constSlice()) |region| {
                log.debug("\t{}", .{region});
            }
        }
    }

    pub fn initVmm() !void {
        log.debug("building kernel page table", .{});

        kernel_page_table = try kernel.arch.paging.allocatePageTable();

        for (memory_layout.layout.constSlice()) |region| {
            switch (region.operation) {
                .full_map => {
                    const physical_range = switch (region.type) {
                        .direct_map => core.PhysicalRange.fromAddr(core.PhysicalAddress.zero, region.range.size),
                        .executable_section, .readonly_section, .sdf_section, .writeable_section => core.PhysicalRange.fromAddr(
                            core.PhysicalAddress.fromInt(
                                region.range.address.value - memory_layout.physical_to_virtual_offset.value,
                            ),
                            region.range.size,
                        ),
                        .eternal_heap => unreachable,
                    };

                    const map_type: MapType = switch (region.type) {
                        .executable_section => .{ .executable = true, .global = true },
                        .readonly_section, .sdf_section => .{ .global = true },
                        .writeable_section, .direct_map => .{ .writeable = true, .global = true },
                        .eternal_heap => unreachable,
                    };

                    try kernel.arch.paging.init.mapToPhysicalRangeAllPageSizes(
                        kernel_page_table,
                        region.range,
                        physical_range,
                        map_type,
                    );
                },
                .top_level_map => {
                    try kernel.arch.paging.init.fillTopLevel(
                        kernel_page_table,
                        region.range,
                        .{ .global = true, .writeable = true },
                    );
                },
            }
        }

        log.debug("switching to kernel page table", .{});
        kernel.vmm.switchToPageTable(kernel_page_table);
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

            memory_layout.registerRegion(.{ .range = virtual_range, .type = region_type, .operation = .full_map });
        }
    }

    fn registerDirectMap() !void {
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
        memory_layout.registerRegion(.{ .range = candidate_direct_map_range, .type = .direct_map, .operation = .full_map });
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

    fn registerHeaps() !void {
        const size_of_top_level = kernel.arch.paging.init.sizeOfTopLevelEntry();

        memory_layout.registerRegion(.{
            .range = memory_layout.findFreeRange(size_of_top_level, size_of_top_level) orelse
                core.panic("no space in kernel memory layout for the eternal heap"),
            .type = .eternal_heap,
            .operation = .top_level_map,
        });
    }
};

pub const MemoryLayout = struct {
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

    pub fn findFreeRange(self: *MemoryLayout, size: core.Size, opt_alignment: ?core.Size) ?core.VirtualRange {
        self.sortMemoryLayout();

        const regions = self.layout.constSlice();

        var current_address = kernel.arch.paging.higher_half;
        if (opt_alignment) |alignment| current_address.alignForwardInPlace(alignment);

        var i: usize = 0;

        while (true) {
            const region = if (i < self.layout.len) regions[i] else {
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
                if (opt_alignment) |alignment| current_address.alignForwardInPlace(alignment);
                i += 1;
                continue;
            }

            const size_of_free_range = core.Size.from(
                (region_address.value - 1) - current_address.value,
                .byte,
            );

            if (size_of_free_range.lessThan(size)) {
                current_address = region.range.endBound();
                if (opt_alignment) |alignment| current_address.alignForwardInPlace(alignment);
                i += 1;
                continue;
            }

            return core.VirtualRange.fromAddr(current_address, size);
        }
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

        operation: Operation,

        pub const Type = enum {
            writeable_section,
            readonly_section,
            executable_section,
            sdf_section,

            direct_map,

            eternal_heap,
        };

        pub const Operation = enum {
            full_map,
            top_level_map,
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
