// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const FlushRequest = @This();

range: core.VirtualRange,
flush_target: kernel.Context,
count: std.atomic.Value(usize) = .init(1), // starts at `1` to account for the current executor
nodes: std.BoundedArray(Node, kernel.config.maximum_number_of_executors) = .{},

pub const Node = struct {
    request: *FlushRequest,
    node: std.SinglyLinkedList.Node,
};

pub fn submitAndWait(flush_request: *FlushRequest, current_task: *kernel.Task) void {
    {
        current_task.incrementInterruptDisable();
        defer current_task.decrementInterruptDisable();

        const current_executor = current_task.state.running;

        // TODO: all except self IPI
        // TODO: is there a better way to determine which executors to target?
        for (kernel.executors) |*executor| {
            if (executor == current_executor) continue; // skip ourselves
            flush_request.requestExecutor(executor);
        }

        flush_request.flush(current_task);
    }

    while (flush_request.count.load(.monotonic) != 0) {
        kernel.arch.spinLoopHint();
    }
}

pub fn processFlushRequests(current_task: *kernel.Task) void {
    std.debug.assert(current_task.interrupt_disable_count != 0);

    const executor = current_task.state.running;

    while (executor.flush_requests.popFirst()) |node| {
        const request_node: *const kernel.mem.FlushRequest.Node = @fieldParentPtr("node", node);
        request_node.request.flush(current_task);
    }
}

fn flush(flush_request: *FlushRequest, current_task: *const kernel.Task) void {
    std.debug.assert(current_task.interrupt_disable_count != 0);

    defer _ = flush_request.count.fetchSub(1, .monotonic);

    switch (flush_request.flush_target) {
        .kernel => {},
        .user => |target_process| switch (current_task.context) {
            .kernel => return,
            .user => |current_process| if (current_process != target_process) return,
        },
    }

    kernel.arch.paging.flushCache(flush_request.range);
}

fn requestExecutor(flush_request: *FlushRequest, executor: *kernel.Executor) void {
    _ = flush_request.count.fetchAdd(1, .monotonic);

    const node = flush_request.nodes.addOne() catch @panic("exceeded maximum number of executors");
    node.* = .{
        .request = flush_request,
        .node = .{},
    };
    executor.flush_requests.prepend(&node.node);

    kernel.arch.interrupts.sendFlushIPI(executor);
}

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
