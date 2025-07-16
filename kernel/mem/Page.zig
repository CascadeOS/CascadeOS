// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const Page = @This();

physical_frame: kernel.mem.phys.Frame,

node: std.SinglyLinkedList.Node = .{},

pub inline fn fromNode(node: *std.SinglyLinkedList.Node) *Page {
    return @fieldParentPtr("node", node);
}

pub const Region = struct {
    start_frame: kernel.mem.phys.Frame,
    number_of_frames: u32,
    start_index: u32,

    pub fn compareContainsFrame(region: Region, frame: kernel.mem.phys.Frame) std.math.Order {
        const frame_num = @intFromEnum(frame);
        const start_frame_num = @intFromEnum(region.start_frame);

        if (frame_num < start_frame_num) return .lt;
        if (frame_num >= start_frame_num + region.number_of_frames) return .gt;
        return .eq;
    }
};

pub const Index = enum(u32) {
    _,
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
