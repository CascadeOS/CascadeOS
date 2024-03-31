// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const log = kernel.log.scoped(.init);

/// Represents the bootstrap cpu during init.
var bootstrap_cpu: kernel.Cpu = .{
    .id = @enumFromInt(0),
    .interrupt_disable_count = 1, // interrupts start disabled
    .preemption_disable_count = 1, // preemption starts disabled
    .idle_stack = undefined, // set at the beginning of `kernelInit`,
    .arch = undefined, // set by `arch.init.prepareBootstrapCpu`
};

var bootstrap_idle_stack: [kernel.config.kernel_stack_size.value]u8 = undefined;

/// Entry point from bootloader specific code.
///
/// Only the bootstrap cpu executes this function.
pub fn kernelInit() !void {
    // get output up and running as soon as possible
    kernel.arch.init.setupEarlyOutput();

    // we need to get the current cpu loaded early as most code assumes it is available
    bootstrap_cpu.idle_stack = kernel.Stack.fromRange(
        core.VirtualRange.fromSlice(u8, &bootstrap_idle_stack),
        core.VirtualRange.fromSlice(u8, &bootstrap_idle_stack),
    );
    kernel.arch.init.prepareBootstrapCpu(&bootstrap_cpu);
    kernel.arch.init.loadCpu(&bootstrap_cpu);

    // ensure any interrupts are handled
    kernel.arch.init.initInterrupts();

    // now that early output and the bootstrap cpu are loaded, we can switch to the init panic
    kernel.debug.init.loadInitPanic();

    if (kernel.arch.init.getEarlyOutput()) |early_output| {
        const starting_message = comptime "starting CascadeOS " ++ kernel.config.cascade_version ++ "\n";
        early_output.writeAll(starting_message) catch {};
    }

    log.debug("capturing kernel offsets", .{});
    try captureKernelOffsets();

    log.debug("capturing direct maps", .{});
    try captureDirectMaps();

    log.debug("capturing system information", .{});
    kernel.arch.init.captureSystemInformation();

    log.debug("adding free memory to pmm", .{});
    try addFreeMemoryToPmm();

    log.debug("building and switching to kernel page table", .{});
    try kernel.vmm.init.buildKernelPageTableAndSwitch();

    kernelInitStage2(&bootstrap_cpu);
}

/// Stage 2 of kernel initialization.
///
/// This function is executed by all cpus, including the bootstrap cpu.
///
/// All cpus are using the bootloader provided stack.
fn kernelInitStage2(cpu: *kernel.Cpu) noreturn {
    kernel.vmm.loadKernelPageTable();
    kernel.arch.init.loadCpu(cpu);

    const idle_stack_pointer = cpu.idle_stack.pushReturnAddressWithoutChangingPointer(
        core.VirtualAddress.fromPtr(&kernelInitStage3),
    ) catch unreachable; // the idle stack is always big enough to hold a return address

    log.debug("leaving bootloader provided stack", .{});
    kernel.arch.scheduling.changeStackAndReturn(idle_stack_pointer);
    unreachable;
}

/// Stage 3 of kernel initialization.
///
/// This function is executed by all cpus, including the bootstrap cpu.
///
/// All cpus are using a normal kernel stack.
fn kernelInitStage3() noreturn {
    core.panic("UNIMPLEMENTED");
}

fn captureKernelOffsets() !void {
    const kernel_base_address = kernel.boot.kernelBaseAddress() orelse return error.KernelBaseAddressNotProvided;

    const kernel_virtual = kernel_base_address.virtual;
    const kernel_physical = kernel_base_address.physical;

    kernel.info.kernel_virtual_base_address = kernel_virtual;
    kernel.info.kernel_physical_base_address = kernel_physical;
    log.debug("kernel virtual base address: {}", .{kernel.info.kernel_virtual_base_address});
    log.debug("kernel physical base address: {}", .{kernel.info.kernel_physical_base_address});

    kernel.info.kernel_virtual_slide = core.Size.from(kernel_virtual.value - kernel.config.kernel_base_address.value, .byte);
    kernel.info.kernel_physical_to_virtual_offset = core.Size.from(kernel_virtual.value - kernel_physical.value, .byte);
    log.debug("kernel virtual slide: 0x{x}", .{kernel.info.kernel_virtual_slide.?.value});
    log.debug("kernel physical to virtual offset: 0x{x}", .{kernel.info.kernel_physical_to_virtual_offset.value});
}

fn captureDirectMaps() !void {
    const direct_map_size = try calculateLengthOfDirectMap();

    kernel.info.direct_map = try calculateDirectMapRange(direct_map_size);
    log.debug("direct map: {}", .{kernel.info.direct_map});

    kernel.info.non_cached_direct_map = try calculateNonCachedDirectMapRange(direct_map_size, kernel.info.direct_map);
    log.debug("non-cached direct map: {}", .{kernel.info.non_cached_direct_map});
}

/// Calculates the length of the direct map.
fn calculateLengthOfDirectMap() !core.Size {
    var memory_map_iterator = kernel.boot.memoryMap(.backwards);

    const last_usable_entry: kernel.boot.MemoryMapEntry = blk: {
        // search from the end of the memory map for the last usable region

        while (memory_map_iterator.next()) |entry| {
            if (entry.type == .reserved_or_unusable) continue;

            break :blk entry;
        }

        return error.NoUsableMemoryRegions;
    };

    const initial_size = core.Size.from(last_usable_entry.range.end().value, .byte);

    // We align the length of the direct map to `largest_page_size` to allow large pages to be used for the mapping.
    var aligned_size = initial_size.alignForward(
        kernel.arch.paging.all_page_sizes[kernel.arch.paging.all_page_sizes.len - 1],
    );

    // We ensure that the lowest 4GiB are always mapped.
    const four_gib = core.Size.from(4, .gib);
    if (aligned_size.lessThan(four_gib)) aligned_size = four_gib;

    log.debug("size of direct map: {}", .{aligned_size});

    return aligned_size;
}

fn calculateDirectMapRange(direct_map_size: core.Size) !core.VirtualRange {
    const direct_map_address = kernel.boot.directMapAddress() orelse return error.DirectMapAddressNotProvided;

    if (!direct_map_address.isAligned(kernel.arch.paging.standard_page_size)) {
        return error.DirectMapAddressNotAligned;
    }

    return core.VirtualRange.fromAddr(direct_map_address, direct_map_size);
}

fn calculateNonCachedDirectMapRange(
    direct_map_size: core.Size,
    direct_map_range: core.VirtualRange,
) !core.VirtualRange {
    // try to place the non-cached direct map directly _before_ the direct map
    {
        const candidate_range = direct_map_range.moveBackward(direct_map_size);
        // check that we have not gone below the higher half
        if (candidate_range.address.greaterThanOrEqual(kernel.arch.paging.higher_half)) {
            return candidate_range;
        }
    }

    // try to place the non-cached direct map directly _after_ the direct map
    {
        const candidate_range = direct_map_range.moveForward(direct_map_size);
        // check that we are not overlapping with the kernel
        if (!candidate_range.contains(kernel.info.kernel_virtual_base_address)) {
            return candidate_range;
        }
    }

    return error.NoUsableMemoryRegions;
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
