// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

/// Entry point from bootloader specific code.
///
/// Only the bootstrap cpu executes this function.
pub fn initStage1() !noreturn {
    const static = struct {
        var bootstrap_executor: kernel.Executor = .{
            .id = .bootstrap,
            .arch = undefined, // set by `arch.init.prepareBootstrapExecutor`
        };
    };

    // get output up and running as soon as possible
    arch.init.setupEarlyOutput();
    arch.init.writeToEarlyOutput(comptime "starting CascadeOS " ++ kernel.config.cascade_version ++ "\n");

    // now that early output is ready, we can switch to the single executor panic
    kernel.debug.panic_impl = singleExecutorPanic;

    // set up the bootstrap executor and load it
    kernel.system.executors = @as([*]kernel.Executor, @ptrCast(&static.bootstrap_executor))[0..1];
    arch.init.prepareBootstrapExecutor(&static.bootstrap_executor);
    arch.init.loadExecutor(&static.bootstrap_executor);

    arch.init.initInterrupts(&handleInterrupt);

    log.debug("building kernel memory layout", .{});
    try buildMemoryLayout(&kernel.system.memory_layout);

    log.debug("initializing ACPI tables", .{});
    try kernel.acpi.init.initializeACPITables(boot.rsdp() orelse return error.RSDPNotProvided);

    core.panic("NOT IMPLEMENTED", null);
}

/// The log implementation during init.
pub fn initLogImpl(level_and_scope: []const u8, comptime fmt: []const u8, args: anytype) void {
    arch.init.writeToEarlyOutput(level_and_scope);
    arch.init.early_output_writer.print(fmt, args) catch unreachable;
}

/// The interrupt handler during init.
fn handleInterrupt(_: arch.interrupts.InterruptContext) noreturn {
    core.panic("unexpected interrupt", null);
}

fn singleExecutorPanic(
    msg: []const u8,
    error_return_trace: ?*const std.builtin.StackTrace,
    return_address: usize,
) void {
    const static = struct {
        var nested_panic_count: std.atomic.Value(usize) = .init(0);
    };

    switch (static.nested_panic_count.fetchAdd(1, .acq_rel)) {
        0 => { // on first panic attempt to print the full panic message
            kernel.debug.formatting.printPanic(
                arch.init.early_output_writer,
                msg,
                error_return_trace,
                return_address,
            ) catch unreachable;
        },
        1 => { // on second panic print a shorter message using only `writeToEarlyOutput`
            arch.init.writeToEarlyOutput("\nPANIC IN PANIC\n");
        },
        else => {}, // don't trigger any more panics
    }
}

fn buildMemoryLayout(memory_layout: *kernel.system.MemoryLayout) !void {
    const base_address = boot.kernelBaseAddress() orelse return error.KernelBaseAddressNotProvided;

    log.debug("kernel virtual base address: {}", .{base_address.virtual});
    log.debug("kernel physical base address: {}", .{base_address.physical});

    const virtual_offset: core.Size = .from(base_address.virtual.value - kernel.config.kernel_base_address.value, .byte);
    const physical_to_virtual_offset: core.Size = .from(base_address.virtual.value - base_address.physical.value, .byte);
    log.debug("kernel virtual offset: 0x{x}", .{virtual_offset.value});
    log.debug("kernel physical to virtual offset: 0x{x}", .{physical_to_virtual_offset.value});

    memory_layout.* = .{
        .virtual_base_address = base_address.virtual,
        .virtual_offset = virtual_offset,
        .physical_to_virtual_offset = physical_to_virtual_offset,
    };

    try registerKernelSections(memory_layout);
    try registerDirectMaps(memory_layout);

    memory_layout.sortMemoryLayout();

    if (log.levelEnabled(.debug)) {
        log.debug("kernel memory layout:", .{});

        for (memory_layout.layout.constSlice()) |region| {
            log.debug("\t{}", .{region});
        }
    }
}

/// Registers the kernel sections in the memory layout.
fn registerKernelSections(memory_layout: *kernel.system.MemoryLayout) !void {
    const linker_symbols = struct {
        extern const __text_start: u8;
        extern const __text_end: u8;
        extern const __rodata_start: u8;
        extern const __rodata_end: u8;
        extern const __data_start: u8;
        extern const __data_end: u8;
    };

    const sdf_slice = kernel.debug.sdfSlice();
    const sdf_range = core.VirtualRange.fromSlice(u8, sdf_slice);

    const sections: []const struct {
        core.VirtualAddress,
        core.VirtualAddress,
        kernel.system.MemoryLayout.Region.Type,
    } = &.{
        .{
            core.VirtualAddress.fromPtr(&linker_symbols.__text_start),
            core.VirtualAddress.fromPtr(&linker_symbols.__text_end),
            .executable_section,
        },
        .{
            core.VirtualAddress.fromPtr(&linker_symbols.__rodata_start),
            core.VirtualAddress.fromPtr(&linker_symbols.__rodata_end),
            .readonly_section,
        },
        .{
            core.VirtualAddress.fromPtr(&linker_symbols.__data_start),
            core.VirtualAddress.fromPtr(&linker_symbols.__data_end),
            .writeable_section,
        },
        .{
            sdf_range.address,
            sdf_range.endBound(),
            .sdf_section,
        },
    };

    for (sections) |section| {
        const start_address = section[0];
        const end_address = section[1];
        const region_type = section[2];

        std.debug.assert(end_address.greaterThan(start_address));

        const virtual_range: core.VirtualRange = .fromAddr(
            start_address,
            core.Size.from(end_address.value - start_address.value, .byte)
                .alignForward(arch.paging.standard_page_size),
        );

        memory_layout.registerRegion(.{ .range = virtual_range, .type = region_type });
    }
}

fn registerDirectMaps(memory_layout: *kernel.system.MemoryLayout) !void {
    const direct_map_size = try calculateSizeOfDirectMap();

    const bootloader_direct_map_range = core.VirtualRange.fromAddr(
        boot.directMapAddress() orelse return error.DirectMapAddressNotProvided,
        direct_map_size,
    );

    // does the bootloader range overlap a pre-existing region?
    for (memory_layout.layout.constSlice()) |region| {
        if (region.range.containsRange(bootloader_direct_map_range)) {
            log.err(
                \\direct map overlaps another memory region:
                \\  direct map: {}
                \\  other region: {}
            , .{ bootloader_direct_map_range, region });

            return error.DirectMapOverlapsRegion;
        }
    }

    memory_layout.direct_map = bootloader_direct_map_range;
    memory_layout.registerRegion(.{
        .range = bootloader_direct_map_range,
        .type = .direct_map,
    });

    const range = findFreeRangeForDirectMap(
        memory_layout,
        direct_map_size,
        arch.paging.largest_page_size,
    ) orelse {
        core.panic("unable to find free memory region for the non-cached direct map", @errorReturnTrace());
    };
    memory_layout.non_cached_direct_map = range;
    memory_layout.registerRegion(.{
        .range = range,
        .type = .non_cached_direct_map,
    });
}

/// Calculates the size of the direct map.
fn calculateSizeOfDirectMap() !core.Size {
    const last_memory_map_entry = blk: {
        var memory_map_iterator = boot.memoryMap(.backward) orelse return error.NoMemoryMap;
        while (memory_map_iterator.next()) |memory_map_entry| {
            if (memory_map_entry.range.address.equal(core.PhysicalAddress.fromInt(0x000000fd00000000))) {
                log.debug("skipping weird QEMU memory map entry: {}", .{memory_map_entry});
                // this is a qemu specific hack to not have a 1TiB direct map
                // this `0xfd00000000` memory region is not listed in qemu's `info mtree` but the bootloader reports it
                continue;
            }
            break :blk memory_map_entry;
        }
        return error.NoMemoryMapEntries;
    };

    var direct_map_size = core.Size.from(last_memory_map_entry.range.last().value, .byte);

    // We ensure that the lowest 4GiB are always mapped.
    const four_gib = core.Size.from(4, .gib);
    if (direct_map_size.lessThan(four_gib)) direct_map_size = four_gib;

    // We align the length of the direct map to `largest_page_size` to allow large pages to be used for the mapping.
    direct_map_size.alignForwardInPlace(arch.paging.largest_page_size);

    return direct_map_size;
}

fn findFreeRangeForDirectMap(memory_layout: *kernel.system.MemoryLayout, size: core.Size, alignment: core.Size) ?core.VirtualRange {
    memory_layout.sortMemoryLayout();

    const regions = memory_layout.layout.constSlice();

    var current_address = arch.paging.higher_half_start;
    current_address.alignForwardInPlace(alignment);

    var i: usize = 0;

    while (true) {
        const region = if (i < memory_layout.layout.len) regions[i] else {
            const size_of_free_range = core.Size.from(
                (arch.paging.largest_higher_half_virtual_address.value) - current_address.value,
                .byte,
            );

            if (size_of_free_range.lessThan(size)) return null;

            return core.VirtualRange.fromAddr(current_address, size);
        };

        const region_address = region.range.address;

        if (region_address.lessThanOrEqual(current_address)) {
            current_address = region.range.endBound();
            current_address.alignForwardInPlace(alignment);
            i += 1;
            continue;
        }

        const size_of_free_range = core.Size.from(
            (region_address.value - 1) - current_address.value,
            .byte,
        );

        if (size_of_free_range.lessThan(size)) {
            current_address = region.range.endBound();
            current_address.alignForwardInPlace(alignment);
            i += 1;
            continue;
        }

        return core.VirtualRange.fromAddr(current_address, size);
    }
}

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const boot = @import("boot");
const arch = @import("arch");
const log = kernel.log.scoped(.init);
