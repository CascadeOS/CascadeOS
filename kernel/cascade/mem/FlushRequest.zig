// SPDX-License-Identifier: BSD-3-Clause
// SPDX-FileCopyrightText: CascadeOS Contributors

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const core = @import("core");

const FlushRequest = @This();

batch: *const cascade.mem.VirtualRangeBatch,
flush_target: cascade.Context,

pub fn submitAndWait(flush_request: FlushRequest) void {
    const all_executors = cascade.Executor.executors();

    if (all_executors.len == 1) {
        // either there is only one executor or we are early in init and only the bootstrap executor is present
        flush_request.rawFlush();
        return;
    }

    const current_task: cascade.Task.Current = .get();
    if (core.is_debug) {
        // only when the bootstrap executor is running during early init will be in this function with interrupts disabled
        // but that will trigger the above branch so will not reach here, so it is safe to assert interrupt enabled
        std.debug.assert(current_task.task.interrupt_disable_count.load(.monotonic) == 0);
        std.debug.assert(arch.Executor.current.interruptsEnabled());
    }

    var state: State = .{
        .request = flush_request,
        .count = .init(all_executors.len - 1), // exclude current executor
    };

    {
        current_task.incrementMigrationDisable();
        defer current_task.decrementMigrationDisable();

        const current_executor = current_task.knownExecutor();

        // TODO: all except self IPI
        // TODO: is there a better way to determine which executors to target?
        for (all_executors) |*executor| {
            if (executor == current_executor) continue; // skip ourselves

            const node = state.nodes.addOne() catch @panic("exceeded maximum number of executors");
            node.* = .{
                .state = &state,
                .node = .{},
            };
            executor.flush_requests.prepend(&node.node);
            executor.arch_specific.flushRequestNotify();
        }

        // use `rawFlush` instead of `flush` as the current executor is not included in the count
        flush_request.rawFlush();
    }

    // TODO: spinloops are bad, we should have a `sync.Parker` on the `flush_request`
    while (state.count.load(.acquire) != 0) {
        processFlushRequests();
    }
}

pub fn processFlushRequests() void {
    const current_task: cascade.Task.Current = .get();
    const executor = current_task.knownExecutor();

    while (executor.flush_requests.popFirst()) |node| {
        const request_node: *const cascade.mem.FlushRequest.Node = @fieldParentPtr("node", node);
        request_node.state.flush();
    }
}

const State = struct {
    request: FlushRequest,
    count: std.atomic.Value(usize),
    nodes: core.containers.BoundedArray(Node, cascade.config.executor.maximum_number_of_executors) = .{},

    /// Flush the request and decrement the reference count.
    fn flush(state: *State) void {
        state.request.rawFlush();
        _ = state.count.fetchSub(1, .release);
    }
};

/// This function performs the actual cache flush, it does not perform any synchronization see `State.flush`.
fn rawFlush(request: FlushRequest) void {
    const current_task: cascade.Task.Current = .get();

    switch (request.flush_target) {
        .kernel => {},
        .user => |target_process| switch (current_task.task.type) {
            .kernel => return,
            .user => {
                const current_process: *cascade.user.Process = .from(current_task.task);
                if (current_process != target_process) return;
            },
        },
    }

    for (request.batch.ranges.constSlice()) |range| {
        arch.Executor.current.flushCache(range);
    }
}

pub const Node = struct {
    state: *State,
    node: std.SinglyLinkedList.Node,
};
