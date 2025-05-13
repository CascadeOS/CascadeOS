// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const Task = @This();

id: Id,

_name: Name,

state: State,

/// The stack used by this task in kernel mode.
stack: Stack,

/// Tracks the depth of nested interrupt disables.
interrupt_disable_count: std.atomic.Value(u32) = .init(1), // fresh tasks start with interrupts disabled

/// Tracks the depth of nested preemption disables.
preemption_disable_count: std.atomic.Value(u32) = .init(0),

/// Whenever we skip preemption, we set this to true.
///
/// When we re-enable preemption, we check this flag.
preemption_skipped: std.atomic.Value(bool) = .init(false),

spinlocks_held: u32 = 1, // fresh tasks start with the scheduler locked

/// Used for various linked lists.
next_task_node: containers.SingleNode = .empty,

is_idle_task: bool = false,

pub fn name(self: *const Task) []const u8 {
    return self._name.constSlice();
}

pub const State = union(enum) {
    ready,
    /// It is the accessors responsibility to ensure that the executor does not change.
    running: *kernel.Executor,
    blocked,
    dropped,
};

pub fn getCurrent() *Task {
    kernel.arch.interrupts.disableInterrupts();

    const executor = kernel.arch.rawGetCurrentExecutor();
    const current_task = executor.current_task;
    std.debug.assert(current_task.state.running == executor);

    if (current_task.interrupt_disable_count.load(.monotonic) == 0) {
        kernel.arch.interrupts.enableInterrupts();
    }

    return current_task;
}

pub fn incrementInterruptDisable(self: *Task) void {
    kernel.arch.interrupts.disableInterrupts();

    _ = self.interrupt_disable_count.fetchAdd(1, .monotonic);

    const executor = self.state.running;
    std.debug.assert(executor == kernel.arch.rawGetCurrentExecutor());
    std.debug.assert(executor.current_task == self);
}

pub fn decrementInterruptDisable(self: *Task) void {
    std.debug.assert(!kernel.arch.interrupts.areEnabled());

    const executor = self.state.running;
    std.debug.assert(executor == kernel.arch.rawGetCurrentExecutor());
    std.debug.assert(executor.current_task == self);

    const previous = self.interrupt_disable_count.fetchSub(1, .monotonic);
    std.debug.assert(previous > 0);

    if (previous == 1) {
        kernel.arch.interrupts.enableInterrupts();
    }
}

pub fn incrementPreemptionDisable(self: *Task) void {
    _ = self.preemption_disable_count.fetchAdd(1, .monotonic);

    const executor = self.state.running;
    std.debug.assert(executor == kernel.arch.rawGetCurrentExecutor());
    std.debug.assert(executor.current_task == self);
}

pub fn decrementPreemptionDisable(self: *Task) void {
    const executor = self.state.running;
    std.debug.assert(executor == kernel.arch.rawGetCurrentExecutor());
    std.debug.assert(executor.current_task == self);

    const previous = self.preemption_disable_count.fetchSub(1, .monotonic);
    std.debug.assert(previous > 0);

    if (previous == 1 and self.preemption_skipped.load(.monotonic)) {
        kernel.scheduler.maybePreempt(self);
    }
}

pub const InterruptRestorer = struct {
    previous_value: u32,

    pub fn exit(self: InterruptRestorer, current_task: *Task) void {
        current_task.interrupt_disable_count.store(self.previous_value, .monotonic);
    }
};

pub fn onInterruptEntry() struct { *Task, InterruptRestorer } {
    std.debug.assert(!kernel.arch.interrupts.areEnabled());

    const executor = kernel.arch.rawGetCurrentExecutor();

    const current_task = executor.current_task;
    std.debug.assert(current_task.state.running == executor);

    const previous_value = current_task.interrupt_disable_count.fetchAdd(1, .monotonic);

    return .{ current_task, .{ .previous_value = previous_value } };
}

pub const CreateOptions = struct {
    name: Name,

    start_function: kernel.arch.scheduling.NewTaskFunction,
    arg: u64,
};

/// Create a task.
pub fn create(current_task: *kernel.Task, options: CreateOptions) !*Task {
    const task = try globals.cache.allocate(current_task);

    task.id = getId();
    task._name = options.name;
    task.state = .ready;
    task.interrupt_disable_count.store(1, .monotonic); // fresh tasks start with interrupts disabled
    task.preemption_disable_count.store(0, .monotonic);
    task.preemption_skipped.store(false, .monotonic);
    task.spinlocks_held = 1; // fresh tasks start with the scheduler locked
    task.next_task_node = .empty;

    task.stack.reset();

    try kernel.arch.scheduling.prepareNewTaskForScheduling(task, options.arg, options.start_function);

    return task;
}

/// Destroy a task.
///
/// Asserts that the task is in the `dropped` state.
pub fn destroy(current_task: *kernel.Task, task: *Task) void {
    std.debug.assert(task.state == .dropped);
    globals.cache.free(current_task, task);
}

pub const Id = enum(u64) {
    none = std.math.maxInt(u64),

    _,
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
    pub fn push(stack: *Stack, value: anytype) error{StackOverflow}!void {
        const T = @TypeOf(value);

        comptime std.debug.assert(@sizeOf(T) == @sizeOf(usize)); // other code assumes register sized types

        const new_stack_pointer: core.VirtualAddress = stack.stack_pointer.moveBackward(core.Size.of(T));
        if (new_stack_pointer.lessThan(stack.usable_range.address)) return error.StackOverflow;

        const ptr: *T = new_stack_pointer.toPtr(*T);
        ptr.* = value;

        stack.stack_pointer = new_stack_pointer;
    }

    pub fn reset(stack: *Stack) void {
        stack.stack_pointer = stack.usable_range.endBound();

        // push a zero return address
        stack.push(@as(usize, 0)) catch unreachable; // TODO: is this correct for non-x64?

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

            kernel.mem.mapRangeAndAllocatePhysicalFrames(
                current_task,
                kernel.mem.globals.core_page_table,
                usable_range,
                .{ .writeable = true, .global = true },
                .kernel,
                true,
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
                true,
                .kernel,
                true,
                kernel.mem.phys.allocator,
            );
        }

        globals.stack_arena.deallocate(current_task, .{
            .base = stack.range.address.value,
            .len = stack.range.size.value,
        });
    }
};

const stack_size_including_guard_page = kernel.config.kernel_stack_size.add(kernel.arch.paging.standard_page_size);

fn getId() Id {
    const id: Id = @enumFromInt(globals.id_counter.fetchAdd(1, .acq_rel));
    if (id == .none) @panic("task id counter overflowed"); // TODO: handle this better
    return id;
}

pub fn print(task: *const Task, writer: std.io.AnyWriter, _: usize) !void {
    try writer.print("Task({s})", .{task.name()});
}

pub inline fn format(
    task: *const Task,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = options;
    _ = fmt;
    return if (@TypeOf(writer) == std.io.AnyWriter)
        print(task, writer, 0)
    else
        print(task, writer.any(), 0);
}

pub inline fn fromNode(node: *containers.SingleNode) *Task {
    return @fieldParentPtr("next_task_node", node);
}

fn cacheConstructor(self: *Task, current_task: *Task) kernel.mem.cache.ConstructorError!void {
    self.* = .{
        .id = undefined,
        ._name = .{},
        .state = .dropped,
        .stack = try .createStack(current_task),
    };
}

fn cacheDestructor(self: *Task, current_task: *Task) void {
    self.stack.destroyStack(current_task);
}

pub const globals = struct {
    /// The source of task IDs.
    ///
    /// TODO: The system will panic if this counter overflows.
    var id_counter: std.atomic.Value(usize) = .init(0);

    /// The source of task objects.
    ///
    /// Initialized during `init.initializeMemorySystem`.
    var cache: kernel.mem.cache.Cache(Task, cacheConstructor, cacheDestructor) = undefined;

    var stack_arena: kernel.mem.ResourceArena = undefined;
    var stack_page_table_mutex: kernel.sync.Mutex = .{};
};

pub const init = struct {
    pub const earlyCreateStack = Stack.createStack;

    pub fn initializeTaskStacksAndCache(current_task: *kernel.Task, stacks_range: core.VirtualRange) !void {
        try globals.stack_arena.create(
            "stacks",
            kernel.arch.paging.standard_page_size.value,
            .{ .quantum_caching = .no },
        );

        globals.stack_arena.addSpan(
            current_task,
            stacks_range.address.value,
            stacks_range.size.value,
        ) catch |err| {
            std.debug.panic(
                "failed to add stack range to `stack_arena`: {s}",
                .{@errorName(err)},
            );
        };

        globals.cache.init(
            .{ .cache_name = try .fromSlice("task") },
        );
    }

    pub fn createBootstrapInitTask(
        bootstrap_executor: *kernel.Executor,
    ) !kernel.Task {
        var bootstrap_init_task: Task = .{
            .id = getId(),
            ._name = try .fromSlice("bootstrap init"),
            .state = undefined, // set after declaration of `bootstrap_executor`
            .stack = undefined, // never used
            .spinlocks_held = 0, // init tasks don't start with the scheduler locked
        };

        bootstrap_init_task.state = .{ .running = bootstrap_executor };

        return bootstrap_init_task;
    }

    pub fn initializeInitTask(
        current_task: *kernel.Task,
        init_task: *kernel.Task,
        executor: *kernel.Executor,
    ) !void {
        init_task.* = .{
            .id = getId(),
            ._name = .{}, // set below
            .state = .{ .running = executor },
            .stack = try .createStack(current_task),
            .spinlocks_held = 0, // init tasks don't start with the scheduler locked
        };

        try init_task._name.writer().print("init {}", .{@intFromEnum(executor.id)});
    }

    pub fn initializeIdleTask(
        current_task: *kernel.Task,
        idle_task: *kernel.Task,
        executor: *kernel.Executor,
    ) !void {
        idle_task.* = .{
            .id = getId(),
            ._name = .{}, // set below
            .state = .ready,
            .stack = try .createStack(current_task),
            .is_idle_task = true,
        };

        try idle_task._name.writer().print("idle {}", .{@intFromEnum(executor.id)});
    }
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const containers = @import("containers");
