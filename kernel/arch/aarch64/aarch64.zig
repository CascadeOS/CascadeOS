// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const arch = @import("../arch.zig");

pub const setup = @import("setup.zig");
pub const Uart = @import("Uart.zig");

pub const interrupts = struct {
    /// Disable interrupts and put the CPU to sleep.
    pub fn disableInterruptsAndHalt() noreturn {
        while (true) {
            asm volatile ("MSR DAIFSET, #0xF;");
        }
    }
};

pub const paging = struct {
    // TODO: Is this correct for aarch64? https://github.com/CascadeOS/CascadeOS/issues/22
    pub const small_page_size = core.Size.from(4, .kib);
    pub const medium_page_size = core.Size.from(2, .mib);
    pub const large_page_size = core.Size.from(1, .gib);

    pub const standard_page_size = small_page_size;
    pub const largest_page_size = large_page_size;

    pub const page_sizes_available = [_]bool{
        true,
        true,
        true,
    };

    // TODO: Is this correct for aarch64? https://github.com/CascadeOS/CascadeOS/issues/22
    pub const higher_half = kernel.VirtAddr.fromInt(0xffff800000000000);

    // TODO: implement paging https://github.com/CascadeOS/CascadeOS/issues/23
    pub const PageTable = struct {
        pub fn zero(self: *PageTable) void {
            _ = self;
            core.panic("UNIMPLEMENTED `zero`"); // TODO: Implement `zero`.
        }
    };

    const MapError = arch.paging.MapError;

    pub fn mapRegion(
        page_table: *PageTable,
        virtual_range: kernel.VirtRange,
        physical_range: kernel.PhysRange,
        map_type: kernel.vmm.MapType,
    ) MapError!void {
        _ = map_type;
        _ = physical_range;
        _ = virtual_range;
        _ = page_table;
        core.panic("UNIMPLEMENTED `mapRegion`"); // TODO: implement paging https://github.com/CascadeOS/CascadeOS/issues/23
    }

    pub fn mapRegionUseAllPageSizes(
        page_table: *PageTable,
        virtual_range: kernel.VirtRange,
        physical_range: kernel.PhysRange,
        map_type: kernel.vmm.MapType,
    ) MapError!void {
        _ = map_type;
        _ = physical_range;
        _ = virtual_range;
        _ = page_table;
        core.panic("UNIMPLEMENTED `mapRegionUseAllPageSizes`"); // TODO: implement paging https://github.com/CascadeOS/CascadeOS/issues/23
    }

    pub fn switchToPageTable(page_table: *const PageTable) void {
        _ = page_table;
        core.panic("UNIMPLEMENTED `switchToPageTable`"); // TODO: implement paging https://github.com/CascadeOS/CascadeOS/issues/23
    }

    pub fn allocatePageTable() *PageTable {
        core.panic("UNIMPLEMENTED `allocatePageTable`"); // TODO: implement paging https://github.com/CascadeOS/CascadeOS/issues/23
    }
};
