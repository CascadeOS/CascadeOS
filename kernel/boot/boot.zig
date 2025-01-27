// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>

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

/// Returns the direct map address provided by the bootloader, if any.
pub fn directMapAddress() ?core.VirtualAddress {
    return switch (bootloader_api) {
        .limine => limine.directMapAddress(),
        .unknown => null,
    };
}

/// Returns the ACPI RSDP address provided by the bootloader, if any.
pub fn rsdp() ?core.Address {
    return switch (bootloader_api) {
        .limine => limine.rsdp(),
        .unknown => null,
    };
}

pub fn x2apicEnabled() bool {
    if (kernel.config.cascade_target != .x64) {
        @compileError("x2apicEnabled can only be called on x64");
    }

    return switch (bootloader_api) {
        .limine => limine.x2apicEnabled(),
        .unknown => return false,
    };
}

pub fn cpuDescriptors() ?CpuDescriptors {
    return switch (bootloader_api) {
        .limine => limine.cpuDescriptors(),
        .unknown => null,
    };
}

pub const CpuDescriptors = struct {
    backing: [descriptors_backing_size]u8 align(descriptors_backing_align),

    pub fn count(self: *const CpuDescriptors) usize {
        return switch (bootloader_api) {
            .limine => limine.CpuDescriptorIterator.count(self),
            .unknown => 0,
        };
    }

    /// Returns the next cpu descriptor from the iterator, if any remain.
    pub fn next(self: *CpuDescriptors) ?Descriptor {
        return switch (bootloader_api) {
            .limine => limine.CpuDescriptorIterator.next(self),
            .unknown => null,
        };
    }

    pub const Descriptor = struct {
        backing: [descriptor_backing_size]u8 align(descriptor_backing_align),

        pub fn boot(
            self: *const Descriptor,
            user_data: *anyopaque,
            target_fn: fn (user_data: *anyopaque) noreturn,
        ) void {
            switch (bootloader_api) {
                .limine => limine.CpuDescriptorIterator.bootFn(self, user_data, target_fn),
                .unknown => unreachable,
            }
        }

        pub fn processorId(self: *const Descriptor) u32 {
            return switch (bootloader_api) {
                .limine => limine.CpuDescriptorIterator.processorId(self),
                .unknown => unreachable,
            };
        }

        const descriptor_backing_size: usize = @max(
            @sizeOf(limine.CpuDescriptorIterator.Descriptor),
            0,
        );

        const descriptor_backing_align: usize = @max(
            @alignOf(limine.CpuDescriptorIterator.Descriptor),
            0,
        );
    };

    const descriptors_backing_size: usize = @max(
        @sizeOf(limine.CpuDescriptorIterator),
        0,
    );

    const descriptors_backing_align: usize = @max(
        @alignOf(limine.CpuDescriptorIterator),
        0,
    );
};

/// Each pixel of the framebuffer is a 32-bit RGB value (0x00RRGGBB).
pub const Framebuffer = struct {
    ptr: [*]volatile u32,
    /// Width of the framebuffer in pixels
    width: u64,
    /// Height of the framebuffer in pixels
    height: u64,
    /// Pixels per row (pitch / @sizeOf(u32))
    pixels_per_row: u64,
};

/// Returns the framebuffer provided by the bootloader, if any.
pub fn framebuffer() ?Framebuffer {
    return switch (bootloader_api) {
        .limine => limine.framebuffer(),
        .unknown => null,
    };
}

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
const kernel = @import("kernel");
const limine = @import("limine.zig");
const core = @import("core");
