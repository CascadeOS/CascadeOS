// SPDX-License-Identifier: MIT

const std = @import("std");
const kernel = @import("root");
const aarch64 = @import("aarch64.zig");

pub const PhysAddr = extern struct {
    value: usize,

    pub fn fromInt(value: usize) VirtAddr {
        return .{ .value = value };
    }
};

pub const VirtAddr = extern struct {
    value: usize,

    pub fn fromInt(value: usize) VirtAddr {
        return .{ .value = value };
    }
};
