// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const boot = @import("boot");
const core = @import("core");
const cascade = @import("cascade");
const Task = cascade.Task;

const limine = @import("limine.zig");

pub fn kernelBaseAddress() ?boot.KernelBaseAddress {
    const resp = requests.kernel_address.response orelse
        return null;

    return .{
        .virtual = resp.virtual_base,
        .physical = resp.physical_base,
    };
}

pub fn memoryMap(direction: core.Direction) error{NoMemoryMap}!boot.MemoryMap {
    const resp = requests.memmap.response orelse
        return error.NoMemoryMap;

    var result: boot.MemoryMap = .{
        .backing = undefined,
    };

    const limine_memory_map = std.mem.bytesAsValue(MemoryMapIterator, &result.backing);

    const entries = resp.entries();

    limine_memory_map.* = .{
        .index = switch (direction) {
            .forward => 0,
            .backward => entries.len,
        },
        .entries = entries,
        .direction = direction,
    };

    return result;
}

pub const MemoryMapIterator = struct {
    index: usize,
    entries: []const *const limine.Memmap.Entry,
    direction: core.Direction,

    pub fn next(memory_map: *boot.MemoryMap) ?boot.MemoryMap.Entry {
        const memory_map_iterator: *MemoryMapIterator = @ptrCast(@alignCast(&memory_map.backing));

        const limine_entry = switch (memory_map_iterator.direction) {
            .backward => blk: {
                if (memory_map_iterator.index == 0) return null;
                memory_map_iterator.index -= 1;
                break :blk memory_map_iterator.entries[memory_map_iterator.index];
            },
            .forward => blk: {
                if (memory_map_iterator.index >= memory_map_iterator.entries.len) return null;
                const entry = memory_map_iterator.entries[memory_map_iterator.index];
                memory_map_iterator.index += 1;
                break :blk entry;
            },
        };

        return .{
            .range = .from(limine_entry.base, limine_entry.length),
            .type = switch (limine_entry.type) {
                .usable => .free,
                .executable_and_modules, .framebuffer => .in_use,
                .reserved, .acpi_nvs => .reserved,
                .bootloader_reclaimable => .bootloader_reclaimable,
                .acpi_reclaimable, .acpi_tables => .acpi_reclaimable,
                .bad_memory => .unusable,
                _ => .unknown,
            },
        };
    }
};

pub fn directMapAddress() ?cascade.KernelVirtualAddress {
    const resp = requests.hhdm.response orelse
        return null;

    return resp.address;
}

pub fn rsdp() ?boot.Address {
    const resp = requests.rsdp.response orelse
        return null;

    return resp.address(limine_revison);
}

pub fn x2apicEnabled() bool {
    std.debug.assert(arch.current_arch == .x64);

    const resp: *const limine.MP.x86_64 = requests.smp.response orelse
        return false;

    return resp.flags.x2apic_enabled;
}

pub fn bootstrapArchitectureProcessorId() u64 {
    const resp = requests.smp.response orelse
        return 0;

    return switch (arch.current_arch) {
        .arm => resp.bsp_mpidr,
        .riscv => resp.bsp_hartid,
        .x64 => resp.bsp_lapic_id,
    };
}

pub fn cpuDescriptors() ?boot.CpuDescriptors {
    const resp = requests.smp.response orelse
        return null;

    var result: boot.CpuDescriptors = .{
        .backing = undefined,
    };

    const descriptor_iterator = std.mem.bytesAsValue(CpuDescriptorIterator, &result.backing);

    descriptor_iterator.* = .{
        .index = 0,
        .entries = resp.cpus(),
    };

    return result;
}

pub const CpuDescriptorIterator = struct {
    index: usize,
    entries: []*limine.MP.Response.MPInfo,

    pub const Descriptor = struct {
        smp_info: *limine.MP.Response.MPInfo,
    };

    pub fn count(cpu_descriptors: *const boot.CpuDescriptors) usize {
        const descriptor_iterator = std.mem.bytesAsValue(CpuDescriptorIterator, &cpu_descriptors.backing);
        return descriptor_iterator.entries.len;
    }

    pub fn next(cpu_descriptors: *boot.CpuDescriptors) ?boot.CpuDescriptors.Descriptor {
        const descriptor_iterator = std.mem.bytesAsValue(CpuDescriptorIterator, &cpu_descriptors.backing);

        if (descriptor_iterator.index >= descriptor_iterator.entries.len) return null;

        const smp_info = descriptor_iterator.entries[descriptor_iterator.index];

        descriptor_iterator.index += 1;

        var result: boot.CpuDescriptors.Descriptor = .{
            .backing = undefined,
        };

        const descriptor = std.mem.bytesAsValue(Descriptor, &result.backing);

        descriptor.* = .{ .smp_info = smp_info };

        return result;
    }

    pub fn bootFn(
        generic_descriptor: *const boot.CpuDescriptors.Descriptor,
        user_data: *anyopaque,
        comptime targetFn: fn (user_data: *anyopaque) anyerror!noreturn,
    ) void {
        const trampolineFn = struct {
            fn trampolineFn(smp_info: *const limine.MP.Response.MPInfo) callconv(.c) noreturn {
                targetFn(@ptrFromInt(smp_info.extra_argument)) catch |err| {
                    std.debug.panic("unhandled error: {t}", .{err});
                };
            }
        }.trampolineFn;

        const descriptor = std.mem.bytesAsValue(Descriptor, &generic_descriptor.backing);
        const smp_info = descriptor.smp_info;

        @atomicStore(
            usize,
            &smp_info.extra_argument,
            @intFromPtr(user_data),
            .release,
        );

        @atomicStore(
            ?*const fn (*const limine.MP.Response.MPInfo) callconv(.c) noreturn,
            &smp_info.goto_address,
            &trampolineFn,
            .release,
        );
    }

    pub fn acpiProcessorId(
        generic_descriptor: *const boot.CpuDescriptors.Descriptor,
    ) u32 {
        const descriptor = std.mem.bytesAsValue(Descriptor, &generic_descriptor.backing);
        return descriptor.smp_info.processor_id;
    }

    pub fn architectureProcessorId(
        generic_descriptor: *const boot.CpuDescriptors.Descriptor,
    ) u64 {
        const descriptor = std.mem.bytesAsValue(Descriptor, &generic_descriptor.backing);

        return switch (arch.current_arch) {
            .arm => descriptor.smp_info.mpidr,
            .riscv => descriptor.smp_info.hartid,
            .x64 => descriptor.smp_info.lapic_id,
        };
    }
};

pub fn framebuffer() ?boot.Framebuffer {
    const buffer = blk: {
        const resp = requests.framebuffer.response orelse
            return null;

        const framebuffers = resp.framebuffers();
        if (framebuffers.len == 0) return null;

        break :blk framebuffers[0];
    };

    std.debug.assert(buffer.bpp == 32);
    std.debug.assert(buffer.memory_model == .rgb);

    return .{
        .ptr = buffer.address.ptr([*]volatile u32),
        .width = buffer.width,
        .height = buffer.height,
        .pitch = buffer.pitch,
        .red_mask_size = buffer.red_mask_size,
        .red_mask_shift = buffer.red_mask_shift,
        .green_mask_size = buffer.green_mask_size,
        .green_mask_shift = buffer.green_mask_shift,
        .blue_mask_size = buffer.blue_mask_size,
        .blue_mask_shift = buffer.blue_mask_shift,
    };
}

pub fn deviceTreeBlob() ?cascade.KernelVirtualAddress {
    const resp = requests.device_tree_blob.response orelse
        return null;
    return resp.address;
}

fn limineEntryPoint() callconv(.c) noreturn {
    asm volatile (arch.scheduling.cfi_prevent_unwinding);

    boot.bootloader_api = .limine;

    limine_revison = requests.limine_base_revison.loadedRevision() orelse {
        // TODO: attempt loading with limine revision 0 and log that the requested revision was not available
        @panic("bootloader does not supported requested limine revision");
    };

    @call(.never_inline, cascade.init.initStage1, .{}) catch |err| {
        std.debug.panic("unhandled error: {t}", .{err});
    };
    @panic("`initStage1` returned");
}

// TODO: ACPI tables and UART are not mapped to HHDM from revision 3 onwards, revision 4 maps ACPI tables but not UART :(
const target_limine_revison: limine.BaseRevison.Revison = .@"2";
var limine_revison: limine.BaseRevison.Revison = .@"0";

pub fn exportRequests() void {
    @export(&requests.limine_base_revison, .{ .name = "limine_base_revison_request" });
    @export(&requests.entry_point, .{ .name = "limine_entry_point_request" });
    @export(&requests.kernel_address, .{ .name = "limine_kernel_address_request" });
    @export(&requests.memmap, .{ .name = "limine_memmap_request" });
    @export(&requests.hhdm, .{ .name = "limine_hhdm_request" });
    @export(&requests.rsdp, .{ .name = "limine_rsdp_request" });
    @export(&requests.smp, .{ .name = "limine_smp_request" });
    @export(&requests.framebuffer, .{ .name = "limine_framebuffer_request" });
    @export(&requests.device_tree_blob, .{ .name = "limine_device_tree_blob_request" });
}

const requests = struct {
    var limine_base_revison: limine.BaseRevison = .{ .revison = target_limine_revison };
    var entry_point: limine.EntryPoint = .{ .entry = limineEntryPoint };
    var kernel_address: limine.ExecutableAddress = .{};
    var memmap: limine.Memmap = .{};
    var hhdm: limine.HHDM = .{};
    var rsdp: limine.RSDP = .{};
    var smp: limine.MP = .{ .flags = .{ .x2apic = true } };
    var framebuffer: limine.Framebuffer = .{};
    var device_tree_blob: limine.DeviceTreeBlob = .{};
};
