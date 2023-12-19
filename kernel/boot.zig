// SPDX-License-Identifier: MIT

const core = @import("core");
const info = kernel.info;
const init = kernel.init;
const kernel = @import("kernel");
const PhysicalAddress = kernel.PhysicalAddress;
const PhysicalRange = kernel.PhysicalRange;
const Processor = kernel.Processor;
const std = @import("std");
const VirtualRange = kernel.VirtualRange;

const limine = @import("limine");

/// Entry point.
export fn _start() linksection(info.init_code) noreturn {
    @call(.never_inline, init.kernelInitStage1, .{});
    core.panic("kernelInitStage1 returned");
}

const limine_requests = struct {
    // TODO: setting this to 1 causes aarch64 to hang at "limine: Loading kernel `boot:///kernel`..."
    export var limine_revison: limine.BaseRevison linksection(info.init_data) = .{ .revison = 0 };
    export var kernel_file: limine.KernelFile linksection(info.init_data) = .{};
    export var hhdm: limine.HHDM linksection(info.init_data) = .{};
    export var kernel_address: limine.KernelAddress linksection(info.init_data) = .{};
    export var memmap: limine.Memmap linksection(info.init_data) = .{};
    export var smp: limine.SMP linksection(info.init_data) = .{ .flags = .{ .x2apic = false } }; // TODO: Enable x2apic
};

/// Returns the direct map address provided by the bootloader, if any.
pub fn directMapAddress() linksection(info.init_code) ?u64 {
    if (limine_requests.hhdm.response) |resp| {
        return resp.offset;
    }
    return null;
}

pub const KernelBaseAddress = struct {
    virtual: u64,
    physical: u64,
};

/// Returns the kernel virtual and physical base addresses provided by the bootloader, if any.
pub fn kernelBaseAddress() linksection(info.init_code) ?KernelBaseAddress {
    if (limine_requests.kernel_address.response) |resp| {
        return .{
            .virtual = resp.virtual_base,
            .physical = resp.physical_base,
        };
    }
    return null;
}

/// Returns the kernel file contents as a VirtualRange, if provided by the bootloader.
pub fn kernelFile() linksection(info.init_code) ?VirtualRange {
    if (limine_requests.kernel_file.response) |resp| {
        return VirtualRange.fromSlice(u8, resp.kernel_file.getContents());
    }
    return null;
}

pub fn x2apicEnabled() linksection(info.init_code) bool {
    if (info.arch != .x86_64) @compileError("x2apicEnabled can only be called on x86_64");

    const smp_response = limine_requests.smp.response orelse return false;
    return smp_response.flags.x2apic_enabled;
}

pub fn processorDescriptors() linksection(info.init_code) ProcessorDescriptorIterator {
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
        processor: *Processor,
        comptime targetFn: fn (processor: *Processor) noreturn,
    ) linksection(info.init_code) void {
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

    pub fn acpiId(self: ProcessorDescriptor) linksection(info.init_code) u32 {
        return switch (self._raw) {
            .limine => |limine_info| limine_info.processor_id,
        };
    }

    pub fn lapicId(self: ProcessorDescriptor) linksection(info.init_code) u32 {
        if (info.arch != .x86_64) @compileError("apicId can only be called on x86_64");

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

    pub fn count(self: ProcessorDescriptorIterator) linksection(info.init_code) usize {
        return switch (self) {
            inline else => |i| i.count(),
        };
    }

    /// Returns the next processor descriptor from the iterator, if any remain.
    pub fn next(self: *ProcessorDescriptorIterator) linksection(info.init_code) ?ProcessorDescriptor {
        return switch (self.*) {
            inline else => |*i| i.next(),
        };
    }
};

const LimineProcessorDescriptorIterator = struct {
    index: usize,
    entries: []*limine.SMP.Response.SMPInfo,

    pub fn count(self: LimineProcessorDescriptorIterator) linksection(info.init_code) usize {
        return self.entries.len;
    }

    pub fn next(self: *LimineProcessorDescriptorIterator) linksection(info.init_code) ?ProcessorDescriptor {
        if (self.index >= self.entries.len) return null;

        const smp_info = self.entries[self.index];

        self.index += 1;

        return .{
            ._raw = .{ .limine = smp_info },
        };
    }
};

/// Returns an iterator over the memory map entries, iterating in the given direction.
pub fn memoryMap(direction: Direction) linksection(info.init_code) MemoryMapIterator {
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
    pub fn next(self: *MemoryMapIterator) linksection(info.init_code) ?MemoryMapEntry {
        return switch (self.*) {
            inline else => |*i| i.next(),
        };
    }
};

/// An entry in the memory map provided by the bootloader.
pub const MemoryMapEntry = struct {
    range: PhysicalRange,
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

    pub fn print(entry: MemoryMapEntry, writer: anytype) linksection(info.init_code) !void {
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

    pub fn next(self: *LimineMemoryMapIterator) linksection(info.init_code) ?MemoryMapEntry {
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
            .range = PhysicalRange.fromAddr(
                PhysicalAddress.fromInt(limine_entry.base),
                core.Size.from(limine_entry.length, .byte),
            ),
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
