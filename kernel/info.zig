// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const builtin = @import("builtin");
const kernel_options = @import("kernel_options");

pub const mode: std.builtin.OptimizeMode = builtin.mode;
pub const arch = kernel_options.arch;
pub const version = kernel_options.version;
pub const root_path = kernel_options.root_path;

// This must be kept in sync with the linker scripts.
pub const kernel_base_address = kernel.VirtAddr.fromInt(0xffffffff80000000);

/// Initialized during `setup`.
pub var kernel_virtual_address: kernel.VirtAddr = undefined;

/// Initialized during `setup`.
pub var kernel_physical_address: kernel.PhysAddr = undefined;

/// This is the offset from `kernel_base_address` that the kernel has been loaded at.
/// This would always be zero if not for kaslr.
///
/// Initialized during `setup`.
pub var kernel_offset_from_base: core.Size = undefined;

/// This is the offset from the physical address of the kernel to the virtual address of the kernel.
///
/// Initialized during `setup`.
pub var kernel_virtual_offset_from_physical: core.Size = undefined;

/// This direct map provides an identity mapping between virtual and physical addresses.
///
/// Initialized during `setup`.
pub var direct_map: kernel.VirtRange = undefined;

/// This direct map provides an identity mapping between virtual and physical addresses.
/// The page tables used disable caching for this range.
///
/// Initialized during `setup`.
pub var non_cached_direct_map: kernel.VirtRange = undefined;

/// This is the kernel's ELF file.
///
/// Initialized during `setup`.
pub var kernel_file: []const u8 = undefined;

const log = kernel.log.scoped(.info);
