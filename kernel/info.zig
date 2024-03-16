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
