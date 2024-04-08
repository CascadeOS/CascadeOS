// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

var heap_address_space_mutex: kernel.sync.Mutex = .{};
var heap_address_space: kernel.vmm.AddressSpace = undefined; // Initialized in `initHeap`

pub const init = struct {
    pub fn initHeap(kernel_heap_range: core.VirtualRange) !void {
        heap_address_space = try kernel.vmm.AddressSpace.init(kernel_heap_range);
    }
};
