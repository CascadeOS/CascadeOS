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

var kernel_state: State = .initial;

pub inline fn state() State {
    return kernel_state;
}

pub fn setState(new_state: State) void {
    std.debug.assert(@intFromEnum(new_state) > @intFromEnum(kernel_state));
    kernel_state = new_state;
}

pub const State = enum(u8) {
    /// Control has been passed to the kernel from the bootloader.
    initial,

    /// The bootstrap core data has been loaded.
    bootstrap_core_data_loaded,

    /// Early output has been initialized.
    early_output_initialized,

    /// Bootloader information has been captured.
    bootloader_information_captured,

    /// System information has been captured.
    system_information_captured,

    /// The virtual memory manager has been initialized.
    vmm_initialized,

    pub inline fn atleast(self: State, required_state: State) bool {
        return @intFromEnum(required_state) <= @intFromEnum(self);
    }
};

comptime {
    // make sure any bootloader specific code that needs to be referenced is
    _ = boot;

    // ensure any architecture specific code that needs to be referenced is
    _ = arch;
}
