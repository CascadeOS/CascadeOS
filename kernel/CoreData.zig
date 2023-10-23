// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const CoreData = @This();

core_id: usize,

panicked: bool = false,

_arch: kernel.arch.ArchCoreData = .{},

pub inline fn arch(self: *CoreData) *kernel.arch.ArchCoreData {
    return &self._arch;
}
