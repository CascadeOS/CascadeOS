// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

var bootstrap_cpu: kernel.Cpu = .{
    .id = .bootstrap,
    .interrupt_disable_count = 1, // interrupts start disabled
    .arch = undefined, // set by `arch.init.prepareBootstrapCpu`
};

const log = kernel.log.scoped(.init);

/// Entry point from bootloader specific code.
///
/// Only the bootstrap cpu executes this function.
pub fn earlyInit() !void {
    // get output up and running as soon as possible
    kernel.arch.init.setupEarlyOutput();

    kernel.arch.init.prepareBootstrapCpu(&bootstrap_cpu);
    kernel.arch.init.loadCpu(&bootstrap_cpu);

    // ensure any interrupts are handled
    kernel.arch.init.initInterrupts();

    // now that early output is ready, we can switch to the init panic
    kernel.debug.init.loadInitPanic();

    if (kernel.arch.init.getEarlyOutput()) |early_output| {
        early_output.writeAll(comptime "starting CascadeOS " ++ kernel.config.cascade_version ++ "\n") catch {};
    }

    log.debug("capturing kernel offsets", .{});
    try captureKernelOffsets();

    log.debug("capturing direct map", .{});
    try captureBootloaderDirectMap();

    log.debug("adding free memory to pmm", .{});
    try addFreeMemoryToPmm();
}

fn captureKernelOffsets() !void {
    const kernel_base_address = kernel.boot.kernelBaseAddress() orelse return error.KernelBaseAddressNotProvided;

    const kernel_virtual = kernel_base_address.virtual;
    const kernel_physical = kernel_base_address.physical;

    kernel.info.kernel_virtual_base_address = kernel_virtual;
    log.debug("kernel virtual base address: {}", .{kernel.info.kernel_virtual_base_address});
    log.debug("kernel physical base address: {}", .{kernel_physical});

    kernel.info.kernel_virtual_offset = core.Size.from(kernel_virtual.value - kernel.config.kernel_base_address.value, .byte);
    kernel.info.kernel_physical_to_virtual_offset = core.Size.from(kernel_virtual.value - kernel_physical.value, .byte);
    log.debug("kernel virtual offset: 0x{x}", .{kernel.info.kernel_virtual_offset.?.value});
    log.debug("kernel physical to virtual offset: 0x{x}", .{kernel.info.kernel_physical_to_virtual_offset.value});
}

fn captureBootloaderDirectMap() !void {
    const direct_map_size = try calculateSizeOfDirectMap();

    kernel.info.direct_map = try calculateDirectMapRange(direct_map_size);
    log.debug("direct map: {}", .{kernel.info.direct_map});
}

/// Calculates the size of the direct map.
fn calculateSizeOfDirectMap() !core.Size {
    const last_memory_map_entry = blk: {
        var memory_map_iterator = kernel.boot.memoryMap(.backwards);
        while (memory_map_iterator.next()) |memory_map_entry| {
            if (memory_map_entry.type == .reserved_or_unusable and
                memory_map_entry.range.address.equal(core.PhysicalAddress.fromInt(0x000000fd00000000)))
            {
                // this is a qemu specific hack to not have a 1TiB direct map
                // this `0xfd00000000` memory region is not listed in qemu's `info mtree` but the bootloader reports it
                continue;
            }
            break :blk memory_map_entry;
        }
        return error.NoMemoryMapEntries;
    };

    var direct_map_size = core.Size.from(last_memory_map_entry.range.last().value, .byte);

    // We align the length of the direct map to `largest_page_size` to allow large pages to be used for the mapping.
    direct_map_size.alignForwardInPlace(kernel.arch.paging.all_page_sizes[kernel.arch.paging.all_page_sizes.len - 1]);

    // We ensure that the lowest 4GiB are always mapped.
    const four_gib = core.Size.from(4, .gib);
    if (direct_map_size.lessThan(four_gib)) direct_map_size = four_gib;

    log.debug("size of direct map: {}", .{direct_map_size});

    return direct_map_size;
}

fn calculateDirectMapRange(direct_map_size: core.Size) !core.VirtualRange {
    const direct_map_address = kernel.boot.directMapAddress() orelse return error.DirectMapAddressNotProvided;

    if (!direct_map_address.isAligned(kernel.arch.paging.standard_page_size)) {
        return error.DirectMapAddressNotAligned;
    }

    return core.VirtualRange.fromAddr(direct_map_address, direct_map_size);
}

fn addFreeMemoryToPmm() !void {
    var size = core.Size.zero;

    var memory_map_iterator = kernel.boot.memoryMap(.forwards);

    while (memory_map_iterator.next()) |memory_map_entry| {
        if (memory_map_entry.type != .free) continue;

        kernel.pmm.init.addRange(memory_map_entry.range) catch |err| {
            log.err("failed to add {} to pmm", .{memory_map_entry});
            return err;
        };

        size.addInPlace(memory_map_entry.range.size);
    }

    log.debug("added {} of memory to pmm", .{size});
}
