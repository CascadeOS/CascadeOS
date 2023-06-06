// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");

pub const arch = @import("arch/arch.zig");
pub const boot = @import("boot/boot.zig");
pub const debug = @import("debug.zig");
pub const info = @import("info.zig");
pub const log = @import("log.zig");
pub const pmm = @import("pmm.zig");
pub const setup = @import("setup.zig");
pub const vmm = @import("vmm.zig");

const addr = @import("addr.zig");
pub const PhysAddr = addr.PhysAddr;
pub const VirtAddr = addr.VirtAddr;
pub const PhysRange = addr.PhysRange;
pub const VirtRange = addr.VirtRange;

comptime {
    // make sure any bootloader specific code that needs to be referenced is
    _ = boot;

    // ensure any architecture specific code that needs to be referenced is
    _ = arch;
}
