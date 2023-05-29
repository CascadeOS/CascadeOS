// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const builtin = @import("builtin");
const kernel_options = @import("kernel_options");

pub const mode: std.builtin.OptimizeMode = builtin.mode;
pub const arch = kernel_options.arch;
pub const version = kernel_options.version;

pub var kernel_slide: core.Size = core.Size.zero;

pub var hhdm = kernel.VirtRange.fromAddr(kernel.VirtAddr.zero, core.Size.zero);
pub var non_cached_hhdm = kernel.VirtRange.fromAddr(kernel.VirtAddr.zero, core.Size.zero);
