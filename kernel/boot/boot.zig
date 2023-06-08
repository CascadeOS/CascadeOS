// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const limine = @import("limine.zig");

// TODO: Support more than just limine. https://github.com/CascadeOS/CascadeOS/issues/35
//       Multiboot, etc.

/// Entry point.
export fn _start() callconv(.Naked) noreturn {
    @call(.never_inline, kernel.setup.setup, .{});
    core.panic("setup returned");
}

const log = kernel.log.scoped(.boot);

pub fn captureBootloaderInformation() void {
    if (limine_requests.hhdm.response) |resp| {
        captureHHDM(resp.offset);
    } else {
        core.panic("bootloader did not provide the start of the HHDM");
    }
    if (limine_requests.kernel_address.response) |resp| {
        const kernel_virtual = resp.virtual_base;
        const kernel_physical = resp.physical_base;
        kernel.info.kernel_offset_from_base = core.Size.from(kernel_virtual - kernel.info.kernel_base_address.value, .byte);
        kernel.info.kernel_offset_from_physical = core.Size.from(kernel_virtual - kernel_physical, .byte);
        log.debug("kernel virtual: 0x{x:0>16}", .{kernel_virtual});
        log.debug("kernel physical: 0x{x:0>16}", .{kernel_physical});
        log.debug("kernel offset from base: 0x{x}", .{kernel.info.kernel_offset_from_base.bytes});
        log.debug("kernel offset from physical: 0x{x}", .{kernel.info.kernel_offset_from_physical.bytes});
    } else {
        // TODO: We should calculate the kernel slide from the the active page table.
        // https://github.com/CascadeOS/CascadeOS/issues/36
        core.panic("bootloader did not respond with kernel address");
    }
    if (limine_requests.kernel_file.response) |resp| {
        kernel.info.kernel_file = resp.kernel_file.getContents();
        log.debug("kernel file: {} - {}", .{
            kernel.VirtAddr.fromPtr(resp.kernel_file.address),
            core.Size.from(resp.kernel_file.size, .byte),
        });
    } else {
        log.warn("bootloader did not provide kernel ELF file location", .{});
    }
}

const limine_requests = struct {
    export var kernel_file: limine.KernelFile = .{};
    export var hhdm: limine.HHDM = .{};
    export var kernel_address: limine.KernelAddress = .{};
    export var memmap: limine.Memmap = .{};
};

fn captureHHDM(hhdm_offset: u64) void {
    const hhdm_start = kernel.VirtAddr.fromInt(hhdm_offset);

    if (!hhdm_start.isAligned(kernel.arch.paging.standard_page_size)) {
        core.panic("HHDM is not aligned to the standard page size");
    }

    const size_of_direct_map = calculateLengthOfDirectMap();

    const direct_map = kernel.VirtRange.fromAddr(hhdm_start, size_of_direct_map);

    // Ensure that the non-cached direct map does not go below the higher half
    var non_cached_direct_map = direct_map;
    non_cached_direct_map.moveBackwardInPlace(size_of_direct_map);
    if (non_cached_direct_map.addr.lessThan(kernel.arch.paging.higher_half)) {
        non_cached_direct_map = direct_map.moveForward(size_of_direct_map);
    }

    kernel.info.direct_map = direct_map;
    log.debug("direct map: {}", .{direct_map});

    kernel.info.non_cached_direct_map = non_cached_direct_map;
    log.debug("non-cached direct map: {}", .{non_cached_direct_map});
}

fn calculateLengthOfDirectMap() core.Size {
    var reverse_memmap_iterator = memoryMapIterator(.backwards);

    while (reverse_memmap_iterator.next()) |entry| {
        const estimated_size = core.Size.from(entry.range.end().value, .byte);

        log.debug("estimated size of direct map: {}", .{estimated_size});

        // We align the length of the direct map to `largest_page_size` to allow large pages to be used for the mapping.
        var aligned_size = estimated_size.alignForward(kernel.arch.paging.largest_page_size);

        // We ensure that the lowest 4GiB are always mapped.
        const @"4gib" = core.Size.from(4, .gib);
        if (aligned_size.lessThan(@"4gib")) aligned_size = @"4gib";

        log.debug("aligned size of direct map: {}", .{aligned_size});

        return aligned_size;
    }

    core.panic("no non-reserved or usable memory regions?");
}

pub fn memoryMapIterator(direction: Direction) MemoryMapIterator {
    const memmap_response = limine_requests.memmap.response orelse core.panic("no memory map from the bootloader");
    return .{
        .limine = .{
            .index = switch (direction) {
                .forwards => 0,
                .backwards => memmap_response.entry_count,
            },
            .memmap = memmap_response,
            .direction = direction,
        },
    };
}

pub const MemoryMapIterator = union(enum) {
    limine: LimineMemoryMapIterator,

    pub fn next(self: *MemoryMapIterator) ?MemoryMapEntry {
        return switch (self.*) {
            inline else => |*i| i.next(),
        };
    }
};

pub const MemoryMapEntry = struct {
    range: kernel.PhysRange,
    type: Type,

    pub const Type = enum {
        free,
        in_use,
        reserved_or_unusable,
        reclaimable,
    };

    pub fn format(
        entry: MemoryMapEntry,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        _ = fmt;

        try writer.writeAll("MemoryMapEntry - ");

        try std.fmt.formatBuf(
            @tagName(entry.type),
            .{
                .alignment = .left,
                .width = 20,
            },
            writer,
        );

        try writer.writeAll(" - ");

        try entry.range.format("", .{}, writer);
    }
};

pub const Direction = enum {
    forwards,
    backwards,
};

const LimineMemoryMapIterator = struct {
    index: usize,
    memmap: *const limine.Memmap.Response,
    direction: Direction,

    pub fn next(self: *LimineMemoryMapIterator) ?MemoryMapEntry {
        if (self.direction == .backwards) {
            if (self.index == 0) return null;
            self.index -= 1;
        }

        const limine_entry = self.memmap.getEntry(self.index) orelse return null;

        if (self.direction == .forwards) {
            self.index += 1;
        }

        return .{
            .range = kernel.PhysRange.fromAddr(
                kernel.PhysAddr.fromInt(limine_entry.base),
                core.Size.from(limine_entry.length, .byte),
            ),
            .type = switch (limine_entry.memmap_type) {
                .usable => .free,
                .kernel_and_modules, .framebuffer => .in_use,
                .reserved, .bad_memory, .acpi_nvs => .reserved_or_unusable,
                .acpi_reclaimable, .bootloader_reclaimable => .reclaimable,
            },
        };
    }
};
