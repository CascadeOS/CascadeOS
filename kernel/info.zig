// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const builtin = @import("builtin");
const core = @import("core");
const kernel = @import("kernel");
const kernel_options = @import("kernel_options");
const std = @import("std");
const target_options = @import("cascade_target");

pub const mode: std.builtin.OptimizeMode = builtin.mode;
pub const arch = target_options.arch;
pub const version = kernel_options.cascade_version;
pub const root_path = kernel_options.root_path;

/// Code in this section is only used during kernel initialization and is unmapped afterwards.
pub const init_code = ".init_text"; // This must be kept in sync with the linker scripts.

/// Data in this section is only used during kernel initialization and is unmapped afterwards.
pub const init_data = ".init_data"; // This must be kept in sync with the linker scripts.

// This must be kept in sync with the linker scripts.
pub const kernel_base_address = kernel.VirtualAddress.fromInt(0xffffffff80000000);

/// Initialized during `initKernelStage1`.
pub var kernel_virtual_base_address: kernel.VirtualAddress = undefined;

/// Initialized during `initKernelStage1`.
pub var kernel_physical_base_address: kernel.PhysicalAddress = undefined;

/// Initialized during `initKernelStage1`.
pub var kernel_virtual_slide: ?core.Size = null;

/// Initialized during `initKernelStage1`.
pub var kernel_physical_to_virtual_offset: core.Size = undefined;

/// This direct map provides an identity mapping between virtual and physical addresses.
///
/// Initialized during `initKernelStage1`.
pub var direct_map: kernel.VirtualRange = undefined;

/// This direct map provides an identity mapping between virtual and physical addresses.
///
/// The page tables used disable caching for this range.
///
/// Initialized during `initKernelStage1`.
pub var non_cached_direct_map: kernel.VirtualRange = undefined;

/// This is the kernel's ELF file.
///
/// Initialized during `initKernelStage1`.
pub var kernel_file: ?kernel.VirtualRange = null;

/// The hypervisor we are running on or null if we are not running on a hypervisor.
pub var hypervisor: ?Hypervisor = null;

pub const Hypervisor = enum {
    kvm,
    tcg,
    hyperv,
    vmware,
    unknown,
};
