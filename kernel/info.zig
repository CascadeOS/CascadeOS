// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const builtin = @import("builtin");
const kernel_options = @import("kernel_options");

pub const mode: std.builtin.OptimizeMode = builtin.mode;
pub const arch = kernel_options.arch;
pub const version = kernel_options.version;

// This must be kept in sync with the linker scripts.
pub const kernel_base_address = kernel.VirtAddr.fromInt(0xffffffff80000000);

/// This is the offset from `kernel_base_address` that the kernel has been loaded at.
/// This would be zero is not for kaslr.
pub var kernel_offset_from_base: core.Size = core.Size.zero;

/// This is the offset from the physical address of the kernel to the virtual address of the kernel.
pub var kernel_offset_from_physical: core.Size = core.Size.zero;

/// This direct map provides an identity mapping between virtual and physical addresses.
pub var direct_map = kernel.VirtRange.fromAddr(kernel.VirtAddr.zero, core.Size.zero);

/// This direct map provides an identity mapping between virtual and physical addresses.
/// The page tables used disable caching for this range.
pub var non_cached_direct_map = kernel.VirtRange.fromAddr(kernel.VirtAddr.zero, core.Size.zero);
