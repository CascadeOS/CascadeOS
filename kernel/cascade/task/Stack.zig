// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const Task = cascade.Task;
const core = @import("core");

const Stack = @This();

/// The entire virtual range including the guard page.
range: core.VirtualRange,

/// The usable range excluding the guard page.
usable_range: core.VirtualRange,

/// The current stack pointer.
stack_pointer: core.VirtualAddress,

/// The top of the stack.
///
/// This is not the same as `usable_range.endBound()` as a zero return address is pushed onto the top of the stack.
top_stack_pointer: core.VirtualAddress,

/// Creates a stack from a range.
///
/// Requirements:
/// - `usable_range` must be atleast `@sizeOf(usize)` bytes.
/// - `range` and `usable_range` must be aligned to 16 bytes.
/// - `range` must fully contain `usable_range`.
pub fn fromRange(range: core.VirtualRange, usable_range: core.VirtualRange) Stack {
    if (core.is_debug) {
        std.debug.assert(usable_range.size.greaterThanOrEqual(core.Size.of(usize)));
        std.debug.assert(range.fullyContainsRange(usable_range));

        // TODO: are these two checks needed needed as we don't use SIMD? non-x64?
        std.debug.assert(range.address.isAligned(.from(16, .byte)));
        std.debug.assert(usable_range.address.isAligned(.from(16, .byte)));
    }

    var stack: Stack = .{
        .range = range,
        .usable_range = usable_range,
        .stack_pointer = usable_range.endBound(),
        .top_stack_pointer = undefined, // set by `reset`
    };

    stack.reset();

    return stack;
}

/// Pushes a value onto the stack.
pub fn push(stack: *Stack, value: usize) error{StackOverflow}!void {
    const new_stack_pointer: core.VirtualAddress = stack.stack_pointer.moveBackward(.of(usize));
    if (new_stack_pointer.lessThan(stack.usable_range.address)) return error.StackOverflow;

    const ptr: *usize = new_stack_pointer.toPtr(*usize);
    ptr.* = value;

    stack.stack_pointer = new_stack_pointer;
}

pub fn reset(stack: *Stack) void {
    stack.stack_pointer = stack.usable_range.endBound();

    // push a zero return address
    stack.push(0) catch unreachable; // TODO: is this correct for non-x64?

    stack.top_stack_pointer = stack.stack_pointer;
}

pub fn createStack(current_task: Task.Current) !Stack {
    const stack_range = globals.stack_arena.allocate(
        current_task,
        stack_size_including_guard_page.value,
        .instant_fit,
    ) catch return error.ItemConstructionFailed;
    errdefer globals.stack_arena.deallocate(current_task, stack_range);

    const range = stack_range.toVirtualRange();
    const usable_range: core.VirtualRange = .{
        .address = range.address,
        .size = cascade.config.kernel_stack_size,
    };

    {
        globals.stack_page_table_mutex.lock(current_task);
        defer globals.stack_page_table_mutex.unlock(current_task);

        cascade.mem.mapRangeAndBackWithPhysicalFrames(
            current_task,
            cascade.mem.kernelPageTable(),
            usable_range,
            .{ .type = .kernel, .protection = .read_write },
            .kernel,
            .keep,
            cascade.mem.phys.allocator,
        ) catch return error.ItemConstructionFailed;
    }

    return .fromRange(range, usable_range);
}

pub fn destroyStack(stack: Stack, current_task: Task.Current) void {
    {
        globals.stack_page_table_mutex.lock(current_task);
        defer globals.stack_page_table_mutex.unlock(current_task);

        cascade.mem.unmapRange(
            current_task,
            cascade.mem.kernelPageTable(),
            stack.usable_range,
            .kernel,
            .free,
            .keep,
            cascade.mem.phys.allocator,
        );
    }

    globals.stack_arena.deallocate(current_task, .fromVirtualRange(stack.range));
}

const stack_size_including_guard_page = cascade.config.kernel_stack_size.add(arch.paging.standard_page_size);

const globals = struct {
    var stack_arena: cascade.mem.resource_arena.Arena(.none) = undefined;
    var stack_page_table_mutex: cascade.sync.Mutex = .{};
};

pub const init = struct {
    const init_log = cascade.debug.log.scoped(.task_init);

    pub fn initializeStacks(
        current_task: Task.Current,
        kernel_regions: *const cascade.mem.KernelMemoryRegion.List,
    ) !void {
        init_log.debug(current_task, "initializing task stacks", .{});
        try globals.stack_arena.init(
            current_task,
            .{
                .name = try .fromSlice("stacks"),
                .quantum = arch.paging.standard_page_size.value,
            },
        );

        const stacks_range = kernel_regions.find(.kernel_stacks).?.range;

        globals.stack_arena.addSpan(
            current_task,
            stacks_range.address.value,
            stacks_range.size.value,
        ) catch |err| {
            std.debug.panic("failed to add stack range to `stack_arena`: {t}", .{err});
        };
    }
};
