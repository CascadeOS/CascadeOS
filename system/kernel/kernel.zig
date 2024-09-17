// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

/// Array of all executors.
///
/// Initialized during init and never modified again.
pub var executors: []Executor = &.{};

/// The core page table.
///
/// All other page tables start as a copy of this one.
///
/// Initialized during `init.initializeVirtualMemory`.
pub var core_page_table: arch.paging.PageTable = undefined;

/// The memory layout of the kernel.
///
/// Initialized during `init.buildMemoryLayout`.
pub const memory_layout = @import("memory_layout.zig");

pub const acpi = @import("acpi.zig");
pub const config = @import("config.zig");
pub const debug = @import("debug.zig");
pub const Executor = @import("Executor.zig");
pub const log = @import("log.zig");
pub const Stack = @import("Stack.zig");
pub const time = @import("time.zig");
pub const vmm = @import("vmm.zig");

const std = @import("std");
const core = @import("core");
const arch = @import("arch");
