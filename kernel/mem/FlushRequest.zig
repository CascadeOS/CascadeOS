// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const FlushRequest = @This();

range: core.VirtualRange,
flush_target: kernel.Mode,
count: std.atomic.Value(usize) = .init(1), // starts at `1` to account for the current executor
nodes: std.BoundedArray(Node, kernel.config.maximum_number_of_executors) = .{},

pub const Node = struct {
    request: *FlushRequest,
    node: containers.SingleNode,
};

pub fn submitAndWait(self: *FlushRequest, current_task: *kernel.Task) void {
    current_task.incrementPreemptionDisable();
    defer current_task.decrementPreemptionDisable();

    switch (self.flush_target) {
        .kernel => {
            for (kernel.executors) |*executor| {
                if (executor == current_task.state.running) continue;
                self.requestExecutor(executor);
            }
        },
        .user => @panic("NOT IMPLEMENTED"),
    }

    self.flush(current_task);
    self.waitForCompletion();
}

pub fn flush(self: *FlushRequest, current_task: *const kernel.Task) void {
    _ = current_task;

    switch (self.flush_target) {
        .kernel => {},
        .user => @panic("NOT IMPLEMENTED"),
    }

    kernel.arch.paging.flushCache(self.range);

    _ = self.count.fetchSub(1, .acq_rel);
}

fn requestExecutor(self: *FlushRequest, executor: *kernel.Executor) void {
    _ = self.count.fetchAdd(1, .acq_rel);

    const node = self.nodes.addOne() catch @panic("exceeded maximum number of executors");
    node.* = .{
        .request = self,
        .node = .empty,
    };
    executor.flush_requests.push(&node.node);

    kernel.arch.interrupts.sendFlushIPI(executor);
}

fn waitForCompletion(self: *FlushRequest) void {
    while (self.count.load(.acquire) > 0) {
        kernel.arch.spinLoopHint();
    }
}

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const containers = @import("containers");
