// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

// This must be kept in sync with the linker scripts.
pub const kernel_base_address = core.VirtualAddress.fromInt(0xffffffff80000000);

/// Initialized during `init.captureKernelOffsets.
pub var kernel_virtual_base_address: core.VirtualAddress = undefined;

/// Initialized during `init.captureKernelOffsets`.
pub var kernel_physical_base_address: core.PhysicalAddress = undefined;

/// Initialized during `init.captureKernelOffsets`.
pub var kernel_virtual_slide: ?core.Size = null;

/// Initialized during `init.captureKernelOffsets`.
pub var kernel_physical_to_virtual_offset: core.Size = undefined;

/// This direct map provides an identity mapping between virtual and physical addresses.
///
/// Initialized during `init.captureDirectMaps`.
pub var direct_map: core.VirtualRange = undefined;

/// This direct map provides an identity mapping between virtual and physical addresses.
///
/// The page tables used disable caching for this range.
///
/// Initialized during `init.captureDirectMaps`.
pub var non_cached_direct_map: core.VirtualRange = undefined;
