// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

//! Represents a schedulable task.
//!
//! Can be either a kernel or userspace task.

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const core = @import("core");

const log = cascade.debug.log.scoped(.task);

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

context: cascade.Context,

pub const State = union(enum) {
    ready,
    /// Do not access the executor directly, use the `context` instead.
    running: *cascade.Executor,
    blocked,
    dropped: Dropped,

    pub const Dropped = struct {
        queued_for_cleanup: std.atomic.Value(bool) = .init(false),
    };
};

pub const Environment = union(cascade.Environment.Type) {
    kernel: KernelTaskType,
    user: *cascade.Process,

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

pub fn createKernelTask(context: *cascade.Context, options: CreateKernelTaskOptions) !*Task {
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
        cascade.globals.kernel_tasks_lock.writeLock(context);
        defer cascade.globals.kernel_tasks_lock.writeUnlock(context);

        const gop = try cascade.globals.kernel_tasks.getOrPut(cascade.mem.heap.allocator, task);
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
pub fn decrementReferenceCount(task: *Task, context: *cascade.Context) void {
    std.debug.assert(task != context.task());
    if (task.reference_count.fetchSub(1, .acq_rel) != 1) return;
    cascade.services.task_cleanup.queueTaskForCleanup(context, task);
}

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

    pub fn create(context: *cascade.Context, options: CreateOptions) !*Task {
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

    pub fn destroy(context: *cascade.Context, task: *Task) void {
        // for user tasks the process reference stored in `environment` has been set to `undefined` before this function
        // is called
        std.debug.assert(task.state == .dropped);
        std.debug.assert(task.reference_count.load(.monotonic) == 0);
        globals.cache.deallocate(context, task);
    }
};

pub const Name = core.containers.BoundedArray(u8, cascade.config.task_name_length);

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

    fn createStack(context: *cascade.Context) !Stack {
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
            .size = cascade.config.kernel_stack_size,
        };

        {
            globals.stack_page_table_mutex.lock(context);
            defer globals.stack_page_table_mutex.unlock(context);

            cascade.mem.mapRangeAndBackWithPhysicalFrames(
                context,
                cascade.mem.globals.core_page_table,
                usable_range,
                .{ .environment_type = .kernel, .protection = .read_write },
                .kernel,
                .keep,
                cascade.mem.phys.allocator,
            ) catch return error.ObjectConstructionFailed;
        }

        return .fromRange(range, usable_range);
    }

    fn destroyStack(stack: Stack, context: *cascade.Context) void {
        {
            globals.stack_page_table_mutex.lock(context);
            defer globals.stack_page_table_mutex.unlock(context);

            cascade.mem.unmapRange(
                context,
                cascade.mem.globals.core_page_table,
                stack.usable_range,
                .kernel,
                .free,
                .keep,
                cascade.mem.phys.allocator,
            );
        }

        globals.stack_arena.deallocate(context, .{
            .base = stack.range.address.value,
            .len = stack.range.size.value,
        });
    }

    const stack_size_including_guard_page = cascade.config.kernel_stack_size.add(arch.paging.standard_page_size);
};

pub const globals = struct {
    /// The source of task objects.
    ///
    /// Initialized during `init.initializeTasks`.
    var cache: cascade.mem.cache.Cache(
        Task,
        struct {
            fn constructor(task: *Task, context: *cascade.Context) cascade.mem.cache.ConstructorError!void {
                task.* = undefined;
                task.stack = try .createStack(context);
            }
        }.constructor,
        struct {
            fn destructor(task: *Task, context: *cascade.Context) void {
                task.stack.destroyStack(context);
            }
        }.destructor,
    ) = undefined;

    var stack_arena: cascade.mem.resource_arena.Arena(.none) = undefined;
    var stack_page_table_mutex: cascade.sync.Mutex = .{};
};

pub const init = struct {
    pub const earlyCreateStack = Stack.createStack;

    pub fn initializeTasks(
        context: *cascade.Context,
        kernel_regions: *const cascade.mem.KernelMemoryRegion.List,
    ) !void {
        log.debug(context, "initializing task stacks", .{});
        try globals.stack_arena.init(
            context,
            .{
                .name = try .fromSlice("stacks"),
                .quantum = arch.paging.standard_page_size.value,
            },
        );

        const stacks_range = kernel_regions.find(.kernel_stacks).?.range;

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
        try cascade.services.task_cleanup.init.initializeTaskCleanupService(context);
    }

    pub fn initializeBootstrapInitTask(
        bootstrap_init_task: *cascade.Task,
        bootstrap_executor: *cascade.Executor,
    ) !*cascade.Context {
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
        context: *cascade.Context,
        executor: *cascade.Executor,
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
        context: *cascade.Context,
        scheduler_task: *cascade.Task,
        executor: *cascade.Executor,
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
