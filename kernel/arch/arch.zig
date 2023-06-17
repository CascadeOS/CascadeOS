// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

pub const aarch64 = @import("aarch64/aarch64.zig");
pub const x86_64 = @import("x86_64/x86_64.zig");

comptime {
    // ensure any architecture specific code is referenced
    _ = current;
}

const current = switch (kernel.info.arch) {
    .aarch64 => aarch64,
    .x86_64 => x86_64,
};

pub inline fn spinLoopHint() void {
    current.spinLoopHint();
}

/// Functionality that is intended to be used during system setup only.
pub const setup = struct {
    /// Attempt to set up some form of early output.
    pub inline fn setupEarlyOutput() void {
        current.setup.setupEarlyOutput();
    }

    pub const EarlyOutputWriter = current.setup.EarlyOutputWriter;

    /// Acquire a `std.io.Writer` for the early output setup by `setupEarlyOutput`.
    pub inline fn getEarlyOutputWriter() EarlyOutputWriter {
        return current.setup.getEarlyOutputWriter();
    }

    /// Initialize the architecture specific registers and structures into the state required for early setup.
    /// One of the requirements of this function is to ensure that any exceptions/faults that occur are correctly handled.
    ///
    /// For example, on x86_64 this should setup a GDT, TSS and IDT then install a simple handler on every vector.
    pub inline fn earlyArchInitialization() void {
        current.setup.earlyArchInitialization();
    }

    /// Capture any system information that is required for the architecture.
    ///
    /// For example, on x86_64 this should capture the CPUID information.
    pub inline fn captureSystemInformation() void {
        current.setup.captureSystemInformation();
    }

    /// Configure any system features.
    ///
    /// For example, on x86_64 this should enable any CPU features that are required.
    pub inline fn configureSystemFeatures() void {
        current.setup.configureSystemFeatures();
    }
};

pub const interrupts = struct {
    /// Disable interrupts and put the CPU to sleep.
    pub inline fn disableInterruptsAndHalt() noreturn {
        current.interrupts.disableInterruptsAndHalt();
    }

    /// Disable interrupts.
    pub inline fn disableInterrupts() void {
        current.interrupts.disableInterrupts();
    }

    /// Enable interrupts.
    pub inline fn enableInterrupts() void {
        current.interrupts.enableInterrupts();
    }

    /// Are interrupts enabled?
    pub inline fn interruptsEnabled() bool {
        return current.interrupts.interruptsEnabled();
    }
};

pub const paging = struct {
    pub const standard_page_size: core.Size = current.paging.standard_page_size;

    pub inline fn largestPageSize() core.Size {
        return current.paging.largestPageSize();
    }

    pub const higher_half: kernel.VirtAddr = current.paging.higher_half;

    pub const PageTable: type = current.paging.PageTable;

    pub inline fn allocatePageTable() error{PageAllocationFailed}!*PageTable {
        return current.paging.allocatePageTable();
    }

    /// This function is only called once during system setup, it is required to:
    ///   1. search the high half of the *top level* of the given page table for a free entry
    ///   2. allocate a backing frame for it
    ///   3. map the free entry to the fresh backing frame and ensure it is zeroed
    ///   4. return the `VirtRange` representing the entire virtual range that entry covers
    pub inline fn getHeapRangeAndFillFirstLevel(page_table: *PageTable) MapError!kernel.VirtRange {
        return current.paging.getHeapRangeAndFillFirstLevel(page_table);
    }

    pub const MapError = error{
        AlreadyMapped,
        AllocationFailed,
        Unexpected,
    };

    /// Maps the `virtual_range` to the `physical_range` with mapping type given by `map_type`.
    /// This function will only use the architecture's `standard_page_size`.
    pub inline fn mapRange(
        page_table: *PageTable,
        virtual_range: kernel.VirtRange,
        physical_range: kernel.PhysRange,
        map_type: kernel.vmm.MapType,
    ) MapError!void {
        return current.paging.mapRange(page_table, virtual_range, physical_range, map_type);
    }

    /// Maps the `virtual_range` to the `physical_range` with mapping type given by `map_type`.
    /// This function is allowed to use all page sizes available to the architecture.
    pub inline fn mapRangeUseAllPageSizes(
        page_table: *PageTable,
        virtual_range: kernel.VirtRange,
        physical_range: kernel.PhysRange,
        map_type: kernel.vmm.MapType,
    ) MapError!void {
        return current.paging.mapRangeUseAllPageSizes(page_table, virtual_range, physical_range, map_type);
    }

    pub inline fn switchToPageTable(page_table: *const PageTable) void {
        current.paging.switchToPageTable(page_table);
    }
};
