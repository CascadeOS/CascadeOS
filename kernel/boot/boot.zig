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
    range: kernel.arch.PhysRange,
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
                .alignment = .Left,
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
            .range = kernel.arch.PhysRange.fromAddr(
                kernel.arch.PhysAddr.fromInt(limine_entry.base),
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
