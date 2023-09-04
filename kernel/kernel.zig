// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");

pub const arch = @import("arch/arch.zig");
pub const boot = @import("boot/boot.zig");
pub const debug = @import("debug/debug.zig");
pub const info = @import("info.zig");
pub const log = @import("log.zig");
pub const pmm = @import("pmm.zig");
pub const setup = @import("setup.zig");
pub const vmm = @import("vmm.zig");

pub const CoreData = @import("CoreData.zig");

pub const SpinLock = @import("SpinLock.zig");

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
