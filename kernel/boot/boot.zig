// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

/// Returns the kernel virtual and physical base addresses provided by the bootloader, if any.
pub fn kernelBaseAddress() ?KernelBaseAddress {
    return switch (bootloader_api) {
        .limine => limine.kernelBaseAddress(),
        .unknown => null,
    };
}

pub const KernelBaseAddress = struct {
    virtual: core.VirtualAddress,
    physical: core.PhysicalAddress,
};

/// Returns an iterator over the memory map entries, iterating in the given direction.
pub fn memoryMap(direction: core.Direction) ?MemoryMap {
    return switch (bootloader_api) {
        .limine => limine.memoryMap(direction),
        .unknown => null,
    };
}

pub const MemoryMap = struct {
    backing: [backing_size]u8 align(backing_align),

    pub fn next(self: *MemoryMap) ?Entry {
        while (true) {
            const entry = switch (bootloader_api) {
                .limine => limine.MemoryMapIterator.next(self),
                .unknown => null,
            } orelse
                return null;

            if (entry.range.address.equal(.fromInt(0xfd00000000))) {
                // this is a qemu specific hack to not have a 1TiB direct map
                // this `0xfd00000000` memory region is not listed in qemu's `info mtree` but the bootloader reports it
                continue;
            }

            return entry;
        }
    }

    /// An entry in the memory map provided by the bootloader.
    pub const Entry = struct {
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

        pub fn print(entry: Entry, writer: std.io.AnyWriter, indent: usize) !void {
            try writer.writeAll("Entry - ");

            try writer.writeAll(@tagName(entry.type));

            try writer.writeAll(" - ");

            try entry.range.print(writer, indent);
        }

        pub inline fn format(
            value: Entry,
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
            Entry.print(undefined, @as(std.fs.File.Writer, undefined), 0);
        }
    };

    const backing_size: usize = @max(
        @sizeOf(limine.MemoryMapIterator),
        0,
    );

    const backing_align: usize = @max(
        @alignOf(limine.MemoryMapIterator),
        0,
    );
};

/// Exports bootloader entry points and any other required exported symbols.
///
/// Required to be called at comptime from the kernels root file 'kernel/kernel.zig'.
pub fn exportEntryPoints() void {
    const unknownBootloaderEntryPoint = struct {
        /// The entry point that is exported as `_start` and acts as fallback entry point for unknown bootloaders.
        ///
        /// No bootloader is ever expected to call `_start` and instead should use bootloader specific entry points;
        /// meaning this function is not expected to ever be called.
        pub fn unknownBootloaderEntryPoint() callconv(.Naked) noreturn {
            @call(.always_inline, kernel.arch.interrupts.disableInterruptsAndHalt, .{});
            unreachable;
        }
    }.unknownBootloaderEntryPoint;

    comptime {
        @export(&unknownBootloaderEntryPoint, .{ .name = "_start" });
        limine.exportRequests();
    }
}

pub var bootloader_api: BootloaderAPI = .unknown;

pub const BootloaderAPI = enum {
    unknown,
    limine,
};

const std = @import("std");
const kernel = @import("../kernel.zig");
const limine = @import("limine.zig");
