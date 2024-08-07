// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const limine = @import("limine");

export fn _start() callconv(.C) noreturn {
    @call(.never_inline, @import("init.zig").initStage1, .{}) catch |err| {
        core.panicFmt("unhandled error: {s}", .{@errorName(err)}, @errorReturnTrace());
    };
    core.panic("`init.initStage1` returned", null);
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
pub fn memoryMap(direction: core.Direction) MemoryMapIterator {
    const memmap_response = limine_requests.memmap.response orelse core.panic("no memory map from the bootloader", null);
    const entries = memmap_response.entries();
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

/// Returns the ACPI RSDP address provided by the bootloader, if any.
pub fn rsdp() ?core.VirtualAddress {
    if (limine_requests.rsdp.response) |resp| {
        return resp.address;
    }
    return null;
}

pub fn x2apicEnabled() bool {
    if (kernel.arch.arch != .x64) @compileError("x2apicEnabled can only be called on x64");

    const smp_response = limine_requests.smp.response orelse return false;
    return smp_response.flags.x2apic_enabled;
}

pub fn cpuDescriptors() CpuDescriptorIterator {
    const smp_response = limine_requests.smp.response orelse core.panic("no cpu descriptors from the bootloader", null);
    const entries = smp_response.cpus();
    return .{
        .limine = .{
            .index = 0,
            .entries = entries,
        },
    };
}

pub const CpuDescriptor = struct {
    _raw: Raw,

    pub fn boot(
        self: CpuDescriptor,
        cpu: *kernel.Cpu,
        comptime targetFn: fn (cpu: *kernel.Cpu) noreturn,
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
                    @intFromPtr(cpu),
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

    pub fn acpiId(self: CpuDescriptor) u32 {
        return switch (self._raw) {
            .limine => |limine_info| limine_info.processor_id,
        };
    }

    pub fn lapicId(self: CpuDescriptor) u32 {
        if (kernel.arch.arch != .x64) @compileError("apicId can only be called on x64");

        return switch (self._raw) {
            .limine => |limine_info| limine_info.lapic_id,
        };
    }

    pub const Raw = union(enum) {
        limine: *limine.SMP.Response.SMPInfo,
    };
};

/// An iterator over the cpu descriptors provided by the bootloader.
pub const CpuDescriptorIterator = union(enum) {
    limine: LimineCpuDescriptorIterator,

    pub fn count(self: CpuDescriptorIterator) usize {
        return switch (self) {
            inline else => |i| i.count(),
        };
    }

    /// Returns the next cpu descriptor from the iterator, if any remain.
    pub fn next(self: *CpuDescriptorIterator) ?CpuDescriptor {
        return switch (self.*) {
            inline else => |*i| i.next(),
        };
    }
};

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

const limine_requests = struct {
    export var limine_revison: limine.BaseRevison = .{ .revison = 2 };
    export var kernel_address: limine.KernelAddress = .{};
    export var hhdm: limine.HHDM = .{};
    export var memmap: limine.Memmap = .{};
    export var rsdp: limine.RSDP = .{};
    export var smp: limine.SMP = .{ .flags = .{ .x2apic = true } };
};

comptime {
    _ = &limine_requests;
}
