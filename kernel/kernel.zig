// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");

pub const arch = @import("arch/arch.zig");
pub const boot = @import("boot/boot.zig");
pub const debug = @import("debug/debug.zig");
pub const heap = @import("heap/heap.zig");
pub const info = @import("info/info.zig");
pub const init = @import("init.zig");
pub const log = @import("log/log.zig");
pub const pmm = @import("pmm/pmm.zig");
pub const vmm = @import("vmm/vmm.zig");
pub const sync = @import("sync/sync.zig");

pub const AddressSpace = @import("AddressSpace.zig");
pub const DirectObjectPool = @import("DirectObjectPool.zig").DirectObjectPool;
pub const Processor = @import("Processor.zig");
pub const RangeAllocator = @import("RangeAllocator.zig");
pub const Stack = @import("Stack.zig");

const address = @import("address.zig");
pub const PhysicalAddress = address.PhysicalAddress;
pub const VirtualAddress = address.VirtualAddress;
pub const PhysicalRange = address.PhysicalRange;
pub const VirtualRange = address.VirtualRange;

/// The root page table for the kernel.
///
/// Initialized during `vmm.init`.
pub var root_page_table: *arch.paging.PageTable = undefined;

/// The memory layout of the kernel.
///
/// Populated during `vmm.init`.
pub var memory_layout: vmm.KernelMemoryLayout = .{};

comptime {
    // make sure any bootloader specific code that needs to be referenced is
    _ = boot;

    // ensure any architecture specific code that needs to be referenced is
    _ = arch;
}
