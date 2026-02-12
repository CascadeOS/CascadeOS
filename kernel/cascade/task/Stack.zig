// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const core = @import("core");
const cascade = @import("cascade");
const Task = cascade.Task;
const addr = cascade.addr;

const Stack = @This();

/// The entire virtual range including the guard page.
range: addr.Virtual.Range.Kernel,

/// The usable range excluding the guard page.
usable_range: addr.Virtual.Range.Kernel,

/// The current stack pointer.
stack_pointer: addr.Virtual.Kernel,

/// The top of the stack.
///
/// This is not the same as `usable_range.after()` as a zero return address is pushed onto the top of the stack.
top_stack_pointer: addr.Virtual.Kernel,

/// Creates a stack from a range.
///
/// Requirements:
/// - `usable_range` must be atleast `@sizeOf(usize)` bytes.
/// - `range` and `usable_range` must be aligned to 16 bytes.
/// - `range` must fully contain `usable_range`.
pub fn fromRange(range: addr.Virtual.Range.Kernel, usable_range: addr.Virtual.Range.Kernel) Stack {
    if (core.is_debug) {
        std.debug.assert(usable_range.size.greaterThanOrEqual(core.Size.of(usize)));
        std.debug.assert(range.fullyContains(usable_range));

        // TODO: are these two checks needed needed as we don't use SIMD? non-x64?
        std.debug.assert(range.address.aligned(.@"16"));
        std.debug.assert(usable_range.address.aligned(.@"16"));
    }

    var stack: Stack = .{
        .range = range,
        .usable_range = usable_range,
        .stack_pointer = usable_range.after(),
        .top_stack_pointer = undefined, // set by `reset`
    };

    stack.reset();

    return stack;
}

/// Pushes a value onto the stack.
pub fn push(stack: *Stack, value: usize) error{StackOverflow}!void {
    const new_stack_pointer: addr.Virtual.Kernel = stack.stack_pointer.moveBackward(.of(usize));
    if (new_stack_pointer.lessThan(stack.usable_range.address)) return error.StackOverflow;

    const ptr: *usize = new_stack_pointer.ptr(*usize);
    ptr.* = value;

    stack.stack_pointer = new_stack_pointer;
}

/// Returns true if there is space for `number` of `usize` values on the stack.
pub fn spaceFor(stack: *const Stack, number: usize) bool {
    const size = core.Size.of(usize).multiplyScalar(number);
    const new_stack_pointer: addr.Virtual.Kernel = stack.stack_pointer.moveBackward(size);
    if (new_stack_pointer.lessThan(stack.usable_range.address)) return false;
    return true;
}

pub fn reset(stack: *Stack) void {
    stack.stack_pointer = stack.usable_range.after();

    // push a zero return address
    stack.push(0) catch unreachable; // TODO: is this correct for non-x64?

    stack.top_stack_pointer = stack.stack_pointer;
}

pub fn createStack() !Stack {
    const stack_range = globals.stack_arena.allocate(
        stack_size_including_guard_page.value,
        .instant_fit,
    ) catch return error.ItemConstructionFailed;
    errdefer globals.stack_arena.deallocate(stack_range);

    const range = stack_range.toVirtualRange();
    const usable_range: addr.Virtual.Range.Kernel = .{
        .address = range.address,
        .size = cascade.config.task.kernel_stack_size,
    };

    {
        globals.stack_page_table_mutex.lock();
        defer globals.stack_page_table_mutex.unlock();

        cascade.mem.mapRangeAndBackWithPhysicalPages(
            cascade.mem.kernelPageTable(),
            usable_range.toVirtualRange(),
            .{ .type = .kernel, .protection = .read_write },
            .kernel,
            .keep,
            cascade.mem.PhysicalPage.allocator,
        ) catch return error.ItemConstructionFailed;
    }

    return .fromRange(range, usable_range);
}

pub fn destroyStack(stack: Stack) void {
    {
        globals.stack_page_table_mutex.lock();
        defer globals.stack_page_table_mutex.unlock();

        var unmap_batch: cascade.mem.VirtualRangeBatch = .{};
        unmap_batch.appendMergeIfFull(stack.usable_range.toVirtualRange());

        cascade.mem.unmap(
            cascade.mem.kernelPageTable(),
            &unmap_batch,
            .kernel,
            .free,
            .keep,
            cascade.mem.PhysicalPage.allocator,
        );
    }

    globals.stack_arena.deallocate(.fromVirtualRange(stack.range));
}

const stack_size_including_guard_page = cascade.config.task.kernel_stack_size.add(arch.paging.standard_page_size);

const globals = struct {
    var stack_arena: cascade.mem.resource_arena.Arena(.none) = undefined;
    var stack_page_table_mutex: cascade.sync.Mutex = .{};
};

pub const init = struct {
    const init_log = cascade.debug.log.scoped(.task_init);

    pub fn initializeStacks() !void {
        init_log.debug("initializing task stacks", .{});
        try globals.stack_arena.init(
            .{
                .name = try .fromSlice("stacks"),
                .quantum = arch.paging.standard_page_size.value,
            },
        );

        const stacks_range = cascade.mem.kernelRegions().find(.kernel_stacks).?.range;

        globals.stack_arena.addSpan(
            stacks_range.address.value,
            stacks_range.size.value,
        ) catch |err| {
            std.debug.panic("failed to add stack range to `stack_arena`: {t}", .{err});
        };
    }
};
