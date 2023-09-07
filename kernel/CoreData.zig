// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const CoreData = @This();

core_id: usize,

arch: kernel.arch.ArchCoreData = .{},
