// SPDX-License-Identifier: MIT

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");

const log = kernel.debug.log.scoped(.init);

var bootstrap_interrupt_stack align(16) linksection(kernel.info.init_data) = [_]u8{0} ** kernel.Stack.usable_stack_size.bytes;

var bootstrap_processor: kernel.Processor linksection(kernel.info.init_data) = .{
    .id = .bootstrap,
    .idle_stack = undefined, // initialized at the beginning of `kernelInit`
    .arch = undefined, // initialized by `prepareBootstrapProcessor`
};

/// Stage 1 of kernel initialization.
///
/// Entry point from the bootloader specific code.
///
/// Only the bootstrap processor executes this function.
pub fn kernelInitStage1() linksection(kernel.info.init_code) noreturn {
    // get output up and running as soon as possible
    kernel.arch.init.setupEarlyOutput();

    // we need to get the processor data loaded early as the panic handler and logging use it
    bootstrap_processor.idle_stack = kernel.Stack.fromRangeNoGuard(kernel.VirtualRange.fromSlice(
        u8,
        @as([]u8, &bootstrap_interrupt_stack),
    ));
    kernel.arch.init.prepareBootstrapProcessor(&bootstrap_processor);
    kernel.arch.init.loadProcessor(&bootstrap_processor);

    // print starting message
    if (kernel.arch.init.getEarlyOutput()) |early_output| {
        defer early_output.deinit();
        early_output.writer.writeAll(comptime "starting CascadeOS " ++ kernel.info.version ++ "\n") catch {};
    }

    log.info("capturing bootloader provided information", .{});
    captureBootloaderProvidedInformation();

    log.info("performing early system initialization", .{});
    kernel.arch.init.earlyArchInitialization();

    log.info("initializing ACPI tables", .{});
    kernel.acpi.init.initializeACPITables();

    log.info("capturing system information", .{});
    kernel.arch.init.captureSystemInformation();

    log.info("configuring system features", .{});
    kernel.arch.init.configureSystemFeatures();

    log.info("initializing physical memory", .{});
    kernel.memory.physical.init.initPhysicalMemory();

    log.info("initializing virtual memory", .{});
    kernel.memory.virtual.init.initVirtualMemory();

    log.info("initializing processors", .{});
    initProcessors();

    kernelInitStage2(&kernel.Processor.all[0]);
}

/// Stage 2 of kernel initialization.
///
/// This function is executed by all processors, including the bootstrap processor.
///
/// All processors are using the bootloader provided stack.
fn kernelInitStage2(processor: *kernel.Processor) linksection(kernel.info.init_code) noreturn {
    kernel.arch.paging.switchToPageTable(kernel.kernel_process.page_table);
    kernel.arch.init.loadProcessor(processor);
    kernel.arch.init.initLocalInterruptController(processor);

    const idle_stack_pointer = processor.idle_stack.pushReturnAddressWithoutChangingPointer(
        kernel.VirtualAddress.fromPtr(&kernelInitStage3),
    ) catch unreachable; // the idle stack is always big enough to hold a return address

    kernel.arch.scheduling.changeStackAndReturn(idle_stack_pointer);
    unreachable;
}

var processors_in_stage3 = std.atomic.Value(usize).init(0);
var reload_page_table_gate = std.atomic.Value(bool).init(false);

/// Stage 3 of kernel initialization.
fn kernelInitStage3() noreturn {
    _ = processors_in_stage3.fetchAdd(1, .AcqRel);

    const processor = kernel.arch.getProcessor();

    if (processor.id == .bootstrap) {
        log.debug("copying kernel file from bootloader memory", .{});
        copyKernelFileFromBootloaderMemory();

        // We are the bootstrap processor, we need to wait for all other processors to enter stage 3 before we unmap
        // the init only mappings.
        const processor_count = kernel.Processor.all.len;
        while (processors_in_stage3.load(.Acquire) != processor_count) {
            kernel.arch.spinLoopHint();
        }

        log.debug("all processors in init stage 3", .{});

        log.debug("reclaiming bootloader reclaimable memory", .{});
        kernel.memory.physical.init.reclaimBootloaderReclaimableMemory();

        log.debug("unmapping init only kernel sections", .{});
        kernel.memory.virtual.init.unmapInitOnlyKernelSections();

        reload_page_table_gate.store(true, .Release);
    } else {
        // We are not the bootstrap processor, we need to wait for the bootstrap processor to
        // unmap the init only mappings before we can continue.

        while (!reload_page_table_gate.load(.Acquire)) {
            kernel.arch.spinLoopHint();
        }
    }

    // now that the init only mappings are gone we reload the page table
    kernel.arch.paging.switchToPageTable(kernel.kernel_process.page_table);

    // TODO: Flush TLB

    log.debug("entering scheduler on processor {}", .{processor.id});
    _ = kernel.scheduler.lock.lock();
    kernel.scheduler.schedule(false);
    unreachable;
}

/// Copy the kernel file from the bootloader provided memory to the kernel kernel.heap.
fn copyKernelFileFromBootloaderMemory() linksection(kernel.info.init_code) void {
    const bootloader_provided_kernel_file = kernel.info.kernel_file.?;

    const kernel_file_buffer = kernel.heap.page_allocator.alloc(
        u8,
        bootloader_provided_kernel_file.size.bytes,
    ) catch {
        core.panic("Failed to allocate memory for kernel file buffer");
    };

    @memcpy(
        kernel_file_buffer[0..bootloader_provided_kernel_file.size.bytes],
        bootloader_provided_kernel_file.toByteSlice(),
    );

    kernel.info.kernel_file.?.address = kernel.VirtualAddress.fromPtr(kernel_file_buffer.ptr);
}

/// Initialize the per processor data structures for all processors including the bootstrap processor.
///
/// Also wakes the non-bootstrap processors and jumps them to `kernelInitStage2`.
fn initProcessors() linksection(kernel.info.init_code) void {
    var processor_descriptors = kernel.boot.processorDescriptors();

    kernel.Processor.all = kernel.heap.page_allocator.alloc(
        kernel.Processor,
        processor_descriptors.count(),
    ) catch core.panic("failed to allocate processors");

    var i: usize = 0;

    while (processor_descriptors.next()) |processor_descriptor| : (i += 1) {
        log.debug("initializing processor {:0>2}", .{i});

        const processor = &kernel.Processor.all[i];

        const idle_stack = kernel.Stack.create(true) catch {
            core.panic("failed to allocate idle stack");
        };

        processor.* = .{
            .id = @enumFromInt(i),
            .idle_stack = idle_stack,
            .arch = undefined, // initialized by `prepareProcessor`
        };

        kernel.arch.init.prepareProcessor(processor, processor_descriptor);

        if (processor.id != .bootstrap) {
            log.debug("booting processor {}", .{i});
            processor_descriptor.boot(processor, kernelInitStage2);
        }
    }
}

fn captureBootloaderProvidedInformation() linksection(kernel.info.init_code) void {
    kernel.info.kernel_file = kernel.boot.kernelFile() orelse
        core.panic("bootloader did not provide the kernel file");

    calculateKernelOffsets();
    calculateDirectMaps();
}

fn calculateDirectMaps() linksection(kernel.info.init_code) void {
    const direct_map_size = calculateLengthOfDirectMap();

    kernel.info.direct_map = calculateDirectMapRange(direct_map_size);
    log.debug("direct map: {}", .{kernel.info.direct_map});

    kernel.info.non_cached_direct_map = calculateNonCachedDirectMapRange(direct_map_size, kernel.info.direct_map);
    log.debug("non-cached direct map: {}", .{kernel.info.non_cached_direct_map});
}

fn calculateDirectMapRange(direct_map_size: core.Size) linksection(kernel.info.init_code) kernel.VirtualRange {
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
) linksection(kernel.info.init_code) kernel.VirtualRange {
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

    core.panic("failed to find region for non-cached direct map");
}

/// Calculates the length of the direct map.
fn calculateLengthOfDirectMap() linksection(kernel.info.init_code) core.Size {
    var memory_map_iterator = kernel.boot.memoryMap(.backwards);

    const last_usable_entry: kernel.boot.MemoryMapEntry = blk: {
        // search from the end of the memory map for the last usable region

        while (memory_map_iterator.next()) |entry| {
            if (entry.type == .reserved_or_unusable) continue;

            break :blk entry;
        }

        core.panic("no non-reserved or usable memory regions?");
    };

    const initial_size = core.Size.from(last_usable_entry.range.end().value, .byte);

    // We align the length of the direct map to `largest_page_size` to allow large pages to be used for the mapping.
    var aligned_size = initial_size.alignForward(kernel.arch.paging.largestPageSize());

    // We ensure that the lowest 4GiB are always mapped.
    const four_gib = core.Size.from(4, .gib);
    if (aligned_size.lessThan(four_gib)) aligned_size = four_gib;

    log.debug("size of direct map: {}", .{aligned_size});

    return aligned_size;
}

fn calculateKernelOffsets() linksection(kernel.info.init_code) void {
    const kernel_base_address = kernel.boot.kernelBaseAddress() orelse
        core.panic("bootloader did not provide the kernel base address");

    const kernel_virtual = kernel_base_address.virtual;
    const kernel_physical = kernel_base_address.physical;

    kernel.info.kernel_virtual_base_address = kernel.VirtualAddress.fromInt(kernel_virtual);
    kernel.info.kernel_physical_base_address = kernel.PhysicalAddress.fromInt(kernel_physical);
    log.debug("kernel virtual base address: {}", .{kernel.info.kernel_virtual_base_address});
    log.debug("kernel physical base address: {}", .{kernel.info.kernel_physical_base_address});

    kernel.info.kernel_virtual_slide = core.Size.from(kernel_virtual - kernel.info.kernel_base_address.value, .byte);
    kernel.info.kernel_physical_to_virtual_offset = core.Size.from(kernel_virtual - kernel_physical, .byte);
    log.debug("kernel virtual slide: 0x{x}", .{kernel.info.kernel_virtual_slide.?.bytes});
    log.debug("kernel physical to virtual offset: 0x{x}", .{kernel.info.kernel_physical_to_virtual_offset.bytes});
}
