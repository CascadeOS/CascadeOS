// SPDX-License-Identifier: MIT

const std = @import("std");
const kernel = @import("root");
const x86_64 = @import("x86_64.zig");

pub const PhysAddr = extern struct {
    value: usize,

    pub const zero = VirtAddr{ .value = 0 };

    pub fn fromInt(value: usize) VirtAddr {
        return .{ .value = value };
    }
};

pub const VirtAddr = extern struct {
    value: usize,

    pub const zero = VirtAddr{ .value = 0 };

    pub fn fromInt(value: usize) VirtAddr {
        return .{ .value = value };
    }
};
