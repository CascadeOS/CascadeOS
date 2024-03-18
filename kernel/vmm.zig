// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

//! Virtual memory management.

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const log = kernel.log.scoped(.vmm);

var kernel_page_table: kernel.arch.paging.PageTable = .{};
var memory_layout: KernelMemoryLayout = .{};

pub const init = struct {
    pub fn buildKernelPageTableAndSwitch() !void {
        log.debug("building kernel page table", .{});

        mapDirectMaps() catch |err| {
            log.err("failed to map direct maps: {s}", .{@errorName(err)});
            return err;
        };

        mapKernelSections() catch |err| {
            log.err("failed to map kernel sections: {s}", .{@errorName(err)});
            return err;
        };

        log.debug("switching to kernel page table", .{});
        loadKernelPageTable();

        if (log.levelEnabled(.debug)) {
            log.debug("kernel memory regions:", .{});

            for (memory_layout.layout.slice()) |region| {
                log.debug("\t{}", .{region});
            }
        }
    }

    pub fn loadKernelPageTable() void {
        kernel.arch.paging.switchToPageTable(
            kernel.physicalFromKernelSectionUnsafe(
                core.VirtualAddress.fromPtr(&kernel_page_table),
            ),
        );
    }

    /// Maps the direct maps in the kernel page table and registers them in the memory layout.
    fn mapDirectMaps() !void {
        const direct_map_physical_range = core.PhysicalRange.fromAddr(core.PhysicalAddress.zero, kernel.info.direct_map.size);

        log.debug("mapping the direct map", .{});

        try unsafeMapToPhysicalRangeAllPageSizes(
            &kernel_page_table,
            kernel.info.direct_map,
            direct_map_physical_range,
            .{ .writeable = true, .global = true },
        );
        memory_layout.registerRegion(.{ .range = kernel.info.direct_map, .type = .direct_map });

        log.debug("mapping the non-cached direct map", .{});

        try unsafeMapToPhysicalRangeAllPageSizes(
            &kernel_page_table,
            kernel.info.non_cached_direct_map,
            direct_map_physical_range,
            .{ .writeable = true, .no_cache = true, .global = true },
        );
        memory_layout.registerRegion(.{ .range = kernel.info.non_cached_direct_map, .type = .non_cached_direct_map });
    }

    /// Maps the kernel sections in the kernel page table and registers them in the memory layout.
    fn mapKernelSections() !void {
        const linker_symbols = struct {
            extern const __text_start: u8;
            extern const __text_end: u8;
            extern const __rodata_start: u8;
            extern const __rodata_end: u8;
            extern const __data_start: u8;
            extern const __data_end: u8;
        };

        log.debug("mapping .text section", .{});
        try mapSection(
            @intFromPtr(&linker_symbols.__text_start),
            @intFromPtr(&linker_symbols.__text_end),
            .{ .executable = true, .global = true },
            .executable_section,
        );

        log.debug("mapping .rodata section", .{});
        try mapSection(
            @intFromPtr(&linker_symbols.__rodata_start),
            @intFromPtr(&linker_symbols.__rodata_end),
            .{ .global = true },
            .readonly_section,
        );

        log.debug("mapping .data section", .{});
        try mapSection(
            @intFromPtr(&linker_symbols.__data_start),
            @intFromPtr(&linker_symbols.__data_end),
            .{ .writeable = true, .global = true },
            .writeable_section,
        );

        const sdf_slice = kernel.info.sdfSlice();
        log.debug("mapping .sdf section", .{});
        try mapSection(
            @intFromPtr(sdf_slice.ptr),
            @intFromPtr(sdf_slice.ptr) + sdf_slice.len,
            .{ .global = true },
            .sdf_section,
        );
    }

    /// Maps a kernel section.
    fn mapSection(
        section_start: usize,
        section_end: usize,
        map_type: MapType,
        region_type: KernelMemoryLayout.KernelMemoryRegion.Type,
    ) !void {
        if (section_start == section_end) return;

        core.assert(section_end > section_start);

        const virt_address = core.VirtualAddress.fromInt(section_start);

        const virtual_range = core.VirtualRange.fromAddr(
            virt_address,
            core.Size
                .from(section_end - section_start, .byte)
                .alignForward(kernel.arch.paging.standard_page_size),
        );
        core.assert(virtual_range.size.isAligned(kernel.arch.paging.standard_page_size));

        const phys_address = core.PhysicalAddress.fromInt(
            virt_address.value - kernel.info.kernel_physical_to_virtual_offset.value,
        );

        const physical_range = core.PhysicalRange.fromAddr(phys_address, virtual_range.size);

        try unsafeMapToPhysicalRangeAllPageSizes(
            &kernel_page_table,
            virtual_range,
            physical_range,
            map_type,
        );

        memory_layout.registerRegion(.{ .range = virtual_range, .type = region_type });
    }

    /// Maps a virtual address range to a physical address range using all available page sizes.
    ///
    /// Caller must ensure:
    ///  - the virtual range address and size are aligned to the standard page size
    ///  - the physical range address and size are aligned to the standard page size
    ///  - the virtual range size is equal to the physical range size
    ///
    /// No TLB flushing is performed.
    fn unsafeMapToPhysicalRangeAllPageSizes(
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
            "mapping {} to {} with type {} using all page sizes",
            .{ virtual_range, physical_range, map_type },
        );

        return kernel.arch.paging.mapToPhysicalRangeAllPageSizes(
            page_table,
            virtual_range,
            physical_range,
            map_type,
        );
    }
};

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

    pub fn print(value: MapType, writer: anytype) !void {
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
        return print(region, writer);
    }
};

const KernelMemoryLayout = struct {
    layout: std.BoundedArray(KernelMemoryRegion, std.meta.tags(KernelMemoryRegion.Type).len) = .{},

    /// Registers a kernel memory region.
    pub fn registerRegion(self: *KernelMemoryLayout, region: KernelMemoryRegion) void {
        self.layout.append(region) catch unreachable;
        self.sortKernelMemoryLayout();
    }

    /// Sorts the kernel memory layout from lowest to highest address.
    fn sortKernelMemoryLayout(self: *KernelMemoryLayout) void {
        std.mem.sort(KernelMemoryRegion, self.layout.slice(), {}, struct {
            fn lessThanFn(context: void, region: KernelMemoryRegion, other_region: KernelMemoryRegion) bool {
                _ = context;
                return region.range.address.lessThan(other_region.range.address);
            }
        }.lessThanFn);
    }

    pub const KernelMemoryRegion = struct {
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

        pub fn print(region: KernelMemoryRegion, writer: anytype) !void {
            try writer.writeAll("KernelMemoryRegion{ ");
            try region.range.print(writer);
            try writer.writeAll(" - ");
            try writer.writeAll(@tagName(region.type));
            try writer.writeAll(" }");
        }

        pub inline fn format(
            region: KernelMemoryRegion,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = options;
            _ = fmt;
            return print(region, writer);
        }
    };
};
