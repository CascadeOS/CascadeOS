// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const Page = @This();

physical_frame: kernel.mem.phys.Frame,

/// The node in the free list `kernel.mem.phys.globals.free_page_list`.
node: containers.SingleNode = .empty,

pub inline fn fromNode(node: *containers.SingleNode) *Page {
    return @fieldParentPtr("node", node);
}

pub const Region = struct {
    start_frame: kernel.mem.phys.Frame,
    number_of_frames: u32,
    start_index: u32,

    pub fn compareContainsFrame(self: Region, frame: kernel.mem.phys.Frame) std.math.Order {
        const frame_num = @intFromEnum(frame);
        const start_frame_num = @intFromEnum(self.start_frame);

        if (frame_num < start_frame_num) return .lt;
        if (frame_num >= start_frame_num + self.number_of_frames) return .gt;
        return .eq;
    }
};

pub const Index = enum(u32) {
    _,
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const containers = @import("containers");
