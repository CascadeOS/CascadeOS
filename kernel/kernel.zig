// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

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

pub const std_options = struct {
    // ensure using `std.log` in the kernel is a compile error
    pub const log_level = @compileError("use `kernel.log` for logging in the kernel");

    // ensure using `std.log` in the kernel is a compile error
    pub const logFn = @compileError("use `kernel.log` for logging in the kernel");
};

pub const panic = debug.panic;
