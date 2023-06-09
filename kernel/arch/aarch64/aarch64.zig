// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const arch = @import("../arch.zig");

pub const setup = @import("setup.zig");
pub const Uart = @import("Uart.zig");

pub inline fn spinLoopHint() void {
    asm volatile ("isb" ::: "memory");
}

pub const interrupts = struct {
    /// Disable interrupts and put the CPU to sleep.
    pub fn disableInterruptsAndHalt() noreturn {
        while (true) {
            asm volatile ("msr DAIFSet, #0b1111");
            asm volatile ("wfe");
        }
    }

    /// Disable interrupts.
    pub inline fn disableInterrupts() void {
        asm volatile ("msr DAIFSet, #0b1111");
    }

    /// Disable interrupts.
    pub inline fn enableInterrupts() void {
        asm volatile ("msr DAIFClr, #0b1111;");
    }

    /// Are interrupts enabled?
    pub inline fn interruptsEnabled() bool {
        return false; // TODO: Actually figure this out https://github.com/CascadeOS/CascadeOS/issues/46
    }
};

pub const paging = struct {
    // TODO: Is this correct for aarch64? https://github.com/CascadeOS/CascadeOS/issues/23
    pub const small_page_size = core.Size.from(4, .kib);
    pub const medium_page_size = core.Size.from(2, .mib);
    pub const large_page_size = core.Size.from(1, .gib);

    pub const standard_page_size = small_page_size;

    pub inline fn largestPageSize() core.Size {
        return large_page_size;
    }

    pub const page_sizes_available = [_]bool{
        true,
        true,
        true,
    };

    // TODO: Is this correct for aarch64? https://github.com/CascadeOS/CascadeOS/issues/23
    pub const higher_half = kernel.VirtualAddress.fromInt(0xffff800000000000);

    // TODO: implement paging https://github.com/CascadeOS/CascadeOS/issues/23
    pub const PageTable = struct {
        pub fn zero(self: *PageTable) void {
            _ = self;
            core.panic("UNIMPLEMENTED `zero`"); // TODO: Implement `zero`.
        }
    };

    /// This function is only called once during system setup, it is required to:
    ///   1. search the high half of the *top level* of the given page table for a free entry
    ///   2. allocate a backing frame for it
    ///   3. map the free entry to the fresh backing frame and ensure it is zeroed
    ///   4. return the `VirtualRange` representing the entire virtual range that entry covers
    pub fn getHeapRangeAndFillFirstLevel(page_table: *PageTable) arch.paging.MapError!kernel.VirtualRange {
        _ = page_table;
        core.panic("UNIMPLEMENTED `getHeapRangeAndFillFirstLevel`"); // TODO: implement paging https://github.com/CascadeOS/CascadeOS/issues/23
    }

    const MapError = arch.paging.MapError;

    pub fn mapRange(
        page_table: *PageTable,
        virtual_range: kernel.VirtualRange,
        physical_range: kernel.PhysicalRange,
        map_type: kernel.vmm.MapType,
    ) MapError!void {
        _ = map_type;
        _ = physical_range;
        _ = virtual_range;
        _ = page_table;
        core.panic("UNIMPLEMENTED `mapRange`"); // TODO: implement paging https://github.com/CascadeOS/CascadeOS/issues/23
    }

    pub fn mapRangeUseAllPageSizes(
        page_table: *PageTable,
        virtual_range: kernel.VirtualRange,
        physical_range: kernel.PhysicalRange,
        map_type: kernel.vmm.MapType,
    ) MapError!void {
        _ = map_type;
        _ = physical_range;
        _ = virtual_range;
        _ = page_table;
        core.panic("UNIMPLEMENTED `mapRangeUseAllPageSizes`"); // TODO: implement paging https://github.com/CascadeOS/CascadeOS/issues/23
    }

    pub fn switchToPageTable(page_table: *const PageTable) void {
        _ = page_table;
        core.panic("UNIMPLEMENTED `switchToPageTable`"); // TODO: implement paging https://github.com/CascadeOS/CascadeOS/issues/23
    }

    pub fn allocatePageTable() *PageTable {
        core.panic("UNIMPLEMENTED `allocatePageTable`"); // TODO: implement paging https://github.com/CascadeOS/CascadeOS/issues/23
    }
};

comptime {
    if (kernel.info.arch != .aarch64) {
        @compileError("aarch64 implementation has been referenced when building " ++ @tagName(kernel.info.arch));
    }
}
