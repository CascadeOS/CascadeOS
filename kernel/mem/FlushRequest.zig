// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const FlushRequest = @This();

range: core.VirtualRange,
flush_target: kernel.Context,
count: std.atomic.Value(usize) = .init(1), // starts at `1` to account for the current executor
nodes: std.BoundedArray(Node, kernel.config.maximum_number_of_executors) = .{},

pub const Node = struct {
    request: *FlushRequest,
    node: containers.SingleNode,
};

pub fn submitAndWait(flush_request: *FlushRequest, current_task: *kernel.Task) void {
    current_task.incrementPreemptionDisable();

    const current_executor = current_task.state.running;

    // TODO: all except self IPI
    // TODO: is there a better way to determine which executors to target?
    for (kernel.executors) |*executor| {
        if (executor == current_executor) continue; // skip ourselves
        flush_request.requestExecutor(executor);
    }

    flush_request.flush(current_task);

    current_task.decrementPreemptionDisable();

    flush_request.waitForCompletion(current_task);
}

pub fn processFlushRequests(current_task: *kernel.Task) void {
    std.debug.assert(current_task.interrupt_disable_count != 0 or current_task.preemption_disable_count != 0);
    const executor = current_task.state.running;

    while (executor.flush_requests.pop()) |node| {
        const request_node: *const kernel.mem.FlushRequest.Node = @fieldParentPtr("node", node);
        request_node.request.flush(current_task);
    }
}

fn flush(flush_request: *FlushRequest, current_task: *const kernel.Task) void {
    _ = current_task;

    switch (flush_request.flush_target) {
        .kernel => {},
        .user => @panic("NOT IMPLEMENTED"),
    }

    kernel.arch.paging.flushCache(flush_request.range);

    _ = flush_request.count.fetchSub(1, .monotonic);
}

fn requestExecutor(flush_request: *FlushRequest, executor: *kernel.Executor) void {
    _ = flush_request.count.fetchAdd(1, .monotonic);

    const node = flush_request.nodes.addOne() catch @panic("exceeded maximum number of executors");
    node.* = .{
        .request = flush_request,
        .node = .empty,
    };
    executor.flush_requests.push(&node.node);

    kernel.arch.interrupts.sendFlushIPI(executor);
}

fn waitForCompletion(flush_request: *FlushRequest, current_task: *kernel.Task) void {
    while (true) {
        processFlushRequests(current_task);
        if (flush_request.count.load(.monotonic) == 0) break;
        kernel.arch.spinLoopHint();
    }
}

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const containers = @import("containers");
