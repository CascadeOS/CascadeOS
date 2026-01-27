// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

//! Represents a userspace process.

const std = @import("std");

const arch = @import("arch");
const kernel = @import("kernel");
const Task = kernel.Task;
const Thread = kernel.user.Thread;
const core = @import("core");

const log = kernel.debug.log.scoped(.user);

const Process = @This();

name: Name,

/// The number of references to this process.
///
/// Each thread within the process has a reference to the process.
reference_count: std.atomic.Value(usize),

address_space: kernel.mem.AddressSpace,

threads_lock: kernel.sync.RwLock = .{},
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
pub fn create(options: CreateOptions) !*Process {
    const process = try globals.cache.allocate();
    errdefer globals.cache.deallocate(process);

    if (core.is_debug) std.debug.assert(process.reference_count.load(.monotonic) == 0);

    process.name = options.name;
    process.address_space.retarget(process);

    globals.processes_lock.writeLock();
    defer globals.processes_lock.writeUnlock();

    const gop = try globals.processes.getOrPut(kernel.mem.heap.allocator, process);
    if (gop.found_existing) @panic("process already in processes list");

    process.incrementReferenceCount();

    return process;
}

pub const CreateThreadOptions = struct {
    name: ?Task.Name = null,
    entry: core.TypeErasedCall,
};

/// Creates a thread in the given process.
///
/// The thread is in the `ready` state and is not scheduled.
pub fn createThread(
    process: *Process,
    options: CreateThreadOptions,
) !*Thread {
    const thread = try Thread.internal.create(
        process,
        .{
            .name = if (options.name) |provided_name|
                provided_name
            else
                try .initPrint(
                    "{d}",
                    .{process.next_thread_id.fetchAdd(1, .monotonic)},
                ),
            .type = .user,
            .entry = options.entry,
        },
    );
    errdefer {
        thread.task.state = .{ .dropped = .{} }; // `destroy` will assert this
        thread.task.reference_count.store(0, .monotonic); // `destroy` will assert this
        Thread.internal.destroy(thread);
    }

    process.threads_lock.writeLock();
    defer process.threads_lock.writeUnlock();

    const gop = try process.threads.getOrPut(kernel.mem.heap.allocator, thread);
    if (gop.found_existing) @panic("thread already in process threads list");

    process.incrementReferenceCount();

    return thread;
}

pub fn incrementReferenceCount(process: *Process) void {
    _ = process.reference_count.fetchAdd(1, .acq_rel);
}

pub fn decrementReferenceCount(process: *Process) void {
    if (process.reference_count.fetchSub(1, .acq_rel) != 1) {
        @branchHint(.likely);
        return;
    }
    globals.process_cleanup.queueProcessForCleanup(process);
}

/// Returns the process that the given task belongs to.
///
/// Asserts that the task is a user task.
pub inline fn from(task: *Task) *Process {
    if (core.is_debug) std.debug.assert(task.type == .user);
    const thread: *Thread = .from(task);
    return thread.process;
}

/// Returns the process that the given task belongs to.
///
/// Asserts that the task is a user task.
pub inline fn fromConst(task: *const Task) *const Process {
    if (core.is_debug) std.debug.assert(task.type == .user);
    const thread: *const Thread = .fromConst(task);
    return thread.process;
}

pub fn format(process: *const Process, writer: *std.Io.Writer) !void {
    // TODO: this is a user controlled string
    try writer.print("Process<{s}>", .{process.name.constSlice()});
}

pub const Name = core.containers.BoundedArray(u8, kernel.config.user.process_name_length);

const ProcessCleanup = struct {
    task: *Task,
    parker: kernel.sync.Parker,
    incoming: core.containers.AtomicSinglyLinkedList,

    pub fn init(process_cleanup: *ProcessCleanup) !void {
        process_cleanup.* = .{
            .task = try Task.createKernelTask(.{
                .name = try .fromSlice("process cleanup"),
                .entry = .prepare(ProcessCleanup.execute, .{process_cleanup}),
            }),
            .parker = undefined, // set below
            .incoming = .{},
        };

        process_cleanup.parker = .withParkedTask(process_cleanup.task);
    }

    pub fn queueProcessForCleanup(
        process_cleanup: *ProcessCleanup,
        process: *Process,
    ) void {
        if (process.queued_for_cleanup.cmpxchgStrong(
            false,
            true,
            .acq_rel,
            .acquire,
        ) != null) {
            @panic("already queued for cleanup");
        }

        log.verbose("queueing {f} for cleanup", .{process});

        process_cleanup.incoming.prepend(&process.cleanup_node);
        process_cleanup.parker.unpark();
    }

    fn execute(process_cleanup: *ProcessCleanup) noreturn {
        while (true) {
            while (process_cleanup.incoming.popFirst()) |node| {
                cleanupProcess(@fieldParentPtr("cleanup_node", node));
            }

            process_cleanup.parker.park();
        }
    }

    fn cleanupProcess(process: *Process) void {
        if (core.is_debug) std.debug.assert(process.queued_for_cleanup.load(.monotonic));

        process.queued_for_cleanup.store(false, .release);

        {
            globals.processes_lock.writeLock();
            defer globals.processes_lock.writeUnlock();

            if (process.reference_count.load(.acquire) != 0) {
                @branchHint(.unlikely);
                // someone has acquired a reference to the process after it was queued for cleanup
                log.verbose("{f} still has references", .{process});
                return;
            }

            if (process.queued_for_cleanup.load(.acquire)) {
                @branchHint(.unlikely);
                // someone has requeued this process for cleanup
                log.verbose("{f} has been requeued for cleanup", .{process});
                return;
            }

            if (!globals.processes.swapRemove(process)) @panic("process not found in processes");
        }

        log.debug("destroying {f}", .{process});

        process.threads.clearAndFree(kernel.mem.heap.allocator);
        process.address_space.reinitializeAndUnmapAll();

        globals.cache.deallocate(process);
    }
};

const globals = struct {
    /// The source of process objects.
    ///
    /// Initialized during `init.initializeCache`.
    var cache: kernel.mem.cache.Cache(
        Process,
        struct {
            fn constructor(process: *Process) kernel.mem.cache.ConstructorError!void {
                const temp_name = Process.Name.initPrint("temp {*}", .{process}) catch unreachable;

                process.* = .{
                    .name = temp_name,
                    .reference_count = .init(0),
                    .address_space = undefined, // initialized below
                };

                const page = kernel.mem.PhysicalPage.allocator.allocate() catch |err| {
                    log.warn("process constructor failed during page allocation: {t}", .{err});
                    return error.ItemConstructionFailed;
                };
                errdefer {
                    var page_list: kernel.mem.PhysicalPage.List = .{};
                    page_list.push(page);
                    kernel.mem.PhysicalPage.allocator.deallocate(page_list);
                }

                const page_table: arch.paging.PageTable = .create(page);
                kernel.mem.kernelPageTable().copyTopLevelInto(page_table);

                process.address_space.init(.{
                    .name = kernel.mem.AddressSpace.Name.fromSlice(
                        temp_name.constSlice(),
                    ) catch unreachable, // ensured in `kernel.config`
                    .range = kernel.config.user.user_address_space_range,
                    .page_table = page_table,
                    .context = .{ .user = process },
                }) catch |err| {
                    log.warn(
                        "process constructor failed during address space initialization: {t}",
                        .{err},
                    );
                    return error.ObjectConstructionFailed;
                };
            }
        }.constructor,
        struct {
            fn destructor(process: *Process) void {
                const page_table = process.address_space.page_table;

                process.address_space.deinit();

                var page_list: kernel.mem.PhysicalPage.List = .{};
                page_list.prepend(page_table.physical_page);
                kernel.mem.PhysicalPage.allocator.deallocate(page_list);
            }
        }.destructor,
    ) = undefined;

    var processes_lock: kernel.sync.RwLock = .{};
    var processes: std.AutoArrayHashMapUnmanaged(*Process, void) = .{};

    /// Initialized during `init.initializeProcesses`.
    var process_cleanup: ProcessCleanup = undefined;
};

pub const init = struct {
    const init_log = kernel.debug.log.scoped(.user_init);

    pub fn initializeProcesses() !void {
        init_log.debug("initializing process cache", .{});
        globals.cache.init(.{
            .name = try .fromSlice("process"),
        });

        init_log.debug("initializing process cleanup service", .{});
        try globals.process_cleanup.init();
    }
};
