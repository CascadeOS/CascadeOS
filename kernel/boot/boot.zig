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

const limine_requests = struct {
    export var kernel_file: limine.KernelFile = .{};
    export var hhdm: limine.HHDM = .{};
    export var kernel_address: limine.KernelAddress = .{};
    export var memmap: limine.Memmap = .{};
};

/// Returns the direct map address provided by the bootloader, if any.
pub fn directMapAddress() ?u64 {
    if (limine_requests.hhdm.response) |resp| {
        return resp.offset;
    }
    return null;
}

pub const KernelAddress = struct {
    virtual: u64,
    physical: u64,
};

/// Returns the kernel virtual and physical addresses provided by the bootloader, if any.
pub fn kernelAddress() ?KernelAddress {
    if (limine_requests.kernel_address.response) |resp| {
        return .{
            .virtual = resp.virtual_base,
            .physical = resp.physical_base,
        };
    }
    return null;
}

/// Returns the kernel file contents as a VirtualRange, if provided by the bootloader.
pub fn kernelFile() ?kernel.VirtualRange {
    if (limine_requests.kernel_file.response) |resp| {
        return kernel.VirtualRange.fromSlice(resp.kernel_file.getContents());
    }
    return null;
}

/// Returns an iterator over the memory map entries, iterating in the given direction.
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

/// An iterator over the memory map entries provided by the bootloader.
pub const MemoryMapIterator = union(enum) {
    limine: LimineMemoryMapIterator,

    /// Returns the next memory map entry from the iterator, if any remain.
    pub fn next(self: *MemoryMapIterator) ?MemoryMapEntry {
        return switch (self.*) {
            inline else => |*i| i.next(),
        };
    }
};

/// An entry in the memory map provided by the bootloader.
pub const MemoryMapEntry = struct {
    range: kernel.PhysicalRange,
    type: Type,

    pub const Type = enum {
        free,
        in_use,
        reserved_or_unusable,
        reclaimable,
    };

    /// The length of the longest tag name in the `MemoryMapEntry.Type` enum.
    const length_of_longest_tag_name = blk: {
        var longest_so_far = 0;
        inline for (std.meta.tags(Type)) |tag| {
            const length = @tagName(tag).len;
            if (length > longest_so_far) longest_so_far = length;
        }
        break :blk longest_so_far;
    };

    pub fn print(entry: MemoryMapEntry, writer: anytype) !void {
        try writer.writeAll("MemoryMapEntry - ");

        try std.fmt.formatBuf(
            @tagName(entry.type),
            .{
                .alignment = .left,
                .width = length_of_longest_tag_name,
            },
            writer,
        );

        try writer.writeAll(" - ");

        try entry.range.print(writer);
    }

    pub inline fn format(
        entry: MemoryMapEntry,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        _ = fmt;
        return print(entry, writer);
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
            .range = kernel.PhysicalRange.fromAddr(
                kernel.PhysicalAddress.fromInt(limine_entry.base),
                core.Size.from(limine_entry.length, .byte),
            ),
            .type = switch (limine_entry.memmap_type) {
                .usable => .free,
                .kernel_and_modules, .framebuffer => .in_use,
                .reserved, .bad_memory, .acpi_nvs => .reserved_or_unusable,
                .acpi_reclaimable, .bootloader_reclaimable => .reclaimable,
                _ => .reserved_or_unusable,
            },
        };
    }
};
