// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const limine = @import("limine");

export fn _start() callconv(.C) noreturn {
    @call(.never_inline, @import("init.zig").initStage1, .{}) catch |err| {
        core.panicFmt("unhandled error: {s}", .{@errorName(err)});
    };
    core.panic("`init.initStage1` returned");
}

pub const KernelBaseAddress = struct {
    virtual: core.VirtualAddress,
    physical: core.PhysicalAddress,
};

/// Returns the kernel virtual and physical base addresses provided by the bootloader, if any.
pub fn kernelBaseAddress() ?KernelBaseAddress {
    if (limine_requests.kernel_address.response) |resp| {
        return .{
            .virtual = resp.virtual_base,
            .physical = resp.physical_base,
        };
    }
    return null;
}

/// Returns the direct map address provided by the bootloader, if any.
pub fn directMapAddress() ?core.VirtualAddress {
    if (limine_requests.hhdm.response) |resp| {
        return resp.offset;
    }
    return null;
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
        reserved,
        reclaimable,
        unusable,
    };

    pub fn print(entry: MemoryMapEntry, writer: std.io.AnyWriter, indent: usize) !void {
        try writer.writeAll("MemoryMapEntry - ");

        try writer.writeAll(@tagName(entry.type));

        try writer.writeAll(" - ");

        try entry.range.print(writer, indent);
    }

    pub inline fn format(
        value: MemoryMapEntry,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        _ = fmt;
        return if (@TypeOf(writer) == std.io.AnyWriter)
            print(value, writer, 0)
        else
            print(value, writer.any(), 0);
    }

    fn __helpZls() void {
        MemoryMapEntry.print(undefined, @as(std.fs.File.Writer, undefined), 0);
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
                .reserved, .acpi_nvs => .reserved,
                .acpi_reclaimable, .bootloader_reclaimable => .reclaimable,
                .bad_memory => .unusable,
                else => .unusable,
            },
        };
    }
};

const limine_requests = struct {
    export var limine_revison: limine.BaseRevison = .{ .revison = 1 };
    export var kernel_address: limine.KernelAddress = .{};
    export var hhdm: limine.HHDM = .{};
    export var memmap: limine.Memmap = .{};
};

comptime {
    _ = &limine_requests;
}
