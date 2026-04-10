// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: CascadeOS Contributors

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const core = @import("core");

const FlushRequest = @This();

batch: *const cascade.mem.VirtualRangeBatch,
flush_target: cascade.Context,
count: std.atomic.Value(usize) = .init(1), // starts at `1` to account for the current executor
nodes: core.containers.BoundedArray(Node, cascade.config.executor.maximum_number_of_executors) = .{},

pub const Node = struct {
    request: *FlushRequest,
    node: std.SinglyLinkedList.Node,
};

pub fn submitAndWait(flush_request: *FlushRequest) void {
    const current_task: cascade.Task.Current = .get();

    {
        current_task.incrementMigrationDisable();
        defer current_task.decrementMigrationDisable();

        const current_executor = current_task.knownExecutor();

        // TODO: all except self IPI
        // TODO: is there a better way to determine which executors to target?
        for (cascade.Executor.executors()) |*executor| {
            if (executor == current_executor) continue; // skip ourselves
            flush_request.requestExecutor(executor);
        }

        flush_request.flush();
    }

    if (current_task.task.interrupt_disable_count.load(.acquire) == 0) {
        // interrupts are enabled so flush requests from other cores will be serviced
        while (flush_request.count.load(.monotonic) != 0) {
            arch.spinLoopHint();
        }
    } else {
        // interrupts are disabled so service flush requests here
        while (flush_request.count.load(.monotonic) != 0) {
            processFlushRequests();
        }
    }
}

pub fn processFlushRequests() void {
    const current_task: cascade.Task.Current = .get();
    const executor = current_task.knownExecutor();

    while (executor.flush_requests.popFirst()) |node| {
        const request_node: *const cascade.mem.FlushRequest.Node = @fieldParentPtr("node", node);
        request_node.request.flush();
    }
}

fn flush(flush_request: *FlushRequest) void {
    const current_task: cascade.Task.Current = .get();
    defer _ = flush_request.count.fetchSub(1, .monotonic);

    switch (flush_request.flush_target) {
        .kernel => {},
        .user => |target_process| switch (current_task.task.type) {
            .kernel => return,
            .user => {
                const current_process: *cascade.user.Process = .from(current_task.task);
                if (current_process != target_process) return;
            },
        },
    }

    for (flush_request.batch.ranges.constSlice()) |range| {
        arch.paging.flushCache(range);
    }
}

fn requestExecutor(flush_request: *FlushRequest, executor: *cascade.Executor) void {
    _ = flush_request.count.fetchAdd(1, .monotonic);

    const node = flush_request.nodes.addOne() catch @panic("exceeded maximum number of executors");
    node.* = .{
        .request = flush_request,
        .node = .{},
    };
    executor.flush_requests.prepend(&node.node);

    arch.interrupts.sendFlushIPI(executor);
}
