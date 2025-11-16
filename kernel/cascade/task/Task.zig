// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
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
pub const Stack = @import("Stack.zig");

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

pub fn incrementReferenceCount(task: *Task) void {
    _ = task.reference_count.fetchAdd(1, .acq_rel);
}

/// Decrements the reference count of the task.
///
/// If it reaches zero the task is submitted to the task cleanup service.
///
/// This must not be called when the task is the current task, see `Task.drop` instead.
pub fn decrementReferenceCount(task: *Task, current_task: Task.Current) void {
    if (core.is_debug) std.debug.assert(task != current_task.task);
    if (task.reference_count.fetchSub(1, .acq_rel) != 1) {
        @branchHint(.likely);
        return;
    }
    globals.task_cleanup.queueTaskForCleanup(current_task, task);
}

pub const CreateKernelTaskOptions = struct {
    name: Name,
    type_erased_call: core.TypeErasedCall,
};

/// Create a kernel task.
///
/// The task is in the `ready` state and is not scheduled.
///
/// `setTaskEntry` *must* be called before the task is scheduled.
pub fn createKernelTask(current_task: Task.Current, name: Name) !*Task {
    const task = try globals.cache.allocate(current_task);
    errdefer globals.cache.deallocate(current_task, task);

    try Task.internal.init(task, .{
        .name = name,
        .type = .kernel,
    });

    globals.kernel_tasks_lock.writeLock(current_task);
    defer globals.kernel_tasks_lock.writeUnlock(current_task);

    const gop = try globals.kernel_tasks.getOrPut(cascade.mem.heap.allocator, task);
    if (gop.found_existing) std.debug.panic("task already in kernel tasks list", .{});

    return task;
}

/// Prepares the task for being scheduled.
///
/// Ensures that when the task is scheduled it will unlock the scheduler lock then call the `type_erased_call`.
///
/// This function *must* be called before the task is scheduled and can only be called once.
pub fn setTaskEntry(
    task: *Task,
    type_erased_call: core.TypeErasedCall,
) void {
    arch.scheduling.prepareTaskForScheduling(
        task,
        type_erased_call,
    );
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

pub const Current = extern struct {
    task: *Task,

    /// Returns the executor that the current task is running on if it is known.
    ///
    /// Asserts that the `known_executor` field is non-null.
    pub fn knownExecutor(current_task: Current) *cascade.Executor {
        return current_task.task.known_executor.?;
    }

    pub fn current() Task.Current {
        // TODO: some architectures can do this without disabling interrupts

        arch.interrupts.disable();

        const executor = arch.getCurrentExecutor();
        const current_task = executor.current_task;
        if (core.is_debug) std.debug.assert(current_task.state.running == executor);

        if (current_task.interrupt_disable_count == 0) arch.interrupts.enable();

        return .{ .task = current_task };
    }

    pub fn incrementInterruptDisable(current_task: Task.Current) void {
        const previous = current_task.task.interrupt_disable_count;

        if (previous == 0) {
            if (core.is_debug) std.debug.assert(arch.interrupts.areEnabled());
            arch.interrupts.disable();
            current_task.task.known_executor = current_task.task.state.running;
        } else if (core.is_debug) std.debug.assert(!arch.interrupts.areEnabled());

        current_task.task.interrupt_disable_count = previous + 1;
    }

    pub fn decrementInterruptDisable(current_task: Task.Current) void {
        if (core.is_debug) std.debug.assert(!arch.interrupts.areEnabled());

        const previous = current_task.task.interrupt_disable_count;
        current_task.task.interrupt_disable_count = previous - 1;

        if (previous == 1) {
            current_task.setKnownExecutor();
            arch.interrupts.enable();
        }
    }

    pub fn incrementEnableAccessToUserMemory(current_task: Task.Current) void {
        if (core.is_debug) std.debug.assert(current_task.task.type == .user);

        const previous = current_task.task.enable_access_to_user_memory_count;
        current_task.task.enable_access_to_user_memory_count = previous + 1;

        if (previous == 0) {
            arch.paging.enableAccessToUserMemory();
        }
    }

    pub fn decrementEnableAccessToUserMemory(current_task: Task.Current) void {
        if (core.is_debug) std.debug.assert(current_task.task.type == .user);

        const previous = current_task.task.enable_access_to_user_memory_count;
        current_task.task.enable_access_to_user_memory_count = previous - 1;

        if (previous == 1) {
            arch.paging.disableAccessToUserMemory();
        }
    }

    /// Drops the current task out of the scheduler.
    ///
    /// Decrements the reference count of the task to remove the implicit self reference.
    ///
    /// The scheduler lock must be held when this function is called.
    pub fn drop(current_task: Task.Current) noreturn {
        if (core.is_debug) {
            Scheduler.assertSchedulerLocked(current_task);
            std.debug.assert(current_task.task.spinlocks_held == 1); // only the scheduler lock is held
        }

        Scheduler.drop(current_task, .{
            .action = struct {
                fn action(inner_current_task: Task.Current, old_task: *Task, _: usize) void {
                    old_task.state = .{ .dropped = .{} };
                    old_task.decrementReferenceCount(inner_current_task);
                }
            }.action,
            .arg = undefined,
        });
        @panic("dropped task returned");
    }

    /// Called when panicking to fetch the current task.
    ///
    /// Interrupts must already be disabled when this function is called.
    pub fn panicked() Task.Current {
        std.debug.assert(!arch.interrupts.areEnabled());

        const executor = arch.getCurrentExecutor();
        const current_task = executor.current_task;

        current_task.interrupt_disable_count += 1;
        current_task.known_executor = executor;

        return .{ .task = current_task };
    }

    pub fn onInterruptEntry() struct { Task.Current, InterruptExit } {
        if (core.is_debug) std.debug.assert(!arch.interrupts.areEnabled());

        const executor = arch.getCurrentExecutor();
        const current_task = executor.current_task;
        if (core.is_debug) std.debug.assert(current_task.state.running == executor);

        const interrupt_disable_count_before_interrupt = current_task.interrupt_disable_count;
        current_task.interrupt_disable_count = interrupt_disable_count_before_interrupt + 1;
        current_task.known_executor = current_task.state.running;

        const enable_access_to_user_memory_count_before_interrupt = current_task.enable_access_to_user_memory_count;
        current_task.enable_access_to_user_memory_count = 0;
        if (enable_access_to_user_memory_count_before_interrupt != 0) {
            @branchHint(.unlikely);
            arch.paging.disableAccessToUserMemory();
        }

        return .{
            .{ .task = current_task }, .{
                .interrupt_disable_count_before_interrupt = interrupt_disable_count_before_interrupt,
                .enable_access_to_user_memory_count_before_interrupt = enable_access_to_user_memory_count_before_interrupt,
            },
        };
    }

    /// Tracks the state of the task before an interrupt was triggered.
    ///
    /// Stored seperately from the task to allow nested interrupts.
    pub const InterruptExit = struct {
        interrupt_disable_count_before_interrupt: u32,
        enable_access_to_user_memory_count_before_interrupt: u32,

        pub fn exit(interrupt_exit: InterruptExit, current_task: Task.Current) void {
            current_task.task.interrupt_disable_count = interrupt_exit.interrupt_disable_count_before_interrupt;

            const enable_access_to_user_memory_count_before_interrupt = interrupt_exit.enable_access_to_user_memory_count_before_interrupt;
            const current_enable_access_to_user_memory_count = current_task.task.enable_access_to_user_memory_count;

            current_task.task.enable_access_to_user_memory_count = enable_access_to_user_memory_count_before_interrupt;

            if (current_enable_access_to_user_memory_count != enable_access_to_user_memory_count_before_interrupt) {
                @branchHint(.unlikely);

                if (enable_access_to_user_memory_count_before_interrupt == 0) {
                    arch.paging.disableAccessToUserMemory();
                } else {
                    arch.paging.enableAccessToUserMemory();
                }
            }

            current_task.setKnownExecutor();
        }
    };

    /// Set the `known_executor` field of the task based on the state of the task.
    inline fn setKnownExecutor(current_task: Task.Current) void {
        if (current_task.task.interrupt_disable_count != 0) {
            current_task.task.known_executor = current_task.task.state.running;
        } else {
            current_task.task.known_executor = null;
        }
    }

    pub inline fn format(current_task: Current, writer: *std.Io.Writer) !void {
        return current_task.task.format(writer);
    }
};

pub const Name = core.containers.BoundedArray(u8, cascade.config.task_name_length);

const TaskCleanup = struct {
    task: *Task,
    parker: cascade.sync.Parker,
    incoming: core.containers.AtomicSinglyLinkedList,

    pub fn init(task_cleanup: *TaskCleanup, current_task: Task.Current) !void {
        task_cleanup.* = .{
            .task = try Task.createKernelTask(current_task, try .fromSlice("task cleanup")),
            .parker = undefined, // set below
            .incoming = .{},
        };
        task_cleanup.task.setTaskEntry(.prepare(TaskCleanup.execute, .{task_cleanup}));

        task_cleanup.parker = .withParkedTask(task_cleanup.task);
    }

    /// Queues a task to be cleaned up by the task cleanup service.
    pub fn queueTaskForCleanup(
        task_cleanup: *TaskCleanup,
        current_task: Task.Current,
        task: *Task,
    ) void {
        if (core.is_debug) {
            std.debug.assert(current_task.task != task);
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

    fn execute(task_cleanup: *TaskCleanup) noreturn {
        if (core.is_debug) std.debug.assert(task_cleanup.task == Task.Current.current().task);
        const current_task: Task.Current = .{ .task = task_cleanup.task };

        while (true) {
            while (task_cleanup.incoming.popFirst()) |node| {
                cleanupTask(
                    current_task,
                    .fromNode(node),
                );
            }

            task_cleanup.parker.park(current_task);
        }
    }

    fn cleanupTask(current_task: Task.Current, task: *Task) void {
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

            if (task.state.dropped.queued_for_cleanup.load(.acquire)) {
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
            .kernel => globals.cache.deallocate(current_task, task),
            .user => {
                const thread: *Process.Thread = .fromTask(task);
                thread.process.decrementReferenceCount(current_task);
                Process.Thread.internal.destroy(current_task, thread);
            },
        }
    }
};

pub const internal = struct {
    pub const InitOptions = struct {
        name: Name,
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
    }

    // Called directly by assembly code in `arch.scheduling.prepareTaskForScheduling`, so the signature must match.
    pub fn taskEntry(
        current_task: Task.Current,
        target_function: core.TypeErasedCall.TypeErasedFn,
        arg0: usize,
        arg1: usize,
        arg2: usize,
        arg3: usize,
    ) callconv(.c) noreturn {
        Scheduler.unlockScheduler(current_task);
        target_function(arg0, arg1, arg2, arg3);
        Scheduler.lockScheduler(current_task);
        current_task.drop();
        unreachable;
    }
};

const globals = struct {
    /// The source of task objects.
    ///
    /// Initialized during `init.initializeTasks`.
    var cache: cascade.mem.cache.Cache(
        Task,
        struct {
            fn constructor(task: *Task, current_task: Task.Current) cascade.mem.cache.ConstructorError!void {
                if (core.is_debug) task.* = undefined;
                task.stack = try .createStack(current_task);
            }
        }.constructor,
        struct {
            fn destructor(task: *Task, current_task: Task.Current) void {
                task.stack.destroyStack(current_task);
            }
        }.destructor,
    ) = undefined;

    /// All currently living kernel tasks.
    ///
    /// This does not include the per-executor scheduler or bootstrap init tasks.
    var kernel_tasks: std.AutoArrayHashMapUnmanaged(*Task, void) = .{};
    var kernel_tasks_lock: cascade.sync.RwLock = .{};

    /// Initialized during `init.initializeTasks`.
    var task_cleanup: TaskCleanup = undefined;
};

pub const init = struct {
    const init_log = cascade.debug.log.scoped(.task_init);

    pub const earlyCreateStack = Stack.createStack;

    pub fn initializeTasks(
        current_task: Task.Current,
        kernel_regions: *const cascade.mem.KernelMemoryRegion.List,
    ) !void {
        try Stack.init.initializeStacks(current_task, kernel_regions);

        init_log.debug(current_task, "initializing task cache", .{});
        globals.cache.init(
            current_task,
            .{ .name = try .fromSlice("task") },
        );

        init_log.debug(current_task, "initializing task cleanup service", .{});
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
        current_task: Task.Current,
        executor: *cascade.Executor,
    ) !void {
        const task = try createKernelTask(
            current_task,
            try .initPrint("init {}", .{@intFromEnum(executor.id)}),
        );
        errdefer comptime unreachable;

        task.state = .{ .running = executor };
        task.known_executor = executor;
        task.spinlocks_held = 0; // init tasks don't start with the scheduler locked
        task.scheduler_locked = false; // init tasks don't start with the scheduler locked

        task.stack.reset(); // we don't care about the `function` and arguments

        executor.current_task = task;
    }

    pub fn initializeSchedulerTask(
        current_task: Task.Current,
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
