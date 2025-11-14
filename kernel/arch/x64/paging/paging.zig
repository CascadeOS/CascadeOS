// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const Task = cascade.Task;
const core = @import("core");

const x64 = @import("../x64.zig");
pub const PageFaultErrorCode = @import("PageFaultErrorCode.zig").PageFaultErrorCode;
pub const PageTable = @import("PageTable.zig").PageTable;

const log = cascade.debug.log.scoped(.paging);

/// Flushes the cache for the given virtual range on the current executor.
///
/// The `virtual_range` address and size must be aligned to the standard page size.
pub fn flushCache(current_task: Task.Current, virtual_range: core.VirtualRange) void {
    _ = current_task;

    if (core.is_debug) {
        std.debug.assert(virtual_range.address.isAligned(PageTable.small_page_size));
        std.debug.assert(virtual_range.size.isAligned(PageTable.small_page_size));
    }

    var current_virtual_address = virtual_range.address;
    const last_virtual_address = virtual_range.last();

    while (current_virtual_address.lessThanOrEqual(last_virtual_address)) {
        x64.instructions.invlpg(current_virtual_address);

        current_virtual_address.moveForwardInPlace(PageTable.small_page_size);
    }
}
