// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

//! Represents a schedulable task.
//!
//! Can be either a kernel or userspace task.

const Task = @This();

state: State,

/// The number of references to this task.
///
/// Each task has a reference to itself which is dropped when the scheduler drops the task.
reference_count: std.atomic.Value(usize) = .init(1), // tasks start with a reference to themselves

/// The stack used by this task in kernel mode.
stack: Stack,

/// Tracks the depth of nested interrupt disables.
interrupt_disable_count: u32 = 1, // tasks always start with interrupts disabled

/// Tracks the depth of nested preemption disables.
preemption_disable_count: u32 = 0,

/// Whenever we skip preemption, we set this to true.
///
/// When we re-enable preemption, we check this flag.
preemption_skipped: bool = false,

spinlocks_held: u32 = 1, // fresh tasks start with the scheduler locked (except for init tasks)

/// Used for various linked lists including:
/// - scheduler ready queue
/// - wait queue
/// - the kernel task cleanup service
next_task_node: containers.SingleNode = .empty,

context: Context,

pub const Context = union(kernel.Context.Type) {
    kernel: Kernel,
    user: void,

    pub const Kernel = struct {
        /// Name of the task.
        ///
        /// Kernel tasks always have a name.
        name: Name,

        is_idle_task: bool,
    };
};

pub const State = union(enum) {
    ready,
    /// It is the accessors responsibility to ensure that the executor does not change.
    running: *kernel.Executor,
    blocked,
    dropped: Dropped,

    pub const Dropped = struct {
        queued_for_cleanup: std.atomic.Value(bool) = .init(false),
    };
};

pub fn getCurrent() *Task {
    kernel.arch.interrupts.disableInterrupts();

    const executor = kernel.arch.rawGetCurrentExecutor();
    const current_task = executor.current_task;
    std.debug.assert(current_task.state.running == executor);

    if (current_task.interrupt_disable_count == 0) {
        kernel.arch.interrupts.enableInterrupts();
    }

    return current_task;
}

pub const CreateKernelTaskOptions = struct {
    name: Name,

    start_function: kernel.arch.scheduling.NewTaskFunction,
    arg1: u64,
    arg2: u64,
};

pub fn createKernelTask(current_task: *kernel.Task, options: CreateKernelTaskOptions) !*Task {
    const task = try internal.create(current_task, .{
        .start_function = options.start_function,
        .arg1 = options.arg1,
        .arg2 = options.arg2,
        .context = .{
            .kernel = .{
                .name = options.name,
            },
        },
    });
    errdefer {
        _ = task.reference_count.fetchSub(1, .monotonic); // ensure the reference count is zero
        internal.destroy(current_task, task);
    }

    {
        kernel.kernel_tasks_lock.writeLock(current_task);
        defer kernel.kernel_tasks_lock.writeUnlock(current_task);

        const gop = try kernel.kernel_tasks.getOrPut(kernel.mem.heap.allocator, task);
        std.debug.assert(gop.found_existing == false);
    }

    return task;
}

pub fn incrementReferenceCount(task: *Task) void {
    _ = task.reference_count.fetchAdd(1, .acq_rel);
}

/// Decrements the reference count of the task.
///
/// If it reaches zero the task is submitted to the task cleanup service.
pub fn decrementReferenceCount(task: *Task, current_task: *Task) void {
    if (task.reference_count.fetchSub(1, .acq_rel) != 1) return;
    kernel.services.task_cleanup.queueTaskForCleanup(current_task, task);
}

pub fn incrementInterruptDisable(task: *Task) void {
    const previous = task.interrupt_disable_count;

    if (previous == 0) {
        std.debug.assert(kernel.arch.interrupts.areEnabled());
        kernel.arch.interrupts.disableInterrupts();
    } else {
        std.debug.assert(!kernel.arch.interrupts.areEnabled());
    }

    task.interrupt_disable_count = previous + 1;

    const executor = task.state.running;
    std.debug.assert(executor == kernel.arch.rawGetCurrentExecutor());
    std.debug.assert(executor.current_task == task);
}

pub fn decrementInterruptDisable(task: *Task) void {
    std.debug.assert(!kernel.arch.interrupts.areEnabled());

    const executor = task.state.running;
    std.debug.assert(executor == kernel.arch.rawGetCurrentExecutor());
    std.debug.assert(executor.current_task == task);

    const previous = task.interrupt_disable_count;
    std.debug.assert(previous > 0);

    task.interrupt_disable_count = previous - 1;

    if (previous == 1) {
        kernel.arch.interrupts.enableInterrupts();
    }
}

pub fn incrementPreemptionDisable(task: *Task) void {
    task.preemption_disable_count += 1;

    const executor = task.state.running;
    std.debug.assert(executor == kernel.arch.rawGetCurrentExecutor());
    std.debug.assert(executor.current_task == task);
}

pub fn decrementPreemptionDisable(task: *Task) void {
    const executor = task.state.running;
    std.debug.assert(executor == kernel.arch.rawGetCurrentExecutor());
    std.debug.assert(executor.current_task == task);

    const previous = task.preemption_disable_count;
    std.debug.assert(previous > 0);

    task.preemption_disable_count = previous - 1;

    if (previous == 1 and task.preemption_skipped) {
        kernel.scheduler.maybePreempt(task);
    }
}

pub fn isIdleTask(task: *const Task) bool {
    return switch (task.context) {
        .kernel => |kernel_context| kernel_context.is_idle_task,
        .user => false,
    };
}

pub fn format(
    task: *const Task,
    writer: *std.Io.Writer,
) !void {
    switch (task.context) {
        .kernel => |kernel_context| try writer.print(
            "KernelTask({s})",
            .{kernel_context.name.constSlice()},
        ),
        .user => @panic("TODO: implement user task printing"),
    }
}

pub inline fn fromNode(node: *containers.SingleNode) *Task {
    return @fieldParentPtr("next_task_node", node);
}

pub const internal = struct {
    pub const CreateOptions = struct {
        start_function: kernel.arch.scheduling.NewTaskFunction,
        arg1: u64,
        arg2: u64,

        context: CreateContext,

        pub const CreateContext = union(kernel.Context.Type) {
            kernel: Kernel,
            user: void,

            pub const Kernel = struct {
                name: Name,
            };
        };
    };

    fn create(current_task: *kernel.Task, options: CreateOptions) !*Task {
        const task = try globals.cache.allocate(current_task);
        errdefer globals.cache.deallocate(current_task, task);

        const preconstructed_stack = task.stack;

        task.* = .{
            .state = .ready,
            .stack = preconstructed_stack,

            .context = switch (options.context) {
                .kernel => |kernel_context| .{
                    .kernel = .{
                        .name = kernel_context.name,
                        .is_idle_task = false,
                    },
                },
                .user => .user,
            },
        };

        task.stack.reset();

        try kernel.arch.scheduling.prepareNewTaskForScheduling(
            task,
            options.start_function,
            options.arg1,
            options.arg2,
        );

        return task;
    }

    pub fn destroy(current_task: *kernel.Task, task: *Task) void {
        std.debug.assert(task.state == .dropped);
        std.debug.assert(task.reference_count.load(.monotonic) == 0);
        globals.cache.deallocate(current_task, task);
    }
};

pub const Name = std.BoundedArray(u8, kernel.config.task_name_length);

pub const Stack = struct {
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
        std.debug.assert(usable_range.size.greaterThanOrEqual(core.Size.of(usize)));
        std.debug.assert(range.fullyContainsRange(usable_range));

        // TODO: are these two checks needed needed as we don't use SIMD? non-x64?
        std.debug.assert(range.address.isAligned(.from(16, .byte)));
        std.debug.assert(usable_range.address.isAligned(.from(16, .byte)));

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

    fn createStack(current_task: *kernel.Task) !Stack {
        const stack_range = globals.stack_arena.allocate(
            current_task,
            stack_size_including_guard_page.value,
            .instant_fit,
        ) catch return error.ObjectConstructionFailed;
        errdefer globals.stack_arena.deallocate(current_task, stack_range);

        const range: core.VirtualRange = .{
            .address = .fromInt(stack_range.base),
            .size = stack_size_including_guard_page,
        };
        const usable_range: core.VirtualRange = .{
            .address = .fromInt(stack_range.base),
            .size = kernel.config.kernel_stack_size,
        };

        {
            globals.stack_page_table_mutex.lock(current_task);
            defer globals.stack_page_table_mutex.unlock(current_task);

            kernel.mem.mapRangeAndBackWithPhysicalFrames(
                current_task,
                kernel.mem.globals.core_page_table,
                usable_range,
                .{ .context = .kernel, .protection = .read_write },
                .kernel,
                .nop,
                kernel.mem.phys.allocator,
            ) catch return error.ObjectConstructionFailed;
        }

        return .fromRange(range, usable_range);
    }

    fn destroyStack(stack: Stack, current_task: *kernel.Task) void {
        {
            globals.stack_page_table_mutex.lock(current_task);
            defer globals.stack_page_table_mutex.unlock(current_task);

            kernel.mem.unmapRange(
                current_task,
                kernel.mem.globals.core_page_table,
                stack.usable_range,
                .kernel,
                .free,
                .nop,
                kernel.mem.phys.allocator,
            );
        }

        globals.stack_arena.deallocate(current_task, .{
            .base = stack.range.address.value,
            .len = stack.range.size.value,
        });
    }

    const stack_size_including_guard_page = kernel.config.kernel_stack_size.add(kernel.arch.paging.standard_page_size);
};

pub const InterruptRestorer = struct {
    previous_value: u32,

    pub fn exit(interrupt_restorer: InterruptRestorer, current_task: *Task) void {
        current_task.interrupt_disable_count = interrupt_restorer.previous_value;
    }
};

pub fn onInterruptEntry() struct { *Task, InterruptRestorer } {
    std.debug.assert(!kernel.arch.interrupts.areEnabled());

    const executor = kernel.arch.rawGetCurrentExecutor();

    const current_task = executor.current_task;
    std.debug.assert(current_task.state.running == executor);

    const previous_value = current_task.interrupt_disable_count;
    current_task.interrupt_disable_count = previous_value + 1;

    return .{ current_task, .{ .previous_value = previous_value } };
}

pub const globals = struct {
    /// The source of task objects.
    ///
    /// Initialized during `init.initializeTasks`.
    var cache: kernel.mem.cache.Cache(
        Task,
        struct {
            fn constructor(task: *Task, current_task: *Task) kernel.mem.cache.ConstructorError!void {
                task.* = undefined;
                task.stack = try .createStack(current_task);
            }
        }.constructor,
        struct {
            fn destructor(task: *Task, current_task: *Task) void {
                task.stack.destroyStack(current_task);
            }
        }.destructor,
    ) = undefined;

    var stack_arena: kernel.mem.resource_arena.Arena(.none) = undefined;
    var stack_page_table_mutex: kernel.sync.Mutex = .{};
};

pub const init = struct {
    pub const earlyCreateStack = Stack.createStack;

    pub fn initializeTasks(current_task: *kernel.Task, stacks_range: core.VirtualRange) !void {
        log.debug("initializing task stacks", .{});
        try globals.stack_arena.init(
            .{
                .name = try .fromSlice("stacks"),
                .quantum = kernel.arch.paging.standard_page_size.value,
            },
        );

        globals.stack_arena.addSpan(
            current_task,
            stacks_range.address.value,
            stacks_range.size.value,
        ) catch |err| {
            std.debug.panic("failed to add stack range to `stack_arena`: {t}", .{err});
        };

        log.debug("initializing task cache", .{});
        globals.cache.init(
            .{ .name = try .fromSlice("task") },
        );

        log.debug("initializing task cleanup service", .{});
        try kernel.services.task_cleanup.init.initializeTaskCleanupService(current_task);
    }

    pub fn initializeBootstrapInitTask(
        bootstrap_init_task: *kernel.Task,
        bootstrap_executor: *kernel.Executor,
    ) !void {
        bootstrap_init_task.* = .{
            .state = .{ .running = bootstrap_executor },
            .stack = undefined, // never used
            .spinlocks_held = 0, // init tasks don't start with the scheduler locked

            .context = .{
                .kernel = .{
                    .name = try .fromSlice("bootstrap init"),
                    .is_idle_task = false,
                },
            },
        };
    }

    pub fn createAndAssignInitTask(
        current_task: *kernel.Task,
        executor: *kernel.Executor,
    ) !void {
        var name: Name = .{};
        try name.writer().print("init {}", .{@intFromEnum(executor.id)});

        const task = try createKernelTask(current_task, .{
            .name = name,
            .start_function = undefined,
            .arg1 = undefined,
            .arg2 = undefined,
        });
        errdefer comptime unreachable;

        task.state = .{ .running = executor };
        task.spinlocks_held = 0; // init tasks don't start with the scheduler locked

        task.stack.reset(); // we don't care about the `start_function` and arguments

        executor.current_task = task;
    }

    pub fn initializeIdleTask(
        current_task: *kernel.Task,
        idle_task: *kernel.Task,
        executor: *kernel.Executor,
    ) !void {
        var name: Name = .{};
        try name.writer().print("idle {}", .{@intFromEnum(executor.id)});

        idle_task.* = .{
            .state = .ready,
            .stack = try .createStack(current_task),

            .context = .{
                .kernel = .{
                    .name = name,
                    .is_idle_task = true,
                },
            },
        };
    }
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const containers = @import("containers");
const log = kernel.debug.log.scoped(.task);
