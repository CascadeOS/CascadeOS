// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

//! Represents a userspace process.

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const Task = cascade.Task;
const core = @import("core");

pub const Thread = @import("Thread.zig");

const log = cascade.debug.log.scoped(.process);

const Process = @This();

name: Name,

/// The number of references to this process.
///
/// Each thread within the process has a reference to the process.
reference_count: std.atomic.Value(usize),

address_space: cascade.mem.AddressSpace,

threads_lock: cascade.sync.RwLock = .{},
threads: std.AutoArrayHashMapUnmanaged(*Thread, void) = .{},

/// Tracks if this process has been queued for cleanup.
queued_for_cleanup: std.atomic.Value(bool) = .init(false),

/// Used for the process cleanup queue.
cleanup_node: std.SinglyLinkedList.Node = .{},

/// Used for generating thread names.
next_thread_id: std.atomic.Value(usize) = .init(0),

pub const CreateOptions = struct {
    name: Name,
};

/// Create a process.
pub fn create(current_task: Task.Current, options: CreateOptions) !*Process {
    const process = try globals.cache.allocate(current_task);
    errdefer globals.cache.deallocate(current_task, process);

    if (core.is_debug) std.debug.assert(process.reference_count.load(.monotonic) == 0);

    process.name = options.name;
    process.address_space.retarget(process);

    globals.processes_lock.writeLock(current_task);
    defer globals.processes_lock.writeUnlock(current_task);

    const gop = try globals.processes.getOrPut(cascade.mem.heap.allocator, process);
    if (gop.found_existing) @panic("process already in processes list");

    process.incrementReferenceCount();

    return process;
}

pub const CreateThreadOptions = struct {
    name: ?Task.Name = null,
    function: arch.scheduling.TaskFunction,
    arg1: u64 = 0,
    arg2: u64 = 0,
};

/// Creates a thread in the given process.
///
/// The thread is in the `ready` state and is not scheduled.
pub fn createThread(
    process: *Process,
    current_task: Task.Current,
    options: CreateThreadOptions,
) !*Thread {
    const thread = try Thread.internal.create(
        current_task,
        process,
        .{
            .name = if (options.name) |provided_name|
                provided_name
            else
                try .initPrint(
                    "{d}",
                    .{process.next_thread_id.fetchAdd(1, .monotonic)},
                ),
            .function = options.function,
            .arg1 = options.arg1,
            .arg2 = options.arg2,
            .type = .user,
        },
    );
    errdefer {
        thread.task.state = .{ .dropped = .{} }; // `destroy` will assert this
        thread.task.reference_count.store(0, .monotonic); // `destroy` will assert this
        Thread.internal.destroy(current_task, thread);
    }

    process.threads_lock.writeLock(current_task);
    defer process.threads_lock.writeUnlock(current_task);

    const gop = try process.threads.getOrPut(cascade.mem.heap.allocator, thread);
    if (gop.found_existing) @panic("thread already in process threads list");

    process.incrementReferenceCount();

    return thread;
}

pub fn incrementReferenceCount(process: *Process) void {
    _ = process.reference_count.fetchAdd(1, .acq_rel);
}

pub fn decrementReferenceCount(process: *Process, current_task: Task.Current) void {
    if (process.reference_count.fetchSub(1, .acq_rel) != 1) {
        @branchHint(.likely);
        return;
    }
    globals.process_cleanup.queueProcessForCleanup(current_task, process);
}

/// Returns the process that the given task belongs to.
///
/// Asserts that the task is a user task.
pub inline fn fromTask(task: *Task) *Process {
    if (core.is_debug) std.debug.assert(task.type == .user);
    const thread: *Thread = @fieldParentPtr("task", task);
    return thread.process;
}

pub fn format(process: *const Process, writer: *std.Io.Writer) !void {
    try writer.print("Process('{s}')", .{process.name.constSlice()});
}

pub const Name = core.containers.BoundedArray(u8, cascade.config.process_name_length);

const ProcessCleanup = struct {
    task: *Task,
    parker: cascade.sync.Parker,
    incoming: core.containers.AtomicSinglyLinkedList,

    pub fn init(process_cleanup: *ProcessCleanup, current_task: Task.Current) !void {
        process_cleanup.* = .{
            .task = try Task.createKernelTask(current_task, .{
                .name = try .fromSlice("process cleanup"),
                .function = ProcessCleanup.entry,
                .arg1 = @intFromPtr(process_cleanup),
            }),
            .parker = undefined, // set below
            .incoming = .{},
        };

        process_cleanup.parker = .withParkedTask(process_cleanup.task);
    }

    pub fn queueProcessForCleanup(
        process_cleanup: *ProcessCleanup,
        current_task: Task.Current,
        process: *cascade.Process,
    ) void {
        if (process.queued_for_cleanup.cmpxchgStrong(
            false,
            true,
            .acq_rel,
            .acquire,
        ) != null) {
            @panic("already queued for cleanup");
        }

        log.verbose(current_task, "queueing {f} for cleanup", .{process});

        process_cleanup.incoming.prepend(&process.cleanup_node);
        process_cleanup.parker.unpark(current_task);
    }

    fn execute(process_cleanup: *ProcessCleanup, current_task: Task.Current) noreturn {
        while (true) {
            while (process_cleanup.incoming.popFirst()) |node| {
                cleanupProcess(
                    current_task,
                    @fieldParentPtr("cleanup_node", node),
                );
            }

            process_cleanup.parker.park(current_task);
        }
    }

    fn cleanupProcess(current_task: Task.Current, process: *cascade.Process) void {
        if (core.is_debug) std.debug.assert(process.queued_for_cleanup.load(.monotonic));

        process.queued_for_cleanup.store(false, .release);

        {
            globals.processes_lock.writeLock(current_task);
            defer globals.processes_lock.writeUnlock(current_task);

            if (process.reference_count.load(.acquire) != 0) {
                @branchHint(.unlikely);
                // someone has acquired a reference to the process after it was queued for cleanup
                log.verbose(current_task, "{f} still has references", .{process});
                return;
            }

            if (process.queued_for_cleanup.load(.acquire)) {
                @branchHint(.unlikely);
                // someone has requeued this process for cleanup
                log.verbose(current_task, "{f} has been requeued for cleanup", .{process});
                return;
            }

            if (!globals.processes.swapRemove(process)) @panic("process not found in processes");
        }

        process.threads.clearAndFree(cascade.mem.heap.allocator);
        process.address_space.reinitializeAndUnmapAll(current_task);

        globals.cache.deallocate(current_task, process);
    }

    fn entry(current_task: Task.Current, process_cleanup_addr: usize, _: usize) noreturn {
        const process_cleanup: *ProcessCleanup = @ptrFromInt(process_cleanup_addr);

        if (core.is_debug) {
            std.debug.assert(current_task.task == process_cleanup.task);
            std.debug.assert(current_task.task.interrupt_disable_count == 0);
            std.debug.assert(current_task.task.spinlocks_held == 0);
            std.debug.assert(!current_task.task.scheduler_locked);
            std.debug.assert(arch.interrupts.areEnabled());
        }

        process_cleanup.execute(current_task);
    }
};

const globals = struct {
    /// The source of process objects.
    ///
    /// Initialized during `init.initializeCache`.
    var cache: cascade.mem.cache.Cache(
        Process,
        struct {
            fn constructor(process: *Process, current_task: Task.Current) cascade.mem.cache.ConstructorError!void {
                const temp_name = Process.Name.initPrint("temp {*}", .{process}) catch unreachable;

                process.* = .{
                    .name = temp_name,
                    .reference_count = .init(0),
                    .address_space = undefined, // initialized below
                };

                const frame = cascade.mem.phys.allocator.allocate(current_task) catch |err| {
                    log.warn(current_task, "process constructor failed during frame allocation: {t}", .{err});
                    return error.ItemConstructionFailed;
                };
                errdefer {
                    var frame_list: cascade.mem.phys.FrameList = .{};
                    frame_list.push(frame);
                    cascade.mem.phys.allocator.deallocate(current_task, frame_list);
                }

                const page_table: arch.paging.PageTable = .create(current_task, frame);
                cascade.mem.kernelPageTable().copyTopLevelInto(current_task, page_table);

                process.address_space.init(current_task, .{
                    .name = cascade.mem.AddressSpace.Name.fromSlice(
                        temp_name.constSlice(),
                    ) catch unreachable, // ensured in `cascade.config`
                    .range = cascade.config.user_address_space_range,
                    .page_table = page_table,
                    .context = .{ .user = process },
                }) catch |err| {
                    log.warn(
                        current_task,
                        "process constructor failed during address space initialization: {t}",
                        .{err},
                    );
                    return error.ObjectConstructionFailed;
                };
            }
        }.constructor,
        struct {
            fn destructor(process: *Process, current_task: Task.Current) void {
                const page_table = process.address_space.page_table;

                process.address_space.deinit(current_task);

                var frame_list: cascade.mem.phys.FrameList = .{};
                frame_list.push(page_table.physical_frame);
                cascade.mem.phys.allocator.deallocate(current_task, frame_list);
            }
        }.destructor,
    ) = undefined;

    var processes_lock: cascade.sync.RwLock = .{};
    var processes: std.AutoArrayHashMapUnmanaged(*Process, void) = .{};

    /// Initialized during `init.initializeProcesses`.
    var process_cleanup: ProcessCleanup = undefined;
};

pub const init = struct {
    const init_log = cascade.debug.log.scoped(.process_init);

    pub fn initializeProcesses(current_task: Task.Current) !void {
        init_log.debug(current_task, "initializing process cache", .{});
        globals.cache.init(current_task, .{
            .name = try .fromSlice("process"),
        });

        try Thread.init.initializeThreads(current_task);

        init_log.debug(current_task, "initializing process cleanup service", .{});
        try globals.process_cleanup.init(current_task);
    }
};
