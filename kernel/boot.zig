// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const limine = @import("limine");

export fn _start() callconv(.C) noreturn {
    @call(.never_inline, @import("init.zig").kernelInit, .{}) catch |err| {
        core.panicFmt("unhandled error: {s}", .{@errorName(err)});
    };
    core.panic("`init.kernelInit` returned");
}

/// Returns an iterator over the memory map entries, iterating in the given direction.
pub fn memoryMap(direction: Direction) MemoryMapIterator {
    const memmap_response = limine_requests.memmap.response orelse core.panic("no memory map from the bootloader");
    const entries = memmap_response.entries();
    return .{
        .limine = .{
            .index = switch (direction) {
                .forwards => 0,
                .backwards => entries.len,
            },
            .entries = entries,
            .direction = direction,
        },
    };
}

/// An entry in the memory map provided by the bootloader.
pub const MemoryMapEntry = struct {
    range: core.PhysicalRange,
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
        for (std.meta.tags(Type)) |tag| {
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

pub const Direction = enum {
    forwards,
    backwards,
};

const LimineMemoryMapIterator = struct {
    index: usize,
    entries: []const *const limine.Memmap.Entry,
    direction: Direction,

    pub fn next(self: *LimineMemoryMapIterator) ?MemoryMapEntry {
        const limine_entry = switch (self.direction) {
            .backwards => blk: {
                if (self.index == 0) return null;
                self.index -= 1;
                break :blk self.entries[self.index];
            },
            .forwards => blk: {
                if (self.index >= self.entries.len) return null;
                const entry = self.entries[self.index];
                self.index += 1;
                break :blk entry;
            },
        };

        return .{
            .range = core.PhysicalRange.fromAddr(limine_entry.base, limine_entry.length),
            .type = switch (limine_entry.type) {
                .usable => .free,
                .kernel_and_modules, .framebuffer => .in_use,
                .reserved, .bad_memory, .acpi_nvs => .reserved_or_unusable,
                .acpi_reclaimable, .bootloader_reclaimable => .reclaimable,
                _ => .reserved_or_unusable,
            },
        };
    }
};

const limine_requests = struct {
    export var limine_revison: limine.BaseRevison = .{ .revison = 1 };
    export var memmap: limine.Memmap = .{};
};

comptime {
    _ = &limine_requests;
}
