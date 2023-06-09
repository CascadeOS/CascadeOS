// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const log = kernel.log.scoped(.setup);

pub fn setup() void {
    // we try to get output up and running as soon as possible
    kernel.arch.setup.setupEarlyOutput();

    // now that we have early output, we can switch to a simple panic handler
    kernel.debug.switchTo(.simple);

    // as we need the kernel elf file to output symbols and source locations, we acquire it early
    kernel.info.kernel_file = kernel.boot.kernelFile() orelse
        core.panic("bootloader did not provide the kernel file");

    // print starting message
    kernel.arch.setup.getEarlyOutputWriter().writeAll(
        comptime "starting CascadeOS " ++ kernel.info.version ++ "\n",
    ) catch {};

    log.info("performing early system initialization", .{});
    kernel.arch.setup.earlyArchInitialization();

    log.info("capturing bootloader information", .{});
    captureBootloaderInformation();

    log.info("capturing system information", .{});
    kernel.arch.setup.captureSystemInformation();

    log.info("configuring system features", .{});
    kernel.arch.setup.configureSystemFeatures();

    log.info("initializing physical memory", .{});
    kernel.pmm.init();

    log.info("initializing virtual memory", .{});
    kernel.vmm.init();

    core.panic("UNIMPLEMENTED"); // TODO: implement initial system setup
}

fn captureBootloaderInformation() void {
    calculateKernelOffsets();
    calculateDirectMaps();

    // the kernel file was captured earlier in the setup process, now we can debug log what was captured
    log.debug("kernel file: {}", .{kernel.info.kernel_file});
}

fn calculateDirectMaps() void {
    const direct_map_size = calculateLengthOfDirectMap();

    kernel.info.direct_map = calculateDirectMapRange(direct_map_size);
    log.debug("direct map: {}", .{kernel.info.direct_map});

    kernel.info.non_cached_direct_map = calculateNonCachedDirectMapRange(direct_map_size, kernel.info.direct_map);
    log.debug("non-cached direct map: {}", .{kernel.info.non_cached_direct_map});
}

fn calculateDirectMapRange(direct_map_size: core.Size) kernel.VirtualRange {
    const direct_map_address = kernel.boot.directMapAddress() orelse
        core.panic("bootloader did not provide the start of the direct map");

    const direct_map_start_address = kernel.VirtualAddress.fromInt(direct_map_address);

    if (!direct_map_start_address.isAligned(kernel.arch.paging.standard_page_size)) {
        core.panic("direct map is not aligned to the standard page size");
    }

    return kernel.VirtualRange.fromAddr(direct_map_start_address, direct_map_size);
}

fn calculateNonCachedDirectMapRange(
    direct_map_size: core.Size,
    direct_map_range: kernel.VirtualRange,
) kernel.VirtualRange {
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
        if (!candidate_range.contains(kernel.info.kernel_virtual_address)) {
            return candidate_range;
        }
    }

    core.panic("failed to find region for non-cached direct map");
}

/// Calculates the length of the direct map.
fn calculateLengthOfDirectMap() core.Size {
    var memory_map_iterator = kernel.boot.memoryMapIterator(.backwards);

    const first_usable_entry: kernel.boot.MemoryMapEntry = blk: {
        // search from the end of the memory map for the first usable region

        while (memory_map_iterator.next()) |entry| {
            if (entry.type == .reserved_or_unusable) continue;

            break :blk entry;
        }

        core.panic("no non-reserved or usable memory regions?");
    };

    const initial_size = core.Size.from(first_usable_entry.range.end().value, .byte);

    // We align the length of the direct map to `largest_page_size` to allow large pages to be used for the mapping.
    var aligned_size = initial_size.alignForward(kernel.arch.paging.largestPageSize());

    // We ensure that the lowest 4GiB are always mapped.
    const four_gib = core.Size.from(4, .gib);
    if (aligned_size.lessThan(four_gib)) aligned_size = four_gib;

    log.debug("size of direct map: {}", .{aligned_size});

    return aligned_size;
}

fn calculateKernelOffsets() void {
    const kernel_address = kernel.boot.kernelAddress() orelse
        core.panic("bootloader did not provide the kernel address");

    // TODO: Can we calculate the kernel offsets from the the bootloaders page table?
    // https://github.com/CascadeOS/CascadeOS/issues/36

    const kernel_virtual = kernel_address.virtual;
    const kernel_physical = kernel_address.physical;

    kernel.info.kernel_virtual_address = kernel.VirtualAddress.fromInt(kernel_virtual);
    kernel.info.kernel_physical_address = kernel.PhysicalAddress.fromInt(kernel_physical);
    log.debug("kernel virtual: {}", .{kernel.info.kernel_virtual_address});
    log.debug("kernel physical: {}", .{kernel.info.kernel_physical_address});

    kernel.info.kernel_load_offset = core.Size.from(kernel_virtual - kernel.info.kernel_base_address.value, .byte);
    kernel.info.kernel_virtual_offset = core.Size.from(kernel_virtual - kernel_physical, .byte);
    log.debug("kernel load offset: 0x{x}", .{kernel.info.kernel_load_offset.bytes});
    log.debug("kernel virtual offset: 0x{x}", .{kernel.info.kernel_virtual_offset.bytes});
}
