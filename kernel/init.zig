// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");

const log = kernel.debug.log.scoped(.init);

var bootstrap_interrupt_stack align(16) = [_]u8{0} ** kernel.Stack.usable_stack_size.value;

var bootstrap_processor: kernel.Processor = .{
    .id = .bootstrap,
    .idle_stack = undefined, // initialized at the beginning of `kernelInit`
    .arch = undefined, // initialized by `prepareBootstrapProcessor`
};

/// Stage 1 of kernel initialization.
///
/// Entry point from the bootloader specific code.
///
/// Only the bootstrap processor executes this function.
pub fn kernelInitStage1() noreturn {
    // get output up and running as soon as possible
    kernel.arch.init.setupEarlyOutput();

    // we need to get the processor data loaded early as the panic handler and logging use it
    bootstrap_processor.idle_stack = kernel.Stack.fromRangeNoGuard(core.VirtualRange.fromSlice(
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

    log.debug("capturing bootloader provided information", .{});
    captureBootloaderProvidedInformation();

    log.debug("performing early arch initialization", .{});
    kernel.arch.init.earlyArchInitialization();

    log.debug("initializing ACPI tables", .{});
    kernel.acpi.init.initializeACPITables();

    log.debug("capturing system information", .{});
    kernel.arch.init.captureSystemInformation();

    log.debug("initializing physical memory", .{});
    kernel.memory.physical.init.initPhysicalMemory();

    log.debug("initializing virtual memory", .{});
    kernel.memory.virtual.init.initVirtualMemory();

    log.debug("configuring global system features", .{});
    kernel.arch.init.configureGlobalSystemFeatures();

    log.debug("initializing time", .{});
    kernel.time.init.initTime();

    log.debug("initializing processors", .{});
    initProcessors();

    kernelInitStage2(kernel.Processor.get(.bootstrap));
}

/// Stage 2 of kernel initialization.
///
/// This function is executed by all processors, including the bootstrap processor.
///
/// All processors are using the bootloader provided stack.
fn kernelInitStage2(processor: *kernel.Processor) noreturn {
    kernel.arch.paging.switchToPageTable(kernel.kernel_process.page_table);
    kernel.arch.init.loadProcessor(processor);

    log.debug("configuring processor-local system features", .{});
    kernel.arch.init.configureSystemFeaturesForCurrentProcessor(processor);

    log.debug("configuring local interrupt controller", .{});
    kernel.arch.init.initLocalInterruptController(processor);

    log.debug("initializing scheduler", .{});
    kernel.scheduler.init.initScheduler();

    const idle_stack_pointer = processor.idle_stack.pushReturnAddressWithoutChangingPointer(
        core.VirtualAddress.fromPtr(&kernelInitStage3),
    ) catch unreachable; // the idle stack is always big enough to hold a return address

    log.debug("leaving bootloader provided stack", .{});
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
        // the bootloader reclaimable memory.
        const processor_count = kernel.Processor._all.len;
        while (processors_in_stage3.load(.Acquire) != processor_count) {
            kernel.arch.spinLoopHint();
        }

        log.debug("all processors in init stage 3", .{});

        kernel.debug.init.switchToMainPanicImpl();

        log.debug("reclaiming bootloader reclaimable memory", .{});
        kernel.memory.physical.init.reclaimBootloaderReclaimableMemory();

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

    log.debug("entering scheduler on processor {}", .{processor.id});
    _ = kernel.scheduler.lock.lock();
    kernel.scheduler.schedule(false);
    unreachable;
}

/// Copy the kernel file from the bootloader provided memory to the kernel kernel.heap.
fn copyKernelFileFromBootloaderMemory() void {
    const bootloader_provided_kernel_file = kernel.info.kernel_file.?;

    const kernel_file_buffer = kernel.heap.page_allocator.alloc(
        u8,
        bootloader_provided_kernel_file.size.value,
    ) catch {
        core.panic("Failed to allocate memory for kernel file buffer");
    };

    @memcpy(
        kernel_file_buffer[0..bootloader_provided_kernel_file.size.value],
        bootloader_provided_kernel_file.toByteSlice(),
    );

    kernel.info.kernel_file.?.address = core.VirtualAddress.fromPtr(kernel_file_buffer.ptr);
}

/// Initialize the per processor data structures for all processors including the bootstrap processor.
///
/// Also wakes the non-bootstrap processors and jumps them to `kernelInitStage2`.
fn initProcessors() void {
    var processor_descriptors = kernel.boot.processorDescriptors();

    kernel.Processor._all = kernel.heap.page_allocator.alloc(
        kernel.Processor,
        processor_descriptors.count(),
    ) catch core.panic("failed to allocate processors");

    var processor_id: kernel.Processor.Id = .bootstrap;

    while (processor_descriptors.next()) |processor_descriptor| : ({
        processor_id = @enumFromInt(@intFromEnum(processor_id) + 1);
    }) {
        log.debug("initializing processor {}", .{processor_id});

        const processor = kernel.Processor.get(processor_id);

        const idle_stack = kernel.Stack.create(true) catch {
            core.panic("failed to allocate idle stack");
        };

        processor.* = .{
            .id = processor_id,
            .idle_stack = idle_stack,
            .arch = undefined, // initialized by `prepareProcessor`
        };

        kernel.arch.init.prepareProcessor(processor, processor_descriptor);

        if (processor.id != .bootstrap) {
            log.debug("booting processor {}", .{processor_id});
            processor_descriptor.boot(processor, kernelInitStage2);
        }
    }
}

fn captureBootloaderProvidedInformation() void {
    kernel.info.kernel_file = kernel.boot.kernelFile() orelse
        core.panic("bootloader did not provide the kernel file");

    calculateKernelOffsets();
    calculateDirectMaps();
}

fn calculateDirectMaps() void {
    const direct_map_size = calculateLengthOfDirectMap();

    kernel.info.direct_map = calculateDirectMapRange(direct_map_size);
    log.debug("direct map: {}", .{kernel.info.direct_map});

    kernel.info.non_cached_direct_map = calculateNonCachedDirectMapRange(direct_map_size, kernel.info.direct_map);
    log.debug("non-cached direct map: {}", .{kernel.info.non_cached_direct_map});
}

fn calculateDirectMapRange(direct_map_size: core.Size) core.VirtualRange {
    const direct_map_address = kernel.boot.directMapAddress() orelse
        core.panic("bootloader did not provide the start of the direct map");

    if (!direct_map_address.isAligned(kernel.arch.paging.standard_page_size)) {
        core.panic("direct map is not aligned to the standard page size");
    }

    return core.VirtualRange.fromAddr(direct_map_address, direct_map_size);
}

fn calculateNonCachedDirectMapRange(
    direct_map_size: core.Size,
    direct_map_range: core.VirtualRange,
) core.VirtualRange {
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
fn calculateLengthOfDirectMap() core.Size {
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

fn calculateKernelOffsets() void {
    const kernel_base_address = kernel.boot.kernelBaseAddress() orelse
        core.panic("bootloader did not provide the kernel base address");

    const kernel_virtual = kernel_base_address.virtual;
    const kernel_physical = kernel_base_address.physical;

    kernel.info.kernel_virtual_base_address = kernel_virtual;
    kernel.info.kernel_physical_base_address = kernel_physical;
    log.debug("kernel virtual base address: {}", .{kernel.info.kernel_virtual_base_address});
    log.debug("kernel physical base address: {}", .{kernel.info.kernel_physical_base_address});

    kernel.info.kernel_virtual_slide = core.Size.from(kernel_virtual.value - kernel.info.kernel_base_address.value, .byte);
    kernel.info.kernel_physical_to_virtual_offset = core.Size.from(kernel_virtual.value - kernel_physical.value, .byte);
    log.debug("kernel virtual slide: 0x{x}", .{kernel.info.kernel_virtual_slide.?.value});
    log.debug("kernel physical to virtual offset: 0x{x}", .{kernel.info.kernel_physical_to_virtual_offset.value});
}
