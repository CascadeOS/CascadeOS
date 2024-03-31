// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");

const Thread = @This();

id: Id,
_name: Name,

state: State = .ready,

process: *kernel.Process,

kernel_stack: kernel.Stack,

next_thread: ?*Thread = null,

pub inline fn isKernel(self: *const Thread) bool {
    return self.process == &kernel.process;
}

pub const State = enum {
    ready,
    running,
};

pub const Name = std.BoundedArray(u8, kernel.config.thread_name_length);
pub const Id = enum(u64) {
    _,
};
