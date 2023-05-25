// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("../kernel.zig");

const arch = @import("arch.zig");

/// This namespace is intended to be `pub usingnamespace`ed in the root file of each arch.
///
/// ### Example
/// ```zig
/// pub usingnamespace @import("../arch_helpers.zig").useful_arch_exports;
/// ```
pub const useful_arch_exports = struct {
    pub const PhysAddr = arch.PhysAddr;
    pub const VirtAddr = arch.VirtAddr;
};
