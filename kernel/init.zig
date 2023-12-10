// SPDX-License-Identifier: MIT

const arch = kernel.arch;
const boot = kernel.boot;
const core = @import("core");
const heap = kernel.heap;
const info = kernel.info;
const kernel = @import("kernel");
const PhysicalAddress = kernel.PhysicalAddress;
const pmm = kernel.pmm;
const Processor = kernel.Processor;
const Stack = kernel.Stack;
const std = @import("std");
const VirtualAddress = kernel.VirtualAddress;
const VirtualRange = kernel.VirtualRange;
const vmm = kernel.vmm;

const log = kernel.log.scoped(.init);

var bootstrap_interrupt_stack align(16) linksection(info.init_data) = [_]u8{0} ** Stack.usable_stack_size.bytes;

var bootstrap_processor: Processor linksection(info.init_data) = .{
    .id = .bootstrap,
    .idle_stack = undefined, // initialized at the beginning of `kernelInit`
    .arch = undefined, // initialized by `prepareBootstrapProcessor`
};

/// Stage 1 of kernel initialization.
///
/// Entry point from the bootloader specific code.
///
/// Only the bootstrap processor executes this function.
pub fn kernelInitStage1() linksection(info.init_code) noreturn {
    // get output up and running as soon as possible
    arch.init.setupEarlyOutput();

    // we need to get the processor data loaded early as the panic handler and logging use it
    bootstrap_processor.idle_stack = Stack.fromRangeNoGuard(VirtualRange.fromSlice(
        u8,
        @as([]u8, &bootstrap_interrupt_stack),
    ));
    arch.init.prepareBootstrapProcessor(&bootstrap_processor);
    arch.init.loadProcessor(&bootstrap_processor);

    // as we need the kernel elf file to output symbols and source locations, we acquire it early
    info.kernel_file = boot.kernelFile() orelse
        core.panic("bootloader did not provide the kernel file");

    // print starting message
    if (arch.init.getEarlyOutputWriter()) |writer| {
        writer.writeAll(comptime "starting CascadeOS " ++ info.version ++ "\n") catch {};
    }

    log.info("performing early system initialization", .{});
    arch.init.earlyArchInitialization();

    log.info("capturing bootloader information", .{});
    captureBootloaderInformation();

    log.info("capturing system information", .{});
    arch.init.captureSystemInformation();

    log.info("configuring system features", .{});
    arch.init.configureSystemFeatures();

    log.info("initializing physical memory", .{});
    pmm.init.initPmm();

    log.info("initializing virtual memory", .{});
    vmm.init.initVmm();

    log.debug("copying kernel file from bootloader memory", .{});
    copyKernelFileFromBootloaderMemory();

    log.info("initializing processors", .{});
    initProcessors();

    kernelInitStage2(&Processor.all[0]);
}

/// Stage 2 of kernel initialization.
///
/// This function is executed by all processors, including the bootstrap processor.
///
/// All processors are using the bootloader provided stack.
fn kernelInitStage2(processor: *Processor) linksection(info.init_code) noreturn {
    arch.paging.switchToPageTable(vmm.kernel_page_table);
    arch.init.loadProcessor(processor);

    const idle_stack_pointer = processor.idle_stack.pushReturnAddressWithoutChangingPointer(
        VirtualAddress.fromPtr(&kernelInitStage3),
    ) catch unreachable; // the idle stack is always big enough to hold a return address
    arch.scheduling.changeStackAndReturn(idle_stack_pointer);
}

var processors_in_stage3 = std.atomic.Value(usize).init(0);
var reload_page_table_gate = std.atomic.Value(bool).init(false);

/// Stage 3 of kernel initialization.
fn kernelInitStage3() noreturn {
    _ = processors_in_stage3.fetchAdd(1, .AcqRel);

    const processor = arch.getProcessor();

    if (processor.id == .bootstrap) {
        // We are the bootstrap processor, we need to wait for all other processors to enter stage 3 before we unmap
        // the init only mappings.
        const processor_count = Processor.all.len;
        while (processors_in_stage3.load(.Acquire) != processor_count) {
            arch.spinLoopHint();
        }

        pmm.init.reclaimBootloaderReclaimableMemory();

        vmm.init.unmapInitOnlyKernelSections();

        reload_page_table_gate.store(true, .Release);
    } else {
        // We are not the bootstrap processor, we need to wait for the bootstrap processor to
        // unmap the init only mappings before we can continue.

        while (!reload_page_table_gate.load(.Acquire)) {
            arch.spinLoopHint();
        }
    }

    // now that the init only mappings are gone we reload the page table
    arch.paging.switchToPageTable(vmm.kernel_page_table);

    kernel.scheduler.schedule(false);
    unreachable;
}

/// Copy the kernel file from the bootloader provided memory to the kernel heap.
pub fn copyKernelFileFromBootloaderMemory() void {
    const bootloader_provided_kernel_file = info.kernel_file.?;

    const kernel_file_buffer = heap.page_allocator.alloc(
        u8,
        bootloader_provided_kernel_file.size.bytes,
    ) catch {
        core.panic("Failed to allocate memory for kernel file buffer");
    };

    @memcpy(
        kernel_file_buffer[0..bootloader_provided_kernel_file.size.bytes],
        bootloader_provided_kernel_file.toByteSlice(),
    );

    info.kernel_file.?.address = VirtualAddress.fromPtr(kernel_file_buffer.ptr);
}

/// Initialize the per processor data structures for all processors including the bootstrap processor.
///
/// Also wakes the non-bootstrap processors and jumps them to `kernelInitStage2`.
fn initProcessors() linksection(info.init_code) void {
    var processor_descriptors = boot.processorDescriptors();

    Processor.all = heap.page_allocator.alloc(
        Processor,
        processor_descriptors.count(),
    ) catch core.panic("failed to allocate processors");

    var i: usize = 0;

    while (processor_descriptors.next()) |processor_descriptor| : (i += 1) {
        log.debug("initializing processor {}", .{i});

        const processor = &Processor.all[i];

        const idle_stack = Stack.create(true) catch {
            core.panic("failed to allocate idle stack");
        };

        processor.* = .{
            .id = @enumFromInt(i),
            .idle_stack = idle_stack,
            .arch = undefined, // initialized by `prepareProcessor`
        };

        arch.init.prepareProcessor(processor);

        if (processor.id != .bootstrap) {
            processor_descriptor.boot(processor, kernelInitStage2);
        }
    }
}

fn captureBootloaderInformation() linksection(info.init_code) void {
    calculateKernelOffsets();
    calculateDirectMaps();

    // the kernel file was captured earlier in the init process, now we can debug log what was captured
    log.debug("kernel file: {}", .{info.kernel_file.?});
}

fn calculateDirectMaps() linksection(info.init_code) void {
    const direct_map_size = calculateLengthOfDirectMap();

    info.direct_map = calculateDirectMapRange(direct_map_size);
    log.debug("direct map: {}", .{info.direct_map});

    info.non_cached_direct_map = calculateNonCachedDirectMapRange(direct_map_size, info.direct_map);
    log.debug("non-cached direct map: {}", .{info.non_cached_direct_map});
}

fn calculateDirectMapRange(direct_map_size: core.Size) linksection(info.init_code) VirtualRange {
    const direct_map_address = boot.directMapAddress() orelse
        core.panic("bootloader did not provide the start of the direct map");

    const direct_map_start_address = VirtualAddress.fromInt(direct_map_address);

    if (!direct_map_start_address.isAligned(arch.paging.standard_page_size)) {
        core.panic("direct map is not aligned to the standard page size");
    }

    return VirtualRange.fromAddr(direct_map_start_address, direct_map_size);
}

fn calculateNonCachedDirectMapRange(
    direct_map_size: core.Size,
    direct_map_range: VirtualRange,
) linksection(info.init_code) VirtualRange {
    // try to place the non-cached direct map directly _before_ the direct map
    {
        const candidate_range = direct_map_range.moveBackward(direct_map_size);
        // check that we have not gone below the higher half
        if (candidate_range.address.greaterThanOrEqual(arch.paging.higher_half)) {
            return candidate_range;
        }
    }

    // try to place the non-cached direct map directly _after_ the direct map
    {
        const candidate_range = direct_map_range.moveForward(direct_map_size);
        // check that we are not overlapping with the kernel
        if (!candidate_range.contains(info.kernel_virtual_base_address)) {
            return candidate_range;
        }
    }

    core.panic("failed to find region for non-cached direct map");
}

/// Calculates the length of the direct map.
fn calculateLengthOfDirectMap() linksection(info.init_code) core.Size {
    var memory_map_iterator = boot.memoryMap(.backwards);

    const last_usable_entry: boot.MemoryMapEntry = blk: {
        // search from the end of the memory map for the last usable region

        while (memory_map_iterator.next()) |entry| {
            if (entry.type == .reserved_or_unusable) continue;

            break :blk entry;
        }

        core.panic("no non-reserved or usable memory regions?");
    };

    const initial_size = core.Size.from(last_usable_entry.range.end().value, .byte);

    // We align the length of the direct map to `largest_page_size` to allow large pages to be used for the mapping.
    var aligned_size = initial_size.alignForward(arch.paging.largestPageSize());

    // We ensure that the lowest 4GiB are always mapped.
    const four_gib = core.Size.from(4, .gib);
    if (aligned_size.lessThan(four_gib)) aligned_size = four_gib;

    log.debug("size of direct map: {}", .{aligned_size});

    return aligned_size;
}

fn calculateKernelOffsets() linksection(info.init_code) void {
    const kernel_base_address = boot.kernelBaseAddress() orelse
        core.panic("bootloader did not provide the kernel base address");

    // TODO: Can we calculate the kernel offsets from the the bootloaders page table?
    // https://github.com/CascadeOS/CascadeOS/issues/36

    const kernel_virtual = kernel_base_address.virtual;
    const kernel_physical = kernel_base_address.physical;

    info.kernel_virtual_base_address = VirtualAddress.fromInt(kernel_virtual);
    info.kernel_physical_base_address = PhysicalAddress.fromInt(kernel_physical);
    log.debug("kernel virtual base address: {}", .{info.kernel_virtual_base_address});
    log.debug("kernel physical base address: {}", .{info.kernel_physical_base_address});

    info.kernel_virtual_slide = core.Size.from(kernel_virtual - info.kernel_base_address.value, .byte);
    info.kernel_physical_to_virtual_offset = core.Size.from(kernel_virtual - kernel_physical, .byte);
    log.debug("kernel virtual slide: 0x{x}", .{info.kernel_virtual_slide.?.bytes});
    log.debug("kernel physical to virtual offset: 0x{x}", .{info.kernel_physical_to_virtual_offset.bytes});
}
