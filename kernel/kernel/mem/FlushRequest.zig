// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const kernel = @import("kernel");
const Task = kernel.Task;
const Process = kernel.user.Process;
const core = @import("core");

const FlushRequest = @This();

batch: *const kernel.mem.VirtualRangeBatch,
flush_target: kernel.Context,
count: std.atomic.Value(usize) = .init(1), // starts at `1` to account for the current executor
nodes: core.containers.BoundedArray(Node, kernel.config.executor.maximum_number_of_executors) = .{},

pub const Node = struct {
    request: *FlushRequest,
    node: std.SinglyLinkedList.Node,
};

pub fn submitAndWait(flush_request: *FlushRequest, current_task: Task.Current) void {
    {
        current_task.incrementInterruptDisable();
        defer current_task.decrementInterruptDisable();

        const current_executor = current_task.knownExecutor();

        // TODO: all except self IPI
        // TODO: is there a better way to determine which executors to target?
        for (kernel.Executor.executors()) |*executor| {
            if (executor == current_executor) continue; // skip ourselves
            flush_request.requestExecutor(current_task, executor);
        }

        flush_request.flush(current_task);
    }

    while (flush_request.count.load(.monotonic) != 0) {
        arch.spinLoopHint();
    }
}

pub fn processFlushRequests(current_task: Task.Current) void {
    if (core.is_debug) std.debug.assert(current_task.task.interrupt_disable_count != 0);

    const executor = current_task.knownExecutor();

    while (executor.flush_requests.popFirst()) |node| {
        const request_node: *const kernel.mem.FlushRequest.Node = @fieldParentPtr("node", node);
        request_node.request.flush(current_task);
    }
}

fn flush(flush_request: *FlushRequest, current_task: Task.Current) void {
    if (core.is_debug) std.debug.assert(current_task.task.interrupt_disable_count != 0);

    defer _ = flush_request.count.fetchSub(1, .monotonic);

    switch (flush_request.flush_target) {
        .kernel => {},
        .user => |target_process| switch (current_task.task.type) {
            .kernel => return,
            .user => {
                const current_process: *Process = .fromTask(current_task.task);
                if (current_process != target_process) return;
            },
        },
    }

    for (flush_request.batch.ranges.constSlice()) |range| {
        arch.paging.flushCache(current_task, range);
    }
}

fn requestExecutor(flush_request: *FlushRequest, current_task: Task.Current, executor: *kernel.Executor) void {
    _ = flush_request.count.fetchAdd(1, .monotonic);

    const node = flush_request.nodes.addOne() catch @panic("exceeded maximum number of executors");
    node.* = .{
        .request = flush_request,
        .node = .{},
    };
    executor.flush_requests.prepend(&node.node);

    arch.interrupts.sendFlushIPI(current_task, executor);
}
