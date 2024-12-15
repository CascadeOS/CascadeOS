// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

pub const MapType = @import("MapType.zig");

/// The core page table.
///
/// All other page tables start as a copy of this one.
///
/// Initialized during `init.initializeVirtualMemory`.
pub var core_page_table: arch.paging.PageTable = undefined;

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");
const arch = @import("arch");
