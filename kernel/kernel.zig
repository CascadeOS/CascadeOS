// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");

pub const arch = @import("arch.zig");
pub const boot = @import("boot.zig");
pub const debug = @import("debug.zig");
pub const heap = @import("heap.zig");
pub const info = @import("info.zig");
pub const init = @import("init.zig");
pub const log = @import("log.zig");
pub const pmm = @import("pmm.zig");
pub const vmm = @import("vmm.zig");

pub const SpinLock = @import("SpinLock.zig");

pub const Processor = @import("Processor.zig");
pub const Stack = @import("Stack.zig");

const address = @import("address.zig");
pub const PhysicalAddress = address.PhysicalAddress;
pub const VirtualAddress = address.VirtualAddress;
pub const PhysicalRange = address.PhysicalRange;
pub const VirtualRange = address.VirtualRange;

comptime {
    // make sure any bootloader specific code that needs to be referenced is
    _ = boot;

    // ensure any architecture specific code that needs to be referenced is
    _ = arch;
}
