// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const arch = @import("arch.zig");

pub const PhysAddr = extern struct {
    value: usize,

    pub const zero: PhysAddr = .{ .value = 0 };

    pub fn fromInt(value: usize) PhysAddr {
        // TODO: check that the address is valid (cannoical)
        return .{ .value = value };
    }

    comptime {
        std.debug.assert(@sizeOf(PhysAddr) == @sizeOf(usize));
        std.debug.assert(@bitSizeOf(PhysAddr) == @bitSizeOf(usize));
    }
};

pub const VirtAddr = extern struct {
    value: usize,

    pub const zero: VirtAddr = .{ .value = 0 };

    pub fn fromInt(value: usize) VirtAddr {
        // TODO: check that the address is valid (cannoical)
        return .{ .value = value };
    }

    comptime {
        std.debug.assert(@sizeOf(VirtAddr) == @sizeOf(usize));
        std.debug.assert(@bitSizeOf(VirtAddr) == @bitSizeOf(usize));
    }
};
