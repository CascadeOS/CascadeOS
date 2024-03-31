// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const Process = @This();

id: Id,
_name: Name,

pub fn name(self: *const Process) []const u8 {
    return self._name.constSlice();
}

pub inline fn isKernel(self: *const Process) bool {
    return self.id == .kernel;
}

pub const Name = std.BoundedArray(u8, kernel.config.process_name_length);
pub const Id = enum(u64) {
    kernel = 0,

    _,
};
