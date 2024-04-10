// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const eternal_heap = @import("eternal_heap.zig");
const page_heap = @import("page_heap.zig");

pub const eternal_heap_allocator = eternal_heap.allocator;
pub const page_heap_allocator = page_heap.allocator;

pub const init = struct {
    pub fn initHeaps(
        kernel_eternal_heap_range: core.VirtualRange,
        kernel_page_heap_range: core.VirtualRange,
    ) !void {
        eternal_heap.init.initEternalHeap(kernel_eternal_heap_range);
        try page_heap.init.initPageHeap(kernel_page_heap_range);
    }
};
