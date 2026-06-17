// SPDX-License-Identifier: BSD-3-Clause
// SPDX-FileCopyrightText: CascadeOS Contributors

const std = @import("std");

const cascade = @import("cascade");
const core = @import("core");

const x64 = @import("../x64.zig");
pub const PageFaultErrorCode = @import("PageFaultErrorCode.zig").PageFaultErrorCode;
pub const PageTable = @import("PageTable.zig").PageTable;

/// Flushes the cache for the given virtual range on the current executor.
///
/// The `virtual_range` address and size must be aligned to the standard page size.
pub fn flushCache(virtual_range: cascade.VirtualRange) void {
    if (core.is_debug) std.debug.assert(virtual_range.pageAligned());

    var current_virtual_address = virtual_range.address;
    const terminating_virtual_address = virtual_range.after();

    while (current_virtual_address.lessThan(terminating_virtual_address)) {
        x64.instructions.invlpg(current_virtual_address);

        current_virtual_address.moveForwardPageInPlace();
    }
}

/// Copies memory from `source` to `destination`.
///
/// Sets `target` to the address any unhandleable page fault should return to after setting the result in the slot.
pub fn safeMemcpy(
    destination: cascade.VirtualRange,
    source: cascade.VirtualRange,
    target: *cascade.KernelVirtualAddress,
) void {
    asm volatile (
        \\lea 1f(%rip), %rax
        \\mov %rax, (%[target])
        \\
        \\rep movsb
        \\
        \\1:
        :
        : [target] "r" (target),
          [source_ptr] "+{rsi}" (source.address.value),
          [destination_ptr] "+{rdi}" (destination.address.value),
          [count] "+{rcx}" (source.size.value),
        : .{ .rax = true, .memory = true });
}
