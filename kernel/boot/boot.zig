// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");

const limine = @import("limine");

export fn _start() linksection(kernel.info.init_code) noreturn {
    core.panic("bare _start function called");
}

/// Limine Entry point.
export fn limineEntryPoint() linksection(kernel.info.init_code) callconv(.C) noreturn {
    @call(.never_inline, kernel.init.kernelInitStage1, .{});
    core.panic("kernelInitStage1 returned");
}

const limine_requests = struct {
    // TODO: setting this to 1 causes aarch64 to hang at "limine: Loading kernel `boot:///kernel`..."
    export var limine_revison: limine.BaseRevison linksection(kernel.info.init_data) = .{ .revison = 0 };
    export var kernel_file: limine.KernelFile linksection(kernel.info.init_data) = .{};
    export var hhdm: limine.HHDM linksection(kernel.info.init_data) = .{};
    export var kernel_address: limine.KernelAddress linksection(kernel.info.init_data) = .{};
    export var memmap: limine.Memmap linksection(kernel.info.init_data) = .{};
    export var smp: limine.SMP linksection(kernel.info.init_data) = .{ .flags = .{ .x2apic = true } };
    export var rsdp: limine.RSDP linksection(kernel.info.init_data) = .{};
    export var entry_point: limine.EntryPoint linksection(kernel.info.init_data) = .{ .entry = &limineEntryPoint };
};

comptime {
    _ = &limine_requests;
}

/// Returns the ACPI RSDP address provided by the bootloader, if any.
pub fn rsdp() linksection(kernel.info.init_code) ?core.VirtualAddress {
    if (limine_requests.rsdp.response) |resp| {
        return resp.address;
    }
    return null;
}

/// Returns the direct map address provided by the bootloader, if any.
pub fn directMapAddress() linksection(kernel.info.init_code) ?core.VirtualAddress {
    if (limine_requests.hhdm.response) |resp| {
        return resp.offset;
    }
    return null;
}

pub const KernelBaseAddress = struct {
    virtual: core.VirtualAddress,
    physical: core.PhysicalAddress,
};

/// Returns the kernel virtual and physical base addresses provided by the bootloader, if any.
pub fn kernelBaseAddress() linksection(kernel.info.init_code) ?KernelBaseAddress {
    if (limine_requests.kernel_address.response) |resp| {
        return .{
            .virtual = resp.virtual_base,
            .physical = resp.physical_base,
        };
    }
    return null;
}

/// Returns the kernel file contents as a core.VirtualRange, if provided by the bootloader.
pub fn kernelFile() linksection(kernel.info.init_code) ?core.VirtualRange {
    if (limine_requests.kernel_file.response) |resp| {
        return core.VirtualRange.fromSlice(u8, resp.kernel_file.getContents());
    }
    return null;
}

pub fn x2apicEnabled() linksection(kernel.info.init_code) bool {
    if (kernel.info.arch != .x86_64) @compileError("x2apicEnabled can only be called on x86_64");

    const smp_response = limine_requests.smp.response orelse return false;
    return smp_response.flags.x2apic_enabled;
}

pub fn processorDescriptors() linksection(kernel.info.init_code) ProcessorDescriptorIterator {
    const smp_response = limine_requests.smp.response orelse core.panic("no processor descriptors from the bootloader");
    const entries = smp_response.cpus();
    return .{
        .limine = .{
            .index = 0,
            .entries = entries,
        },
    };
}

pub const ProcessorDescriptor = struct {
    _raw: Raw,

    pub fn boot(
        self: ProcessorDescriptor,
        processor: *kernel.Processor,
        comptime targetFn: fn (processor: *kernel.Processor) noreturn,
    ) linksection(kernel.info.init_code) void {
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
                    @intFromPtr(processor),
                    .Release,
                );

                @atomicStore(
                    ?*const fn (*const limine.SMP.Response.SMPInfo) callconv(.C) noreturn,
                    &limine_info.goto_address,
                    &trampolineFn,
                    .Release,
                );
            },
        }
    }

    pub fn acpiId(self: ProcessorDescriptor) linksection(kernel.info.init_code) u32 {
        return switch (self._raw) {
            .limine => |limine_info| limine_info.processor_id,
        };
    }

    pub fn lapicId(self: ProcessorDescriptor) linksection(kernel.info.init_code) u32 {
        if (kernel.info.arch != .x86_64) @compileError("apicId can only be called on x86_64");

        return switch (self._raw) {
            .limine => |limine_info| limine_info.lapic_id,
        };
    }

    pub const Raw = union(enum) {
        limine: *limine.SMP.Response.SMPInfo,
    };
};

/// An iterator over the processor descriptors provided by the bootloader.
pub const ProcessorDescriptorIterator = union(enum) {
    limine: LimineProcessorDescriptorIterator,

    pub fn count(self: ProcessorDescriptorIterator) linksection(kernel.info.init_code) usize {
        return switch (self) {
            inline else => |i| i.count(),
        };
    }

    /// Returns the next processor descriptor from the iterator, if any remain.
    pub fn next(self: *ProcessorDescriptorIterator) linksection(kernel.info.init_code) ?ProcessorDescriptor {
        return switch (self.*) {
            inline else => |*i| i.next(),
        };
    }
};

const LimineProcessorDescriptorIterator = struct {
    index: usize,
    entries: []*limine.SMP.Response.SMPInfo,

    pub fn count(self: LimineProcessorDescriptorIterator) linksection(kernel.info.init_code) usize {
        return self.entries.len;
    }

    pub fn next(self: *LimineProcessorDescriptorIterator) linksection(kernel.info.init_code) ?ProcessorDescriptor {
        if (self.index >= self.entries.len) return null;

        const smp_info = self.entries[self.index];

        self.index += 1;

        return .{
            ._raw = .{ .limine = smp_info },
        };
    }
};

/// Returns an iterator over the memory map entries, iterating in the given direction.
pub fn memoryMap(direction: Direction) linksection(kernel.info.init_code) MemoryMapIterator {
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

/// An iterator over the memory map entries provided by the bootloader.
pub const MemoryMapIterator = union(enum) {
    limine: LimineMemoryMapIterator,

    /// Returns the next memory map entry from the iterator, if any remain.
    pub fn next(self: *MemoryMapIterator) linksection(kernel.info.init_code) ?MemoryMapEntry {
        return switch (self.*) {
            inline else => |*i| i.next(),
        };
    }
};

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

    pub fn print(entry: MemoryMapEntry, writer: anytype) linksection(kernel.info.init_code) !void {
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
    entries: []const *const limine.Memmap.Entry,
    direction: Direction,

    pub fn next(self: *LimineMemoryMapIterator) linksection(kernel.info.init_code) ?MemoryMapEntry {
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
