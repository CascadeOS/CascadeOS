// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const limine = @import("limine.zig");

// TODO: Support more than just limine.
//       Multiboot, etc.

/// Entry point.
export fn _start() callconv(.Naked) noreturn {
    @call(.never_inline, kernel.setup.setup, .{});
    core.panic("setup returned");
}

const log = kernel.log.scoped(.boot);

pub fn captureBootloaderInformation() void {
    if (hhdm.response) |resp| {
        captureHHDMs(resp.offset);
    } else {
        core.panic("bootloader did not provide the start of the HHDM");
    }
    if (kernel_address.response) |resp| {
        const kernel_virtual = resp.virtual_base;
        const kernel_physical = resp.physical_base;
        kernel.info.kernel_slide = core.Size.from(kernel_virtual - kernel_physical, .byte);
        log.debug("kernel virtual: 0x{x:0>16}", .{kernel_virtual});
        log.debug("kernel physical: 0x{x:0>16}", .{kernel_physical});
        log.debug("kernel slide: 0x{x:0>16}", .{kernel.info.kernel_slide});
    } else {
        // TODO: Maybe we should just allow the slide to be 0 in this case?
        core.panic("bootloader did not respond with kernel address");
    }
}

var hhdm: limine.HHDM = .{};

fn captureHHDMs(hhdm_offset: u64) void {
    const hhdm_start = kernel.VirtAddr.fromInt(hhdm_offset);

    if (!hhdm_start.isAligned(kernel.arch.paging.smallest_page_size)) {
        core.panic("HHDM is not aligned to the smallest page size");
    }

    const length_of_hhdm = calculateLengthOfHHDM();

    const hhdm_range = kernel.VirtRange.fromAddr(hhdm_start, length_of_hhdm);

    // Ensure that the non-cached HHDM does not go below the higher half
    var non_cached_hhdm = hhdm_range;
    non_cached_hhdm.moveBackwardInPlace(length_of_hhdm);
    if (non_cached_hhdm.addr.lessThan(kernel.arch.paging.higher_half)) {
        non_cached_hhdm = hhdm_range.moveForward(length_of_hhdm);
    }

    kernel.info.hhdm = hhdm_range;
    log.debug("hhdm: {}", .{hhdm_range});

    kernel.info.non_cached_hhdm = non_cached_hhdm;
    log.debug("non-cached hhdm: {}", .{non_cached_hhdm});
}

fn calculateLengthOfHHDM() core.Size {
    var reverse_memmap_iterator = memoryMapIterator(.backwards);

    while (reverse_memmap_iterator.next()) |entry| {
        if (entry.type == .reserved_or_unusable) continue;

        var size = core.Size.from(entry.range.end().value, .byte);

        // We choose to align the length of the HHDM to `largest_page_size` to allow large pages to be used for the mapping.
        size = size.alignForward(kernel.arch.paging.largest_page_size);

        // We ensure the lowest 4GiB are always identity mapped as it is possible that things like the PCI bus are
        // above the maximum range of the memory map.
        const four_gib = core.Size.from(4, .gib);
        if (size.lessThan(four_gib)) {
            size = four_gib;
        }

        return size;
    }

    core.panic("no non-reserved or usable memory regions?");
}

export var kernel_address: limine.KernelAddress = .{};

export var memmap: limine.Memmap = .{};

pub fn memoryMapIterator(direction: Direction) MemoryMapIterator {
    return .{
        .limine = .{
            .index = 0,
            .memmap = memmap.response orelse core.panic("no memory map from the bootloader"),
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
        const limine_entry = self.memmap.getEntry(self.index) orelse return null;

        switch (self.direction) {
            .forwards => self.index += 1,
            .backwards => {
                if (self.index != 0) self.index -= 1;
            },
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
