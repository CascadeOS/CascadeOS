// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

//! Represents a schedulable task.
//!
//! Can be either a kernel or userspace task.

const Task = @This();

/// The name of the task.
///
/// For kernel tasks this is always explicitly provided.
///
/// For user tasks this starts as a process local incrementing number but can be changed by the user.
name: Name,

environment: Environment,

state: State,

/// The number of references to this task.
///
/// Each task has a reference to itself which is dropped when the scheduler drops the task.
reference_count: std.atomic.Value(usize) = .init(1), // tasks start with a reference to themselves

/// The stack used by this task in kernel mode.
stack: Stack,

/// Used for various linked lists including:
/// - scheduler ready queue
/// - wait queue
/// - the kernel task cleanup service
next_task_node: std.SinglyLinkedList.Node = .{},

context: Context,

pub const State = union(enum) {
    ready,
    /// Do not access the executor directly, use the `context` instead.
    running: *kernel.Executor,
    blocked,
    dropped: Dropped,

    pub const Dropped = struct {
        queued_for_cleanup: std.atomic.Value(bool) = .init(false),
    };
};

pub const Environment = union(kernel.Environment.Type) {
    kernel: KernelTaskType,
    user: *kernel.Process,

    pub const KernelTaskType = union(enum) {
        init,
        scheduler,
        normal,
    };
};

pub const CreateKernelTaskOptions = struct {
    name: Name,

    start_function: arch.scheduling.NewTaskFunction,
    arg1: u64,
    arg2: u64,

    kernel_task_type: Environment.KernelTaskType,
};

pub fn createKernelTask(context: *kernel.Task.Context, options: CreateKernelTaskOptions) !*Task {
    const task = try internal.create(context, .{
        .name = options.name,
        .start_function = options.start_function,
        .arg1 = options.arg1,
        .arg2 = options.arg2,
        .environment = .{ .kernel = options.kernel_task_type },
    });
    errdefer {
        std.debug.assert(task.reference_count.fetchSub(1, .monotonic) == 0);
        internal.destroy(context, task);
    }

    {
        kernel.globals.kernel_tasks_lock.writeLock(context);
        defer kernel.globals.kernel_tasks_lock.writeUnlock(context);

        const gop = try kernel.globals.kernel_tasks.getOrPut(kernel.mem.heap.allocator, task);
        if (gop.found_existing) std.debug.panic("task already in kernel_tasks list", .{});
    }

    return task;
}

pub fn incrementReferenceCount(task: *Task) void {
    _ = task.reference_count.fetchAdd(1, .acq_rel);
}

/// Decrements the reference count of the task.
///
/// If it reaches zero the task is submitted to the task cleanup service.
///
/// This must not be called when the task is the current task, see `Context.drop` instead.
pub fn decrementReferenceCount(task: *Task, context: *Task.Context) void {
    std.debug.assert(task != context.task());
    if (task.reference_count.fetchSub(1, .acq_rel) != 1) return;
    kernel.services.task_cleanup.queueTaskForCleanup(context, task);
}

pub const Context = struct {
    executor: ?*kernel.Executor,

    /// Tracks the depth of nested interrupt disables.
    interrupt_disable_count: u32 = 1, // tasks always start with interrupts disabled

    spinlocks_held: u32,
    scheduler_locked: bool,

    pub inline fn task(context: *Context) *Task {
        return @fieldParentPtr("context", context);
    }

    pub fn current() *Context {
        // TODO: some architectures can do this without disabling interrupts

        arch.interrupts.disable();

        const executor = arch.getCurrentExecutor();
        const current_task = executor.current_task;
        if (core.is_debug) std.debug.assert(current_task.state.running == executor);

        const context: *Context = &current_task.context;

        if (context.interrupt_disable_count == 0) {
            if (core.is_debug) std.debug.assert(context.executor == null);
            arch.interrupts.enable();
        } else {
            if (core.is_debug) std.debug.assert(context.executor == executor);
            //context.executor = executor;
        }

        return context;
    }

    pub const InterruptExit = struct {
        previous_interrupt_disable_count: u32,

        pub fn exit(interrupt_exit: InterruptExit, context: *Context) void {
            const previous = interrupt_exit.previous_interrupt_disable_count;
            context.interrupt_disable_count = previous;
            if (previous == 0) {
                context.executor = null;
            }
        }
    };

    pub fn onInterruptEntry() struct { *Context, InterruptExit } {
        if (core.is_debug) std.debug.assert(!arch.interrupts.areEnabled());

        const executor = arch.getCurrentExecutor();

        const current_task = executor.current_task;
        if (core.is_debug) std.debug.assert(current_task.state.running == executor);

        const context: *Context = &current_task.context;
        context.executor = executor;

        const previous_interrupt_disable_count = context.interrupt_disable_count;
        context.interrupt_disable_count = previous_interrupt_disable_count + 1;

        return .{ context, .{ .previous_interrupt_disable_count = previous_interrupt_disable_count } };
    }

    pub fn incrementInterruptDisable(context: *Context) void {
        const previous = context.interrupt_disable_count;

        if (previous == 0) {
            if (core.is_debug) std.debug.assert(arch.interrupts.areEnabled());
            arch.interrupts.disable();
            context.executor = context.task().state.running;
        } else {
            if (core.is_debug) std.debug.assert(!arch.interrupts.areEnabled());
        }

        context.interrupt_disable_count = previous + 1;

        if (core.is_debug) {
            const executor = context.executor.?;
            std.debug.assert(executor == arch.getCurrentExecutor());
            std.debug.assert(executor.current_task == context.task());
        }
    }

    pub fn decrementInterruptDisable(context: *Context) void {
        if (core.is_debug) std.debug.assert(!arch.interrupts.areEnabled());

        const executor = context.executor.?;
        if (core.is_debug) {
            std.debug.assert(executor == arch.getCurrentExecutor());
            std.debug.assert(executor.current_task == context.task());
        }

        const previous = context.interrupt_disable_count;
        if (core.is_debug) std.debug.assert(previous > 0);

        context.interrupt_disable_count = previous - 1;

        if (previous == 1) {
            context.executor = null;
            arch.interrupts.enable();
        }
    }

    /// Drops the current task out of the scheduler.
    ///
    /// Decrements the reference count of the task to remove the implicit self reference.
    ///
    /// The scheduler lock must be held when this function is called.
    pub fn drop(context: *kernel.Task.Context) noreturn {
        if (core.is_debug) {
            std.debug.assert(context.scheduler_locked);
            std.debug.assert(kernel.scheduler.isLockedByCurrent(context));
            std.debug.assert(context.spinlocks_held == 1); // only the scheduler lock is held
        }

        if (context.task().reference_count.load(.acquire) == 1) {
            // TODO: this optimization is only really valid for single executor systems

            // the `decrementReferenceCount` call inside `drop` below will _probably_ decrement the reference count to zero
            // so make sure the task cleanup service is woken up
            //
            // this prevents the situation of dropping ourselves with an empty scheduler queue so the scheduler moves us
            // into idle but then in `drop` we wake the task cleanup service causing idle to immediately go back into the
            // scheduler as the queue is no longer empty
            kernel.services.task_cleanup.wake(context);
        }

        kernel.scheduler.drop(context, .{
            .action = struct {
                fn action(new_context: *kernel.Task.Context, old_task: *kernel.Task, _: usize) void {
                    old_task.state = .{ .dropped = .{} };
                    old_task.decrementReferenceCount(new_context);
                }
            }.action,
            .arg = undefined,
        });
        @panic("dropped task returned");
    }
};

pub fn format(
    task: *const Task,
    writer: *std.Io.Writer,
) !void {
    switch (task.environment) {
        .kernel => try writer.print(
            "Kernel('{s}')",
            .{task.name.constSlice()},
        ),
        .user => |process| try writer.print(
            "User('{s}'-'{s}')",
            .{ process.name.constSlice(), task.name.constSlice() },
        ),
    }
}

pub inline fn fromNode(node: *std.SinglyLinkedList.Node) *Task {
    return @fieldParentPtr("next_task_node", node);
}

pub const internal = struct {
    pub const CreateOptions = struct {
        name: Name,

        start_function: arch.scheduling.NewTaskFunction,
        arg1: u64,
        arg2: u64,

        environment: Environment,
    };

    pub fn create(context: *kernel.Task.Context, options: CreateOptions) !*Task {
        const task = try globals.cache.allocate(context);
        errdefer globals.cache.deallocate(context, task);

        const preconstructed_stack = task.stack;

        task.* = .{
            .name = options.name,
            .state = .ready,
            .stack = preconstructed_stack,
            .environment = options.environment,
            .context = .{
                .executor = null,
                .spinlocks_held = 1, // fresh tasks start with the scheduler locked
                .scheduler_locked = true, // fresh tasks start with the scheduler locked
            },
        };

        task.stack.reset();

        try arch.scheduling.prepareNewTaskForScheduling(
            task,
            options.start_function,
            options.arg1,
            options.arg2,
        );

        return task;
    }

    pub fn destroy(context: *kernel.Task.Context, task: *Task) void {
        // for user tasks the process reference stored in `environment` has been set to `undefined` before this function
        // is called
        std.debug.assert(task.state == .dropped);
        std.debug.assert(task.reference_count.load(.monotonic) == 0);
        globals.cache.deallocate(context, task);
    }
};

pub const Name = core.containers.BoundedArray(u8, kernel.config.task_name_length);

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

    fn createStack(context: *kernel.Task.Context) !Stack {
        const stack_range = globals.stack_arena.allocate(
            context,
            stack_size_including_guard_page.value,
            .instant_fit,
        ) catch return error.ObjectConstructionFailed;
        errdefer globals.stack_arena.deallocate(context, stack_range);

        const range: core.VirtualRange = .{
            .address = .fromInt(stack_range.base),
            .size = stack_size_including_guard_page,
        };
        const usable_range: core.VirtualRange = .{
            .address = .fromInt(stack_range.base),
            .size = kernel.config.kernel_stack_size,
        };

        {
            globals.stack_page_table_mutex.lock(context);
            defer globals.stack_page_table_mutex.unlock(context);

            kernel.mem.mapRangeAndBackWithPhysicalFrames(
                context,
                kernel.mem.globals.core_page_table,
                usable_range,
                .{ .environment_type = .kernel, .protection = .read_write },
                .kernel,
                .keep,
                kernel.mem.phys.allocator,
            ) catch return error.ObjectConstructionFailed;
        }

        return .fromRange(range, usable_range);
    }

    fn destroyStack(stack: Stack, context: *kernel.Task.Context) void {
        {
            globals.stack_page_table_mutex.lock(context);
            defer globals.stack_page_table_mutex.unlock(context);

            kernel.mem.unmapRange(
                context,
                kernel.mem.globals.core_page_table,
                stack.usable_range,
                .kernel,
                .free,
                .keep,
                kernel.mem.phys.allocator,
            );
        }

        globals.stack_arena.deallocate(context, .{
            .base = stack.range.address.value,
            .len = stack.range.size.value,
        });
    }

    const stack_size_including_guard_page = kernel.config.kernel_stack_size.add(arch.paging.standard_page_size);
};

pub const globals = struct {
    /// The source of task objects.
    ///
    /// Initialized during `init.initializeTasks`.
    var cache: kernel.mem.cache.Cache(
        Task,
        struct {
            fn constructor(task: *Task, context: *Task.Context) kernel.mem.cache.ConstructorError!void {
                task.* = undefined;
                task.stack = try .createStack(context);
            }
        }.constructor,
        struct {
            fn destructor(task: *Task, context: *Task.Context) void {
                task.stack.destroyStack(context);
            }
        }.destructor,
    ) = undefined;

    var stack_arena: kernel.mem.resource_arena.Arena(.none) = undefined;
    var stack_page_table_mutex: kernel.sync.Mutex = .{};
};

pub const init = struct {
    pub const earlyCreateStack = Stack.createStack;

    pub fn initializeTasks(context: *kernel.Task.Context, stacks_range: core.VirtualRange) !void {
        log.debug(context, "initializing task stacks", .{});
        try globals.stack_arena.init(
            context,
            .{
                .name = try .fromSlice("stacks"),
                .quantum = arch.paging.standard_page_size.value,
            },
        );

        globals.stack_arena.addSpan(
            context,
            stacks_range.address.value,
            stacks_range.size.value,
        ) catch |err| {
            std.debug.panic("failed to add stack range to `stack_arena`: {t}", .{err});
        };

        log.debug(context, "initializing task cache", .{});
        globals.cache.init(
            context,
            .{ .name = try .fromSlice("task") },
        );

        log.debug(context, "initializing task cleanup service", .{});
        try kernel.services.task_cleanup.init.initializeTaskCleanupService(context);
    }

    pub fn initializeBootstrapInitTask(
        bootstrap_init_task: *kernel.Task,
        bootstrap_executor: *kernel.Executor,
    ) !*kernel.Task.Context {
        bootstrap_init_task.* = .{
            .name = try .fromSlice("bootstrap init"),

            .state = .{ .running = bootstrap_executor },
            .stack = undefined, // never used

            .environment = .{ .kernel = .init },

            .context = .{
                .executor = bootstrap_executor,
                .spinlocks_held = 0, // init tasks don't start with the scheduler locked
                .scheduler_locked = false, // init tasks don't start with the scheduler locked
            },
        };
        return &bootstrap_init_task.context;
    }

    pub fn createAndAssignInitTask(
        context: *kernel.Task.Context,
        executor: *kernel.Executor,
    ) !void {
        const task = try createKernelTask(context, .{
            .name = try .initPrint("init {}", .{@intFromEnum(executor.id)}),
            .start_function = undefined,
            .arg1 = undefined,
            .arg2 = undefined,
            .kernel_task_type = .init,
        });
        errdefer comptime unreachable;

        task.state = .{ .running = executor };
        task.context = .{
            .executor = executor,
            .spinlocks_held = 0, // init tasks don't start with the scheduler locked
            .scheduler_locked = false, // init tasks don't start with the scheduler locked
        };

        task.stack.reset(); // we don't care about the `start_function` and arguments

        executor.current_task = task;
    }

    pub fn initializeSchedulerTask(
        context: *kernel.Task.Context,
        scheduler_task: *kernel.Task,
        executor: *kernel.Executor,
    ) !void {
        scheduler_task.* = .{
            .name = try .initPrint("scheduler {}", .{@intFromEnum(executor.id)}),

            .state = .ready,
            .stack = try .createStack(context),
            .environment = .{ .kernel = .scheduler },
            .context = .{
                .executor = null,
                .spinlocks_held = 1, // fresh tasks start with the scheduler locked
                .scheduler_locked = true, // fresh tasks start with the scheduler locked
            },
        };
    }
};

const arch = @import("arch");
const kernel = @import("kernel");

const core = @import("core");
const log = kernel.debug.log.scoped(.task);
const std = @import("std");
