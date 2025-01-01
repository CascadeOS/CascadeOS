// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const Stack = @This();

/// The entire virtual range including the guard page.
range: core.VirtualRange,

/// The usable range excluding the guard page.
usable_range: core.VirtualRange,

/// The current stack pointer.
stack_pointer: core.VirtualAddress,

/// Creates a stack from a range.
///
/// Requirements:
/// - `range` must be aligned to 16 bytes.
/// - `range` must fully contain `usable_range`.
pub fn fromRange(range: core.VirtualRange, usable_range: core.VirtualRange) Stack {
    std.debug.assert(range.containsRange(usable_range));
    std.debug.assert(range.address.isAligned(.from(16, .byte)));

    return .{
        .range = range,
        .usable_range = usable_range,
        .stack_pointer = usable_range.endBound(),
    };
}

/// Pushes a value onto the stack.
pub fn push(stack: *Stack, comptime T: type, value: T) error{StackOverflow}!void {
    const new_stack_pointer: core.VirtualAddress = stack.stack_pointer.moveBackward(core.Size.of(T));
    if (new_stack_pointer.lessThan(stack.usable_range.address)) return error.StackOverflow;

    const ptr: *T = new_stack_pointer.toPtr(*T);
    ptr.* = value;

    stack.stack_pointer = new_stack_pointer;
}

pub fn createStack(current_task: *kernel.Task) !Stack {
    const stack_range = try globals.stack_arena.allocate(
        current_task,
        stack_size_including_guard_page.value,
        .instant_fit,
    );

    const stack = fromRange(
        .{ .address = .fromInt(stack_range.base), .size = stack_size_including_guard_page },
        .{ .address = .fromInt(stack_range.base), .size = kernel.config.kernel_stack_size },
    );

    try kernel.vmm.mapRange(
        kernel.vmm.globals.core_page_table,
        stack.usable_range,
        .{ .writeable = true, .global = true },
    );

    return stack;
}

pub fn destroyStack(stack: Stack, current_task: *kernel.Task) void {
    kernel.vmm.unmapRange(
        kernel.vmm.globals.core_page_table,
        stack.usable_range,
        true,
    );

    globals.stack_arena.deallocate(current_task, .{
        .base = stack.range.address.value,
        .len = stack.range.size.value,
    });
}

const stack_size_including_guard_page = kernel.config.kernel_stack_size.add(kernel.arch.paging.standard_page_size);

const globals = struct {
    var stack_arena: kernel.ResourceArena = undefined;
};

pub const init = struct {
    pub fn initializeStacks() !void {
        try globals.stack_arena.create(
            "stacks",
            kernel.arch.paging.standard_page_size.value,
            .{},
        );

        const stacks_range = kernel.vmm.getKernelRegion(.kernel_stacks) orelse
            core.panic("no kernel stacks", null);

        globals.stack_arena.addSpan(
            kernel.Task.getCurrent(),
            stacks_range.address.value,
            stacks_range.size.value,
        ) catch |err| {
            core.panicFmt(
                "failed to add stack range to `stack_arena`: {s}",
                .{@errorName(err)},
                @errorReturnTrace(),
            );
        };
    }
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
