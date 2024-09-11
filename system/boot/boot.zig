// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

/// Exports bootloader entry points.
///
/// Required to be called at comptime from the kernels root file 'system/root.zig'.
pub fn exportEntryPoints() void {
    comptime {
        // export a fallback entry point for unknown bootloaders
        @export(&arch.init.unknownBootloaderEntryPoint, .{ .name = "_start" });

        // ensure the limine requests are exported
        _ = &limine_requests;
    }
}

pub const KernelBaseAddress = struct {
    virtual: core.VirtualAddress,
    physical: core.PhysicalAddress,
};

/// Returns the kernel virtual and physical base addresses provided by the bootloader, if any.
pub fn kernelBaseAddress() ?KernelBaseAddress {
    switch (bootloader_api) {
        .limine => if (limine_requests.kernel_address.response) |resp| {
            return .{
                .virtual = resp.virtual_base,
                .physical = resp.physical_base,
            };
        },
        .unknown => {},
    }

    return null;
}

/// Returns the direct map address provided by the bootloader, if any.
pub fn directMapAddress() ?core.VirtualAddress {
    switch (bootloader_api) {
        .limine => if (limine_requests.hhdm.response) |resp| {
            return resp.offset;
        },
        .unknown => {},
    }

    return null;
}

/// Returns an iterator over the memory map entries, iterating in the given direction.
pub fn memoryMap(direction: core.Direction) ?MemoryMapIterator {
    switch (bootloader_api) {
        .limine => if (limine_requests.memmap.response) |resp| {
            const entries = resp.entries();
            return .{
                .limine = .{
                    .index = switch (direction) {
                        .forward => 0,
                        .backward => entries.len,
                    },
                    .entries = entries,
                    .direction = direction,
                },
            };
        },
        .unknown => {},
    }

    return null;
}

/// An entry in the memory map provided by the bootloader.
pub const MemoryMapEntry = struct {
    range: core.PhysicalRange,
    type: Type,

    pub const Type = enum {
        free,
        in_use,
        reserved,
        bootloader_reclaimable,
        acpi_reclaimable,
        unusable,

        unknown,
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

/// Returns the ACPI RSDP address provided by the bootloader, if any.
pub fn rsdp() ?core.VirtualAddress {
    switch (bootloader_api) {
        .limine => if (limine_requests.rsdp.response) |resp| {
            return resp.address;
        },
        .unknown => {},
    }

    return null;
}

fn limineEntryPoint() callconv(.C) noreturn {
    bootloader_api = .limine;
    @call(.never_inline, @import("root").initEntryPoint, .{}) catch |err| {
        core.panicFmt("unhandled error: {s}", .{@errorName(err)}, @errorReturnTrace());
    };
    core.panic("`init.initStage1` returned", null);
}

const LimineMemoryMapIterator = struct {
    index: usize,
    entries: []const *const limine.Memmap.Entry,
    direction: core.Direction,

    pub fn next(self: *LimineMemoryMapIterator) ?MemoryMapEntry {
        const limine_entry = switch (self.direction) {
            .backward => blk: {
                if (self.index == 0) return null;
                self.index -= 1;
                break :blk self.entries[self.index];
            },
            .forward => blk: {
                if (self.index >= self.entries.len) return null;
                const entry = self.entries[self.index];
                self.index += 1;
                break :blk entry;
            },
        };

        return .{
            .range = .fromAddr(limine_entry.base, limine_entry.length),
            .type = switch (limine_entry.type) {
                .usable => .free,
                .kernel_and_modules, .framebuffer => .in_use,
                .reserved, .acpi_nvs => .reserved,
                .bootloader_reclaimable => .bootloader_reclaimable,
                .acpi_reclaimable => .acpi_reclaimable,
                .bad_memory => .unusable,
                else => .unknown,
            },
        };
    }
};

const limine_requests = struct {
    export var limine_revison: limine.BaseRevison = .{ .revison = 2 };
    export var entry_point: limine.EntryPoint = .{ .entry = limineEntryPoint };
    export var kernel_address: limine.KernelAddress = .{};
    export var hhdm: limine.HHDM = .{};
    export var memmap: limine.Memmap = .{};
    export var rsdp: limine.RSDP = .{};
};

var bootloader_api: BootloaderAPI = .unknown;

const BootloaderAPI = enum {
    unknown,
    limine,
};

const std = @import("std");
const core = @import("core");
const limine = @import("limine");
const arch = @import("arch");
