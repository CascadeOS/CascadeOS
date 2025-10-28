// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const core = @import("core");

const FlushRequest = @This();

range: core.VirtualRange,
flush_target: cascade.Environment,
count: std.atomic.Value(usize) = .init(1), // starts at `1` to account for the current executor
nodes: core.containers.BoundedArray(Node, cascade.config.maximum_number_of_executors) = .{},

pub const Node = struct {
    request: *FlushRequest,
    node: std.SinglyLinkedList.Node,
};

pub fn submitAndWait(flush_request: *FlushRequest, context: *cascade.Task.Context) void {
    {
        context.incrementInterruptDisable();
        defer context.decrementInterruptDisable();

        const current_executor = context.executor.?;

        // TODO: all except self IPI
        // TODO: is there a better way to determine which executors to target?
        for (cascade.globals.executors) |*executor| {
            if (executor == current_executor) continue; // skip ourselves
            flush_request.requestExecutor(executor);
        }

        flush_request.flush(context);
    }

    while (flush_request.count.load(.monotonic) != 0) {
        arch.spinLoopHint();
    }
}

pub fn processFlushRequests(context: *cascade.Task.Context) void {
    if (core.is_debug) std.debug.assert(context.interrupt_disable_count != 0);

    const executor = context.executor.?;

    while (executor.flush_requests.popFirst()) |node| {
        const request_node: *const cascade.mem.FlushRequest.Node = @fieldParentPtr("node", node);
        request_node.request.flush(context);
    }
}

fn flush(flush_request: *FlushRequest, context: *cascade.Task.Context) void {
    if (core.is_debug) std.debug.assert(context.interrupt_disable_count != 0);

    defer _ = flush_request.count.fetchSub(1, .monotonic);

    switch (flush_request.flush_target) {
        .kernel => {},
        .user => |target_process| switch (context.task().environment) {
            .kernel => return,
            .user => |current_process| if (current_process != target_process) return,
        },
    }

    arch.paging.flushCache(flush_request.range);
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
