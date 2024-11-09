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
pub fn memoryMap(direction: core.Direction) ?MemoryMapEntry.Iterator {
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

    /// An iterator over the memory map entries provided by the bootloader.
    pub const Iterator = union(enum) {
        limine: LimineMemoryMapIterator,

        /// Returns the next memory map entry from the iterator, if any remain.
        pub fn next(self: *Iterator) ?MemoryMapEntry {
            while (true) {
                const opt_entry = switch (self.*) {
                    inline else => |*i| i.next(),
                };

                if (opt_entry) |entry| {
                    if (entry.range.address.equal(core.PhysicalAddress.fromInt(0x000000fd00000000))) {
                        // this is a qemu specific hack to not have a 1TiB direct map
                        // this `0xfd00000000` memory region is not listed in qemu's `info mtree` but the bootloader reports it
                        continue;
                    }
                }

                return opt_entry;
            }
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
    };
};

/// Returns the ACPI RSDP address provided by the bootloader, if any.
pub fn rsdp() ?core.Address {
    switch (bootloader_api) {
        .limine => if (limine_requests.rsdp.response) |resp| {
            return resp.address(limine_requests.limine_revison);
        },
        .unknown => {},
    }

    return null;
}

pub fn cpuDescriptors() ?CpuDescriptor.Iterator {
    switch (bootloader_api) {
        .limine => if (limine_requests.smp.response) |resp| {
            const entries = resp.cpus();
            return .{
                .limine = .{
                    .index = 0,
                    .entries = entries,
                },
            };
        },
        .unknown => {},
    }

    return null;
}

pub const CpuDescriptor = struct {
    _raw: Raw,

    pub fn boot(
        self: CpuDescriptor,
        user_data: *anyopaque,
        comptime targetFn: fn (user_data: *anyopaque) noreturn,
    ) void {
        switch (self._raw) {
            .limine => |limine_info| {
                const trampolineFn = struct {
                    fn trampolineFn(smp_info: *const limine.SMP.Response.SMPInfo) callconv(.C) noreturn {
                        targetFn(@ptrFromInt(smp_info.extra_argument));
                    }
                }.trampolineFn;

                @atomicStore(
                    usize,
                    &limine_info.extra_argument,
                    @intFromPtr(user_data),
                    .release,
                );

                @atomicStore(
                    ?*const fn (*const limine.SMP.Response.SMPInfo) callconv(.C) noreturn,
                    &limine_info.goto_address,
                    &trampolineFn,
                    .release,
                );
            },
        }
    }

    pub fn processorId(self: CpuDescriptor) u32 {
        return switch (self._raw) {
            .limine => |limine_info| limine_info.processor_id,
        };
    }

    pub const Raw = union(enum) {
        limine: *limine.SMP.Response.SMPInfo,
    };

    /// An iterator over the cpu descriptors provided by the bootloader.
    pub const Iterator = union(enum) {
        limine: LimineCpuDescriptorIterator,

        pub fn count(self: Iterator) usize {
            return switch (self) {
                inline else => |i| i.count(),
            };
        }

        /// Returns the next cpu descriptor from the iterator, if any remain.
        pub fn next(self: *Iterator) ?CpuDescriptor {
            return switch (self.*) {
                inline else => |*i| i.next(),
            };
        }

        const LimineCpuDescriptorIterator = struct {
            index: usize,
            entries: []*limine.SMP.Response.SMPInfo,

            pub fn count(self: LimineCpuDescriptorIterator) usize {
                return self.entries.len;
            }

            pub fn next(self: *LimineCpuDescriptorIterator) ?CpuDescriptor {
                if (self.index >= self.entries.len) return null;

                const smp_info = self.entries[self.index];

                self.index += 1;

                return .{
                    ._raw = .{ .limine = smp_info },
                };
            }
        };
    };
};

pub fn x2apicEnabled() bool {
    if (@import("cascade_target").arch != .x64) @compileError("x2apicEnabled can only be called on x64");

    switch (bootloader_api) {
        .limine => {
            const smp_response = limine_requests.smp.response orelse return false;
            return smp_response.flags.x2apic_enabled;
        },
        .unknown => return false,
    }
}

fn limineEntryPoint() callconv(.C) noreturn {
    bootloader_api = .limine;
    if (limine_requests.limine_base_revison.revison == .@"0") {
        // limine sets the `revison` field to `0` to signal that the requested revision is supported
        limine_requests.limine_revison = limine_requests.target_limine_revison;
    }

    @call(.never_inline, @import("root").initEntryPoint, .{}) catch |err| {
        core.panicFmt("unhandled error: {s}", .{@errorName(err)}, @errorReturnTrace());
    };
    core.panic("`init.initStage1` returned", null);
}

const limine_requests = struct {
    // TODO: update to 3, needs annoying changes as things like the ACPI RSDP are not mapped in the
    //       HHDM from that revision onwards
    const target_limine_revison: limine.BaseRevison.Revison = .@"2";
    var limine_revison: limine.BaseRevison.Revison = .@"0";

    export var limine_base_revison: limine.BaseRevison = .{ .revison = target_limine_revison };
    export var entry_point: limine.EntryPoint = .{ .entry = limineEntryPoint };
    export var kernel_address: limine.KernelAddress = .{};
    export var hhdm: limine.HHDM = .{};
    export var memmap: limine.Memmap = .{};
    export var rsdp: limine.RSDP = .{};
    export var smp: limine.SMP = .{ .flags = .{ .x2apic = true } };
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
