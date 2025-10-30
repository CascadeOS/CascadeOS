// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

//! Represents a schedulable task.
//!
//! Can be either a kernel or userspace task.

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const Process = cascade.Process;
const Thread = Process.Thread;
const core = @import("core");

pub const Scheduler = @import("Scheduler.zig");

const log = cascade.debug.log.scoped(.task);

const Task = @This();

/// The name of the task.
///
/// For kernel tasks this is always explicitly provided.
///
/// For user tasks this starts as a process local incrementing number but can be changed by the user.
name: Name,

type: cascade.Context.Type,

is_scheduler_task: bool = false,

state: State,

/// The number of references to this task.
///
/// Each task has a reference to itself which is dropped when the scheduler drops the task.
reference_count: std.atomic.Value(usize) = .init(1), // tasks start with a reference to themselves

/// The stack used by this task in kernelspace.
stack: Stack,

/// Used for various linked lists including:
/// - scheduler ready queue
/// - wait queue
/// - the kernel task cleanup service
next_task_node: std.SinglyLinkedList.Node = .{},

/// Set to the executor the current task is running on if the state of the task means that the executor cannot
/// change underneath us (for example when interrupts are disabled).
///
/// Set to null otherwise.
///
/// The value is undefined when the task is not running.
known_executor: ?*cascade.Executor,

/// Tracks the depth of nested interrupt disables.
interrupt_disable_count: u32 = 1, // tasks always start with interrupts disabled

/// Tracks nested enables of access to user memory.
enable_access_to_user_memory_count: u32 = 0,

spinlocks_held: u32,
scheduler_locked: bool,

pub const State = union(enum) {
    ready,
    /// Do not access the executor directly, use `known_executor` instead.
    running: *cascade.Executor,
    blocked,
    dropped: Dropped,

    pub const Dropped = struct {
        queued_for_cleanup: std.atomic.Value(bool) = .init(false),
    };
};

pub fn current() *Task {
    // TODO: some architectures can do this without disabling interrupts

    arch.interrupts.disable();

    const executor = arch.getCurrentExecutor();
    const current_task = executor.current_task;
    if (core.is_debug) std.debug.assert(current_task.state.running == executor);

    if (current_task.interrupt_disable_count == 0) arch.interrupts.enable();

    return current_task;
}

pub fn incrementReferenceCount(task: *Task) void {
    _ = task.reference_count.fetchAdd(1, .acq_rel);
}

/// Decrements the reference count of the task.
///
/// If it reaches zero the task is submitted to the task cleanup service.
///
/// This must not be called when the task is the current task, see `Task.drop` instead.
pub fn decrementReferenceCount(task: *Task, current_task: *Task) void {
    if (core.is_debug) std.debug.assert(task != current_task);
    if (task.reference_count.fetchSub(1, .acq_rel) != 1) {
        @branchHint(.likely);
        return;
    }
    globals.task_cleanup.queueTaskForCleanup(current_task, task);
}

pub fn incrementInterruptDisable(current_task: *Task) void {
    const previous = current_task.interrupt_disable_count;

    if (previous == 0) {
        if (core.is_debug) std.debug.assert(arch.interrupts.areEnabled());
        arch.interrupts.disable();
        current_task.known_executor = current_task.state.running;
    } else if (core.is_debug) std.debug.assert(!arch.interrupts.areEnabled());

    current_task.interrupt_disable_count = previous + 1;
}

pub fn decrementInterruptDisable(current_task: *Task) void {
    if (core.is_debug) std.debug.assert(!arch.interrupts.areEnabled());

    const previous = current_task.interrupt_disable_count;
    current_task.interrupt_disable_count = previous - 1;

    if (previous == 1) {
        current_task.setKnownExecutor();
        arch.interrupts.enable();
    }
}

pub fn incrementEnableAccessToUserMemory(current_task: *Task) void {
    if (core.is_debug) std.debug.assert(current_task.type == .user);

    const previous = current_task.enable_access_to_user_memory_count;
    current_task.enable_access_to_user_memory_count = previous + 1;

    if (previous == 0) {
        arch.paging.enableAccessToUserMemory();
    }
}

pub fn decrementEnableAccessToUserMemory(current_task: *Task) void {
    if (core.is_debug) std.debug.assert(current_task.type == .user);

    const previous = current_task.enable_access_to_user_memory_count;
    current_task.enable_access_to_user_memory_count = previous - 1;

    if (previous == 1) {
        arch.paging.disableAccessToUserMemory();
    }
}

pub fn onInterruptEntry() struct { *Task, InterruptExit } {
    if (core.is_debug) std.debug.assert(!arch.interrupts.areEnabled());

    const executor = arch.getCurrentExecutor();
    const current_task = executor.current_task;
    if (core.is_debug) std.debug.assert(current_task.state.running == executor);

    const previous_interrupt_disable_count = current_task.interrupt_disable_count;
    current_task.interrupt_disable_count = previous_interrupt_disable_count + 1;
    current_task.known_executor = current_task.state.running;

    const previous_enable_access_to_user_memory_count = current_task.enable_access_to_user_memory_count;
    current_task.enable_access_to_user_memory_count = 0;
    if (previous_enable_access_to_user_memory_count != 0) {
        @branchHint(.unlikely);
        arch.paging.disableAccessToUserMemory();
    }

    return .{
        current_task, .{
            .previous_interrupt_disable_count = previous_interrupt_disable_count,
            .previous_enable_access_to_user_memory_count = previous_enable_access_to_user_memory_count,
        },
    };
}

pub const InterruptExit = struct {
    previous_interrupt_disable_count: u32,
    previous_enable_access_to_user_memory_count: u32,

    pub fn exit(interrupt_exit: InterruptExit, current_task: *Task) void {
        current_task.interrupt_disable_count = interrupt_exit.previous_interrupt_disable_count;

        current_task.enable_access_to_user_memory_count = interrupt_exit.previous_enable_access_to_user_memory_count;
        if (current_task.enable_access_to_user_memory_count == 0) {
            @branchHint(.likely);
            arch.paging.disableAccessToUserMemory();
        } else {
            arch.paging.enableAccessToUserMemory();
        }

        current_task.setKnownExecutor();
    }
};

/// Drops the current task out of the scheduler.
///
/// Decrements the reference count of the task to remove the implicit self reference.
///
/// The scheduler lock must be held when this function is called.
pub fn drop(current_task: *Task) noreturn {
    if (core.is_debug) {
        Scheduler.assertSchedulerLocked(current_task);
        std.debug.assert(current_task.spinlocks_held == 1); // only the scheduler lock is held
    }

    Scheduler.drop(current_task, .{
        .action = struct {
            fn action(scheduler_task: *Task, old_task: *Task, _: usize) void {
                old_task.state = .{ .dropped = .{} };
                old_task.decrementReferenceCount(scheduler_task);
            }
        }.action,
        .arg = undefined,
    });
    @panic("dropped task returned");
}

/// Called when panicking to fetch the current task.
///
/// Interrupts must already be disabled when this function is called.
pub fn panicked() *Task {
    std.debug.assert(!arch.interrupts.areEnabled());

    const executor = arch.getCurrentExecutor();
    const current_task = executor.current_task;

    current_task.interrupt_disable_count += 1;
    current_task.known_executor = executor;

    return current_task;
}

pub const CreateKernelTaskOptions = struct {
    name: Name,
    function: arch.scheduling.TaskFunction,
    arg1: u64 = 0,
    arg2: u64 = 0,
};

pub fn createKernelTask(current_task: *Task, options: CreateKernelTaskOptions) !*Task {
    const task = try globals.cache.allocate(current_task);
    errdefer globals.cache.deallocate(current_task, task);

    try internal.init(task, .{
        .name = options.name,
        .function = options.function,
        .arg1 = options.arg1,
        .arg2 = options.arg2,
        .type = .kernel,
    });

    globals.kernel_tasks_lock.writeLock(current_task);
    defer globals.kernel_tasks_lock.writeUnlock(current_task);

    const gop = try globals.kernel_tasks.getOrPut(cascade.mem.heap.allocator, task);
    if (gop.found_existing) std.debug.panic("task already in kernel tasks list", .{});

    return task;
}

fn destroyKernelTask(task: *Task, current_task: *Task) void {
    if (core.is_debug) {
        std.debug.assert(task.type == .kernel);
        std.debug.assert(task.state == .dropped);
        std.debug.assert(task.reference_count.load(.monotonic) == 0);
    }
    globals.cache.deallocate(current_task, task);
}

pub fn format(
    task: *Task,
    writer: *std.Io.Writer,
) !void {
    switch (task.type) {
        .kernel => try writer.print(
            "Kernel<{s}>",
            .{task.name.constSlice()},
        ),
        .user => {
            const process: *const Process = .fromTask(task);
            try writer.print(
                "User<{s} - {s}>",
                .{ process.name.constSlice(), task.name.constSlice() },
            );
        },
    }
}

pub inline fn fromNode(node: *std.SinglyLinkedList.Node) *Task {
    return @fieldParentPtr("next_task_node", node);
}

/// Set the `known_executor` field of the task based on the state of the task.
inline fn setKnownExecutor(current_task: *Task) void {
    if (current_task.interrupt_disable_count != 0) {
        current_task.known_executor = current_task.state.running;
    } else {
        current_task.known_executor = null;
    }
}

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

    pub fn createStack(current_task: *Task) !Stack {
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

    pub fn destroyStack(stack: Stack, current_task: *Task) void {
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
};

pub const internal = struct {
    pub const InitOptions = struct {
        name: Name,
        function: arch.scheduling.TaskFunction,
        arg1: u64,
        arg2: u64,
        type: cascade.Context.Type,
    };

    pub fn init(task: *Task, options: InitOptions) !void {
        const preconstructed_stack = task.stack;

        task.* = .{
            .name = options.name,
            .state = .ready,
            .stack = preconstructed_stack,
            .type = options.type,
            .known_executor = null,
            .spinlocks_held = 1, // fresh tasks start with the scheduler locked
            .scheduler_locked = true, // fresh tasks start with the scheduler locked
        };

        task.stack.reset();

        try arch.scheduling.prepareTaskForScheduling(
            task,
            options.function,
            options.arg1,
            options.arg2,
        );
    }
};

const TaskCleanup = struct {
    task: *Task,
    parker: cascade.sync.Parker,
    incoming: core.containers.AtomicSinglyLinkedList,

    pub fn init(task_cleanup: *TaskCleanup, current_task: *Task) !void {
        task_cleanup.* = .{
            .task = try Task.createKernelTask(current_task, .{
                .name = try .fromSlice("task cleanup"),
                .function = TaskCleanup.entry,
                .arg1 = @intFromPtr(task_cleanup),
            }),
            .parker = undefined, // set below
            .incoming = .{},
        };

        task_cleanup.parker = .withParkedTask(task_cleanup.task);
    }

    /// Queues a task to be cleaned up by the task cleanup service.
    pub fn queueTaskForCleanup(
        task_cleanup: *TaskCleanup,
        current_task: *Task,
        task: *Task,
    ) void {
        if (core.is_debug) {
            std.debug.assert(current_task != task);
            std.debug.assert(task.state == .dropped);
        }

        if (task.state.dropped.queued_for_cleanup.cmpxchgStrong(
            false,
            true,
            .acq_rel,
            .acquire,
        ) != null) {
            @panic("already queued for cleanup");
        }

        log.verbose(current_task, "queueing {f} for cleanup", .{task});

        task_cleanup.incoming.prepend(&task.next_task_node);
        task_cleanup.parker.unpark(current_task);
    }

    fn execute(task_cleanup: *TaskCleanup, current_task: *Task) noreturn {
        while (true) {
            while (task_cleanup.incoming.popFirst()) |node| {
                handleTask(
                    current_task,
                    .fromNode(node),
                );
            }

            task_cleanup.parker.park(current_task);
        }
    }

    fn handleTask(current_task: *Task, task: *Task) void {
        if (core.is_debug) {
            std.debug.assert(task.state == .dropped);
            std.debug.assert(task.state.dropped.queued_for_cleanup.load(.monotonic));
        }

        task.state.dropped.queued_for_cleanup.store(false, .release);

        const lock: *cascade.sync.RwLock = switch (task.type) {
            .kernel => &globals.kernel_tasks_lock,
            .user => &Process.fromTask(task).threads_lock,
        };

        {
            lock.writeLock(current_task);
            defer lock.writeUnlock(current_task);

            if (task.reference_count.load(.acquire) != 0) {
                @branchHint(.unlikely);
                // someone has acquired a reference to the task after it was queued for cleanup
                log.verbose(current_task, "{f} still has references", .{task});
                return;
            }

            if (task.state.dropped.queued_for_cleanup.swap(true, .acq_rel)) {
                @branchHint(.unlikely);
                // someone has requeued this task for cleanup
                log.verbose(current_task, "{f} has been requeued for cleanup", .{task});
                return;
            }

            // the task is no longer referenced so we can safely destroy it
            switch (task.type) {
                .kernel => if (!globals.kernel_tasks.swapRemove(task)) @panic("task not found in kernel tasks"),
                .user => {
                    const thread: *Process.Thread = .fromTask(task);
                    if (!thread.process.threads.swapRemove(thread)) @panic("thread not found in process threads");
                },
            }
        }

        // this log must happen before the process reference count is decremented
        log.debug(current_task, "destroying {f}", .{task});

        switch (task.type) {
            .kernel => task.destroyKernelTask(current_task),
            .user => {
                const thread: *Process.Thread = .fromTask(task);
                thread.process.decrementReferenceCount(current_task);
                Process.Thread.internal.destroy(current_task, thread);
            },
        }
    }

    fn entry(current_task: *Task, task_cleanup_addr: usize, _: usize) noreturn {
        const task_cleanup: *TaskCleanup = @ptrFromInt(task_cleanup_addr);

        if (core.is_debug) {
            std.debug.assert(current_task == task_cleanup.task);
            std.debug.assert(current_task.interrupt_disable_count == 0);
            std.debug.assert(current_task.spinlocks_held == 0);
            std.debug.assert(!current_task.scheduler_locked);
            std.debug.assert(arch.interrupts.areEnabled());
        }

        task_cleanup.execute(current_task);
    }
};

const globals = struct {
    /// The source of task objects.
    ///
    /// Initialized during `init.initializeTasks`.
    var cache: cascade.mem.cache.Cache(
        Task,
        struct {
            fn constructor(task: *Task, current_task: *Task) cascade.mem.cache.ConstructorError!void {
                if (core.is_debug) task.* = undefined;
                task.stack = try .createStack(current_task);
            }
        }.constructor,
        struct {
            fn destructor(task: *Task, current_task: *Task) void {
                task.stack.destroyStack(current_task);
            }
        }.destructor,
    ) = undefined;

    var stack_arena: cascade.mem.resource_arena.Arena(.none) = undefined;
    var stack_page_table_mutex: cascade.sync.Mutex = .{};

    /// All currently living kernel tasks.
    ///
    /// This does not include the per-executor scheduler or bootstrap init tasks.
    var kernel_tasks: std.AutoArrayHashMapUnmanaged(*Task, void) = .{};
    var kernel_tasks_lock: cascade.sync.RwLock = .{};

    /// Initialized during `init.initializeTasks`.
    var task_cleanup: TaskCleanup = undefined;
};

pub const init = struct {
    pub const earlyCreateStack = Stack.createStack;

    pub fn initializeTasks(
        current_task: *Task,
        kernel_regions: *const cascade.mem.KernelMemoryRegion.List,
    ) !void {
        log.debug(current_task, "initializing task stacks", .{});
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

        log.debug(current_task, "initializing task cache", .{});
        globals.cache.init(
            current_task,
            .{ .name = try .fromSlice("task") },
        );

        log.debug(current_task, "initializing task cleanup service", .{});
        try globals.task_cleanup.init(current_task);
    }

    pub fn initializeBootstrapInitTask(
        bootstrap_init_task: *Task,
        bootstrap_executor: *cascade.Executor,
    ) !void {
        bootstrap_init_task.* = .{
            .name = try .fromSlice("bootstrap init"),

            .state = .{ .running = bootstrap_executor },
            .stack = undefined, // never used

            .type = .kernel,

            .known_executor = bootstrap_executor,
            .spinlocks_held = 0, // init tasks don't start with the scheduler locked
            .scheduler_locked = false, // init tasks don't start with the scheduler locked
        };
    }

    pub fn createAndAssignInitTask(
        current_task: *Task,
        executor: *cascade.Executor,
    ) !void {
        const task = try createKernelTask(current_task, .{
            .name = try .initPrint("init {}", .{@intFromEnum(executor.id)}),
            .function = undefined,
        });
        errdefer comptime unreachable;

        task.state = .{ .running = executor };
        task.known_executor = executor;
        task.spinlocks_held = 0; // init tasks don't start with the scheduler locked
        task.scheduler_locked = false; // init tasks don't start with the scheduler locked

        task.stack.reset(); // we don't care about the `function` and arguments

        executor.current_task = task;
    }

    pub fn initializeSchedulerTask(
        current_task: *Task,
        scheduler_task: *Task,
        executor: *cascade.Executor,
    ) !void {
        scheduler_task.* = .{
            .name = try .initPrint("scheduler {}", .{@intFromEnum(executor.id)}),

            .state = .ready,
            .stack = try .createStack(current_task),
            .type = .kernel,
            .known_executor = null,
            .spinlocks_held = 1, // fresh tasks start with the scheduler locked
            .scheduler_locked = true, // fresh tasks start with the scheduler locked
            .is_scheduler_task = true,
        };
    }
};
