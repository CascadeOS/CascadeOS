// SPDX-License-Identifier: MIT

const address = @import("address.zig");

pub const acpi = @import("acpi/acpi.zig");
pub const arch = @import("arch/arch.zig");
pub const boot = @import("boot.zig");
pub const debug = @import("debug/debug.zig");
pub const heap = @import("heap/heap.zig");
pub const info = @import("info.zig");
pub const init = @import("init.zig");
pub const memory = @import("memory/memory.zig");
pub const PhysicalAddress = address.PhysicalAddress;
pub const PhysicalRange = address.PhysicalRange;
pub const Processor = @import("Processor.zig");
pub const scheduler = @import("scheduler/scheduler.zig");
pub const SpinLock = @import("SpinLock.zig");
pub const Stack = @import("Stack.zig");
pub const VirtualAddress = address.VirtualAddress;
pub const VirtualRange = address.VirtualRange;

pub var kernel_process: scheduler.Process = .{
    .id = .kernel,
    ._name = scheduler.Process.Name.fromSlice("kernel") catch unreachable,
    .page_table = undefined, // initialized in `initVirtualMemory`
};

comptime {
    // make sure any bootloader specific code that needs to be referenced is
    _ = &boot;

    // ensure any architecture specific code that needs to be referenced is
    _ = &arch;
}
