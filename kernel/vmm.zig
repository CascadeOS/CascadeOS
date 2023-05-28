// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const arch = kernel.arch;
const paging = kernel.arch.paging;
const PageTable = paging.PageTable;

const log = kernel.log.scoped(.vmm);

var kernel_root_page_table: *PageTable = undefined;

pub fn init() void {
    log.debug("allocating physical page for kernel root page table", .{});

    const physical_page = kernel.pmm.allocateSmallestPage() orelse core.panic("unable to allocate physical page for root page table");
    std.debug.assert(physical_page.size.greaterThanOrEqual(core.Size.of(PageTable)));

    kernel_root_page_table = physical_page.toKernelVirtual().addr.toPtr(*PageTable);
    kernel_root_page_table.zero();

    identityMaps() catch |err| {
        core.panicFmt("failed to map identity maps: {s}", .{@errorName(err)});
    };

    mapKernelSections() catch |err| {
        core.panicFmt("failed to map kernel sections: {s}", .{@errorName(err)});
    };
}

fn identityMaps() !void {
    const physical_range = arch.PhysRange.fromAddr(arch.PhysAddr.zero, kernel.info.hhdm.size);

    log.debug("identity mapping HHDM", .{});

    try mapRegion(
        kernel_root_page_table,
        kernel.info.hhdm,
        physical_range,
        .{ .writeable = true, .global = true },
    );

    log.debug("identity mapping non-cached HHDM", .{});

    try kernel.vmm.mapRegion(
        kernel_root_page_table,
        kernel.info.non_cached_hhdm,
        physical_range,
        .{ .writeable = true, .no_cache = true, .global = true },
    );
}

const linker_symbols = struct {
    extern const __text_start: u8;
    extern const __text_end: u8;
    extern const __rodata_start: u8;
    extern const __rodata_end: u8;
    extern const __data_start: u8;
    extern const __data_end: u8;
};

fn mapKernelSections() !void {
    log.debug("mapping .text section", .{});
    try mapSection(
        @ptrToInt(&linker_symbols.__text_start),
        @ptrToInt(&linker_symbols.__text_end),
        .{ .executable = true, .global = true },
    );

    log.debug("mapping .rodata section", .{});
    try mapSection(
        @ptrToInt(&linker_symbols.__rodata_start),
        @ptrToInt(&linker_symbols.__rodata_end),
        .{ .global = true },
    );

    log.debug("mapping .data section", .{});
    try mapSection(
        @ptrToInt(&linker_symbols.__data_start),
        @ptrToInt(&linker_symbols.__data_end),
        .{ .writeable = true, .global = true },
    );
}

fn mapSection(start: usize, end: usize, map_type: MapType) !void {
    std.debug.assert(end > start);

    const virtual_range = arch.VirtRange.fromAddr(
        arch.VirtAddr.fromInt(start),
        core.Size.from(end - start, .byte).alignForward(arch.paging.smallest_page_size),
    );

    const physical_range = arch.PhysRange.fromAddr(
        arch.PhysAddr.fromInt(start).moveBackward(kernel.info.kernel_slide),
        virtual_range.size,
    );

    try mapRegion(
        kernel_root_page_table,
        virtual_range,
        physical_range,
        map_type,
    );
}

pub const MapType = struct {
    user: bool = false,
    global: bool = false,
    writeable: bool = false,
    executable: bool = false,
    no_cache: bool = false,

    // pub fn apply(self: MapType, entry: *PageTable.Entry) void {
    //     entry.present.write(true);

    //     if (self.user) {
    //         entry.user_accessible.write(true);
    //     }

    //     if (self.global) {
    //         entry.global.write(true);
    //     }

    //     if (!self.executable and kernel.info.execute_disable) entry.no_execute.write(true);

    //     if (self.writeable) entry.writeable.write(true);

    //     if (self.no_cache) {
    //         entry.no_cache.write(true);
    //         entry.write_through.write(true);
    //     }
    // }

    // pub fn applyParent(self: MapType, entry: *PageTable.Entry) void {
    //     entry.present.write(true);
    //     entry.writeable.write(true);
    //     if (self.user) entry.user_accessible.write(true);
    // }
};

pub const MapToError = error{
    AlreadyMapped,
    AllocationFailed,
    Unexpected,
};

pub const PageSize = struct {
    size: core.Size,

    mapTo: fn (
        page_table: *PageTable,
        virtual_addr: arch.VirtAddr,
        physical_addr: arch.PhysAddr,
        map_type: MapType,
    ) MapToError!void,
};

pub fn mapRegion(
    page_table: *PageTable,
    virtual_range: arch.VirtRange,
    physical_range: arch.PhysRange,
    map_type: MapType,
) !void {
    std.debug.assert(virtual_range.addr.isAligned(arch.paging.smallest_page_size));
    std.debug.assert(virtual_range.size.isAligned(arch.paging.smallest_page_size));
    std.debug.assert(physical_range.addr.isAligned(arch.paging.smallest_page_size));
    std.debug.assert(physical_range.size.isAligned(arch.paging.smallest_page_size));
    std.debug.assert(virtual_range.size.equal(virtual_range.size));

    log.debug(
        "mapping: {} to {} with type: {}",
        .{ virtual_range, physical_range, map_type },
    );

    return kernel.arch.paging.mapRegion(
        page_table,
        virtual_range,
        physical_range,
        map_type,
    );
}
