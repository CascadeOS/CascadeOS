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
    calculateKernelVirtualAndPhysicalOffsets();
    calculateDirectMaps();

    // the kernel file was captured earlier in the setup process, now we can debug log what was captured
    log.debug("kernel file: {} - {}", .{
        kernel.VirtAddr.fromPtr(kernel.info.kernel_file.ptr),
        core.Size.from(kernel.info.kernel_file.len, .byte),
    });
}

fn calculateDirectMaps() void {
    const size_of_direct_map = calculateLengthOfDirectMap();

    const direct_map_range: kernel.VirtRange = blk: {
        const direct_map_address = kernel.boot.directMapAddress() orelse
            core.panic("bootloader did not provide the start of the direct map");

        const direct_map = kernel.VirtAddr.fromInt(direct_map_address);

        if (!direct_map.isAligned(kernel.arch.paging.standard_page_size)) {
            core.panic("direct map is not aligned to the standard page size");
        }

        break :blk kernel.VirtRange.fromAddr(direct_map, size_of_direct_map);
    };

    const non_cached_direct_map_range = blk: {
        // try to place the non-cached direct map directly _before_ the direct map
        {
            const range = direct_map_range.moveBackward(size_of_direct_map);
            // check that we have not gone below the higher half
            if (range.addr.greaterThanOrEqual(kernel.arch.paging.higher_half)) {
                break :blk range;
            }
        }

        // try to place the non-cached direct map directly _after_ the direct map
        {
            const range = direct_map_range.moveForward(size_of_direct_map);
            // check that we are not overlapping with the kernel
            if (!range.contains(kernel.info.kernel_virtual_address)) {
                break :blk range;
            }
        }

        core.panic("failed to find region for non-cached direct map");
    };

    kernel.info.direct_map = direct_map_range;
    log.debug("direct map: {}", .{direct_map_range});

    kernel.info.non_cached_direct_map = non_cached_direct_map_range;
    log.debug("non-cached direct map: {}", .{non_cached_direct_map_range});
}

fn calculateLengthOfDirectMap() core.Size {
    var reverse_memmap_iterator = kernel.boot.memoryMapIterator(.backwards);

    while (reverse_memmap_iterator.next()) |entry| {
        if (entry.type == .reserved_or_unusable) continue;

        const estimated_size = core.Size.from(entry.range.end().value, .byte);

        log.debug("estimated size of direct map: {}", .{estimated_size});

        // We align the length of the direct map to `largest_page_size` to allow large pages to be used for the mapping.
        var aligned_size = estimated_size.alignForward(kernel.arch.paging.largestPageSize());

        // We ensure that the lowest 4GiB are always mapped.
        const @"4gib" = core.Size.from(4, .gib);
        if (aligned_size.lessThan(@"4gib")) aligned_size = @"4gib";

        log.debug("aligned size of direct map: {}", .{aligned_size});

        return aligned_size;
    }

    core.panic("no non-reserved or usable memory regions?");
}

fn calculateKernelVirtualAndPhysicalOffsets() void {
    const kernel_address = kernel.boot.kernelAddress() orelse
        core.panic("bootloader did not provide the kernel address");
    // TODO: Can we calculate the kernel offsets from the the bootloaders page table?
    // https://github.com/CascadeOS/CascadeOS/issues/36

    const kernel_virtual = kernel_address.virtual;
    const kernel_physical = kernel_address.physical;

    kernel.info.kernel_virtual_address = kernel.VirtAddr.fromInt(kernel_virtual);
    kernel.info.kernel_physical_address = kernel.PhysAddr.fromInt(kernel_physical);
    log.debug("kernel virtual: {}", .{kernel.info.kernel_virtual_address});
    log.debug("kernel physical: {}", .{kernel.info.kernel_physical_address});

    kernel.info.kernel_offset_from_base = core.Size.from(kernel_virtual - kernel.info.kernel_base_address.value, .byte);
    kernel.info.kernel_virtual_offset_from_physical = core.Size.from(kernel_virtual - kernel_physical, .byte);
    log.debug("kernel offset from base: 0x{x}", .{kernel.info.kernel_offset_from_base.bytes});
    log.debug("kernel offset from physical: 0x{x}", .{kernel.info.kernel_virtual_offset_from_physical.bytes});
}
