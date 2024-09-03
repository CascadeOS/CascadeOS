// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

/// Array of all executors.
///
/// Initialized during init and never modified again.
pub var executors: []kernel.Executor = &.{};

/// The memory layout of the kernel.
///
/// Initialized during `init.buildMemoryLayout`.
pub var memory_layout: MemoryLayout = .{};

pub const MemoryLayout = struct {
    /// The virtual base address that the kernel was loaded at.
    virtual_base_address: core.VirtualAddress = kernel.config.kernel_base_address,

    /// The offset from the requested ELF virtual base address to the address that the kernel was actually loaded at.
    ///
    /// This is optional due to the small window on start up where the panic handler can run before this is set.
    virtual_offset: ?core.Size = null,

    /// Offset from the virtual address of kernel sections to the physical address of the section.
    physical_to_virtual_offset: ?core.Size = null,
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
