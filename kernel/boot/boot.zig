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

pub fn kernelAddress() ?KernelAddress {
    if (limine_requests.kernel_address.response) |resp| {
        return .{
            .virtual = resp.virtual_base,
            .physical = resp.physical_base,
        };
    }
    return null;
}

pub fn kernelFile() ?[]const u8 {
    if (limine_requests.kernel_file.response) |resp| {
        return resp.kernel_file.getContents();
    }
    return null;
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

    const length_of_longest_tag = blk: {
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
                .width = length_of_longest_tag,
            },
            writer,
        );

        try writer.writeAll(" - ");

        try entry.range.print(writer);
    }

    pub fn format(
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
