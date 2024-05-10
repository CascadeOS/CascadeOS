// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

//! Virtual memory management.

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const log = kernel.log.scoped(.vmm);

pub const AddressSpace = @import("AddressSpace.zig");
pub const VirtualRangeAllocator = @import("VirtualRangeAllocator.zig");

var memory_layout: KernelMemoryLayout = .{};

pub inline fn kernelPageTable() *kernel.arch.paging.PageTable {
    const static = struct {
        var kernel_page_table: kernel.arch.paging.PageTable = .{};
    };

    return &static.kernel_page_table;
}

pub fn switchToKernelPageTable() void {
    kernel.arch.paging.switchToPageTable(
        kernel.physicalFromKernelSectionUnsafe(core.VirtualAddress.fromPtr(
            kernelPageTable(),
        )),
    );
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

pub const MemoryRegion = struct {
    /// The virtual range of this region.
    range: core.VirtualRange,

    /// The type of mapping.
    map_type: MapType,

    pub fn print(region: MemoryRegion, writer: std.io.AnyWriter, indent: usize) !void {
        try writer.writeAll("MemoryRegion{ ");
        try region.range.print(writer, indent);
        try writer.writeAll(" ");
        try region.map_type.print(writer, indent);
        try writer.writeAll(" }");
    }

    pub inline fn format(
        region: MemoryRegion,
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
        MemoryRegion.print(undefined, @as(std.fs.File.Writer, undefined), 0);
    }
};

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

        prepareKernelStacks() catch |err| {
            core.panicFmt("failed to prepare kernel stacks: {s}", .{@errorName(err)});
        };

        prepareKernelHeaps() catch |err| {
            core.panicFmt("failed to prepare kernel heaps: {s}", .{@errorName(err)});
        };

        log.debug("switching to kernel page table", .{});
        kernel.vmm.switchToKernelPageTable();

        if (log.levelEnabled(.debug)) {
            log.debug("kernel memory regions:", .{});

            for (memory_layout.layout.slice()) |region| {
                log.debug("\t{}", .{region});
            }
        }
    }

    /// Maps the direct maps in the kernel page table and registers them in the memory layout.
    fn mapDirectMaps() !void {
        const direct_map_physical_range = core.PhysicalRange.fromAddr(core.PhysicalAddress.zero, kernel.info.direct_map.size);

        log.debug("mapping the direct map", .{});

        try kernel.arch.paging.init.mapToPhysicalRangeAllPageSizes(
            kernelPageTable(),
            kernel.info.direct_map,
            direct_map_physical_range,
            .{ .writeable = true, .global = true },
        );
        memory_layout.registerRegion(.{ .range = kernel.info.direct_map, .type = .direct_map });

        log.debug("mapping the non-cached direct map", .{});

        try kernel.arch.paging.init.mapToPhysicalRangeAllPageSizes(
            kernelPageTable(),
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

    fn prepareKernelStacks() !void {
        log.debug("preparing the kernel stacks area", .{});

        const kernel_stacks_range = try kernel.arch.paging.init.getTopLevelRangeAndFillFirstLevel(
            kernelPageTable(),
        );

        try kernel.Stack.init.initStacks(kernel_stacks_range);

        memory_layout.registerRegion(.{ .range = kernel_stacks_range, .type = .kernel_stacks });
    }

    fn prepareKernelHeaps() !void {
        log.debug("preparing the kernel heaps", .{});

        const kernel_eternal_heap_range = try kernel.arch.paging.init.getTopLevelRangeAndFillFirstLevel(
            kernelPageTable(),
        );

        const kernel_page_heap_range = try kernel.arch.paging.init.getTopLevelRangeAndFillFirstLevel(
            kernelPageTable(),
        );

        try kernel.heap.init.initHeaps(
            kernel_eternal_heap_range,
            kernel_page_heap_range,
        );

        memory_layout.registerRegion(.{ .range = kernel_eternal_heap_range, .type = .eternal_heap });
        memory_layout.registerRegion(.{ .range = kernel_page_heap_range, .type = .page_heap });
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

        try kernel.arch.paging.init.mapToPhysicalRangeAllPageSizes(
            kernelPageTable(),
            virtual_range,
            physical_range,
            map_type,
        );
        memory_layout.registerRegion(.{ .range = virtual_range, .type = region_type });
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

            kernel_stacks,
            eternal_heap,
            page_heap,
        };

        pub fn print(region: KernelMemoryRegion, writer: std.io.AnyWriter, indent: usize) !void {
            try writer.writeAll("KernelMemoryRegion{ ");
            try region.range.print(writer, indent);
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
            return if (@TypeOf(writer) == std.io.AnyWriter)
                print(region, writer, 0)
            else
                print(region, writer.any(), 0);
        }
        fn __helpZls() void {
            KernelMemoryRegion.print(undefined, @as(std.fs.File.Writer, undefined), 0);
        }
    };
};
