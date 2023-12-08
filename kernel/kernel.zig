// SPDX-License-Identifier: MIT

const address = @import("address.zig");
const core = @import("core");
const std = @import("std");
pub const arch = @import("arch.zig");
pub const boot = @import("boot.zig");
pub const debug = @import("debug.zig");
pub const heap = @import("heap.zig");
pub const info = @import("info.zig");
pub const init = @import("init.zig");
pub const log = @import("log.zig");
pub const PhysicalAddress = address.PhysicalAddress;
pub const PhysicalRange = address.PhysicalRange;
pub const pmm = @import("pmm.zig");
pub const Processor = @import("Processor.zig");
pub const SpinLock = @import("SpinLock.zig");
pub const Stack = @import("Stack.zig");
pub const Task = @import("Task.zig");
pub const VirtualAddress = address.VirtualAddress;
pub const VirtualRange = address.VirtualRange;
pub const vmm = @import("vmm.zig");

pub var kernel_task: Task = .{
    .id = .kernel,
    ._name = Task.Name.fromSlice("kernel") catch unreachable,
    .page_table = undefined, // initialized in `initVmm`
};

comptime {
    // make sure any bootloader specific code that needs to be referenced is
    _ = boot;

    // ensure any architecture specific code that needs to be referenced is
    _ = arch;
}
