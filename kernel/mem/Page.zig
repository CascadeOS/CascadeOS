// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const Page = @This();

physical_frame: kernel.mem.phys.Frame,

state: State,

pub const State = union(enum) {
    in_use,
    free: Free,

    pub const Free = struct {
        /// The node in the free list `kernel.mem.phys.globals.free_page_list`.
        free_list_node: containers.SingleNode = .empty,
    };
};

pub fn fromFreeListNode(free_list_node: *containers.SingleNode) *Page {
    // TODO: is this really the way to do this?
    const free: *kernel.mem.Page.State.Free = @fieldParentPtr("free_list_node", free_list_node);
    const state: *kernel.mem.Page.State = @fieldParentPtr("free", free);
    return @fieldParentPtr("state", state);
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
