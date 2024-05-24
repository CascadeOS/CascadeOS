// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const eternal_heap = @import("eternal_heap.zig");

pub const eternal_heap_allocator = eternal_heap.allocator;

pub const init = struct {
    pub fn initHeaps() !void {
        eternal_heap.init.initEternalHeap(try findHeapRange(.eternal_heap));
    }

    fn findHeapRange(heap_type: kernel.vmm.MemoryLayout.Region.Type) !core.VirtualRange {
        for (kernel.vmm.memory_layout.layout.constSlice()) |region| {
            if (region.type == heap_type) return region.range;
        }
        return error.HeapRangeNotFound;
    }
};
