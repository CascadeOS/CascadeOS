// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

//! Represents a schedulable task.
//!
//! Can be either a kernel or userspace task.

const std = @import("std");

const arch = @import("arch");
const kernel = @import("kernel");
const Process = kernel.user.Process;
const Thread = kernel.user.Thread;
const core = @import("core");

pub const Current = @import("Current.zig").Current;
pub const SchedulerHandle = @import("SchedulerHandle.zig");
pub const Stack = @import("Stack.zig");

pub const EntryFunction = core.TypeErasedCall.Templated(&.{Current});

const log = kernel.debug.log.scoped(.task);

const Task = @This();

/// The name of the task.
///
/// For kernel tasks this is always explicitly provided.
///
/// For user tasks this starts as a process local incrementing number but can be changed by the user.
name: Name,

type: kernel.Context.Type,

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
known_executor: ?*kernel.Executor,

/// Tracks the depth of nested interrupt disables.
interrupt_disable_count: u32 = 1, // tasks always start with interrupts disabled

/// Tracks nested enables of access to user memory.
enable_access_to_user_memory_count: u32 = 0,

spinlocks_held: u32,
scheduler_locked: bool,

pub const State = union(enum) {
    ready,
    /// Do not access the executor directly, use `known_executor` instead.
    running: *kernel.Executor,
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
    entry: EntryFunction,
};

/// Create a kernel task.
///
/// The task is in the `ready` state and is not scheduled.
pub fn createKernelTask(current_task: Task.Current, options: CreateKernelTaskOptions) !*Task {
    const task = try globals.cache.allocate(current_task);
    errdefer globals.cache.deallocate(current_task, task);

    try Task.internal.init(task, .{
        .name = options.name,
        .type = .kernel,
        .entry = options.entry,
    });

    globals.kernel_tasks_lock.writeLock(current_task);
    defer globals.kernel_tasks_lock.writeUnlock(current_task);

    const gop = try globals.kernel_tasks.getOrPut(kernel.mem.heap.allocator, task);
    if (gop.found_existing) std.debug.panic("task already in kernel tasks list", .{});

    return task;
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

/// Represents a scheduler transition between two tasks.
pub const Transition = struct {
    old_task: *Task,
    new_task: *Task,
    type: Type,

    pub const Type = enum {
        kernel_to_kernel,
        kernel_to_user,
        user_to_kernel,
        user_to_user,

        pub fn oldType(type_: Type) kernel.Context.Type {
            return switch (type_) {
                .kernel_to_kernel, .kernel_to_user => .kernel,
                .user_to_kernel, .user_to_user => .user,
            };
        }

        pub fn newType(type_: Type) kernel.Context.Type {
            return switch (type_) {
                .kernel_to_kernel, .user_to_kernel => .kernel,
                .kernel_to_user, .user_to_user => .user,
            };
        }
    };

    pub fn from(old_task: *Task, new_task: *Task) Transition {
        return .{
            .old_task = old_task,
            .new_task = new_task,
            .type = switch (old_task.type) {
                .kernel => switch (new_task.type) {
                    .kernel => .kernel_to_kernel,
                    .user => .kernel_to_user,
                },
                .user => switch (new_task.type) {
                    .kernel => .user_to_kernel,
                    .user => .user_to_user,
                },
            },
        };
    }
};

pub const Name = core.containers.BoundedArray(u8, kernel.config.task.task_name_length);

const TaskCleanup = struct {
    task: *Task,
    parker: kernel.sync.Parker,
    incoming: core.containers.AtomicSinglyLinkedList,

    pub fn init(task_cleanup: *TaskCleanup, current_task: Task.Current) !void {
        task_cleanup.* = .{
            .task = try Task.createKernelTask(current_task, .{
                .name = try .fromSlice("task cleanup"),
                .entry = .prepare(TaskCleanup.execute, .{task_cleanup}),
            }),
            .parker = undefined, // set below
            .incoming = .{},
        };

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

    fn execute(current_task: Task.Current, task_cleanup: *TaskCleanup) noreturn {
        if (core.is_debug) std.debug.assert(task_cleanup.task == current_task.task);

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

        const lock: *kernel.sync.RwLock = switch (task.type) {
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
                    const thread: *Thread = .fromTask(task);
                    if (!thread.process.threads.swapRemove(thread)) @panic("thread not found in process threads");
                },
            }
        }

        // this log must happen before the process reference count is decremented
        log.debug(current_task, "destroying {f}", .{task});

        switch (task.type) {
            .kernel => globals.cache.deallocate(current_task, task),
            .user => {
                const thread: *Thread = .fromTask(task);
                thread.process.decrementReferenceCount(current_task);
                Thread.internal.destroy(current_task, thread);
            },
        }
    }
};

pub const internal = struct {
    pub const InitOptions = struct {
        name: Name,
        type: kernel.Context.Type,
        entry: EntryFunction,
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

        var entry = options.entry;
        entry.setTemplatedArgs(.{.{ .task = task }});

        arch.scheduling.prepareTaskForScheduling(
            task,
            entry.type_erased_call,
        );
    }

    // Called directly by assembly code in `arch.scheduling.prepareTaskForScheduling`, so the signature must match.
    pub fn taskEntry(
        current_task: Task.Current,
        target_function: *const core.TypeErasedCall.TypeErasedFn,
        arg0: usize,
        arg1: usize,
        arg2: usize,
        arg3: usize,
        arg4: usize,
    ) callconv(.c) noreturn {
        SchedulerHandle.internal.unsafeUnlock(current_task);
        target_function(arg0, arg1, arg2, arg3, arg4);

        const scheduler_handle: Task.SchedulerHandle = .get(current_task);
        scheduler_handle.drop(current_task);
        unreachable;
    }
};

const globals = struct {
    /// The source of task objects.
    ///
    /// Initialized during `init.initializeTasks`.
    var cache: kernel.mem.cache.Cache(
        Task,
        struct {
            fn constructor(task: *Task, current_task: Task.Current) kernel.mem.cache.ConstructorError!void {
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
    var kernel_tasks_lock: kernel.sync.RwLock = .{};

    /// Initialized during `init.initializeTasks`.
    var task_cleanup: TaskCleanup = undefined;
};

pub const init = struct {
    const init_log = kernel.debug.log.scoped(.task_init);

    pub const earlyCreateStack = Stack.createStack;

    pub fn initializeTasks(current_task: Task.Current) !void {
        try Stack.init.initializeStacks(current_task);

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
        bootstrap_executor: *kernel.Executor,
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
        executor: *kernel.Executor,
    ) !void {
        const dummyInitEntry = struct {
            fn dummyInitEntry(_: Task.Current) noreturn {
                @panic("init task should not be scheduled");
            }
        }.dummyInitEntry;

        const task = try createKernelTask(
            current_task,
            .{
                .name = try .initPrint("init {}", .{@intFromEnum(executor.id)}),
                .entry = .prepare(dummyInitEntry, .{}),
            },
        );
        errdefer comptime unreachable;

        task.state = .{ .running = executor };
        task.known_executor = executor;
        task.spinlocks_held = 0; // init tasks don't start with the scheduler locked
        task.scheduler_locked = false; // init tasks don't start with the scheduler locked

        task.stack.reset(); // we don't care about the entry function or its arguments

        executor.current_task = task;
    }

    pub fn initializeSchedulerTask(
        current_task: Task.Current,
        scheduler_task: *Task,
        executor: *kernel.Executor,
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
