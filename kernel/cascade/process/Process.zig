// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

//! Represents a userspace process.

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const core = @import("core");

const process_cleanup = @import("process_cleanup.zig");
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
pub fn create(current_task: *cascade.Task, options: CreateOptions) !*Process {
    const process = try globals.cache.allocate(current_task);
    errdefer globals.cache.deallocate(current_task, process);

    if (core.is_debug) std.debug.assert(process.reference_count.load(.monotonic) == 0);

    process.name = options.name;
    process.address_space.retarget(process);

    cascade.globals.processes_lock.writeLock(current_task);
    defer cascade.globals.processes_lock.writeUnlock(current_task);

    const gop = try cascade.globals.processes.getOrPut(cascade.mem.heap.allocator, process);
    if (gop.found_existing) @panic("process already in processes list");

    process.incrementReferenceCount();

    return process;
}

pub const CreateThreadOptions = struct {
    name: ?cascade.Task.Name = null,
    function: arch.scheduling.TaskFunction,
    arg1: u64 = 0,
    arg2: u64 = 0,
};

/// Creates a thread in the given process.
///
/// The thread is in the `ready` state and is not scheduled.
pub fn createThread(
    process: *Process,
    current_task: *cascade.Task,
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

pub fn decrementReferenceCount(process: *Process, current_task: *cascade.Task) void {
    if (process.reference_count.fetchSub(1, .acq_rel) != 1) return;
    process_cleanup.queueProcessForCleanup(current_task, process);
}

pub fn format(process: *const Process, writer: *std.Io.Writer) !void {
    try writer.print("Process('{s}')", .{process.name.constSlice()});
}

pub const internal = struct {
    pub fn destroy(current_task: *cascade.Task, process: *Process) void {
        if (core.is_debug) {
            std.debug.assert(process.reference_count.load(.monotonic) == 0);
            std.debug.assert(process.queued_for_cleanup.load(.monotonic));
        }
        process.queued_for_cleanup.store(false, .monotonic);

        if (core.is_debug) {
            std.debug.assert(!process.threads_lock.isReadLocked() and !process.threads_lock.isWriteLocked());
            std.debug.assert(process.threads.count() == 0);
        }
        process.threads.clearAndFree(cascade.mem.heap.allocator);

        process.address_space.reinitializeAndUnmapAll(current_task);

        globals.cache.deallocate(current_task, process);
    }
};

pub const Name = core.containers.BoundedArray(u8, cascade.config.process_name_length);

fn cacheConstructor(process: *Process, current_task: *cascade.Task) cascade.mem.cache.ConstructorError!void {
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

    const page_table: arch.paging.PageTable = arch.paging.PageTable.create(frame);
    cascade.mem.globals.core_page_table.copyTopLevelInto(page_table);

    process.address_space.init(current_task, .{
        .name = cascade.mem.AddressSpace.Name.fromSlice(
            temp_name.constSlice(),
        ) catch unreachable, // ensured in `cascade.config`
        .range = cascade.config.user_address_space_range,
        .page_table = page_table,
        .environment = .{ .user = process },
    }) catch |err| {
        log.warn(
            current_task,
            "process constructor failed during address space initialization: {t}",
            .{err},
        );
        return error.ObjectConstructionFailed;
    };
}

fn cacheDestructor(process: *Process, current_task: *cascade.Task) void {
    const page_table = process.address_space.page_table;

    process.address_space.deinit(current_task);

    var frame_list: cascade.mem.phys.FrameList = .{};
    frame_list.push(page_table.physical_frame);
    cascade.mem.phys.allocator.deallocate(current_task, frame_list);
}

const globals = struct {
    /// The source of process objects.
    ///
    /// Initialized during `init.initializeCache`.
    var cache: cascade.mem.cache.Cache(
        Process,
        cacheConstructor,
        cacheDestructor,
    ) = undefined;
};

pub const init = struct {
    pub fn initializeProcesses(current_task: *cascade.Task) !void {
        log.debug(current_task, "initializing process cache", .{});
        globals.cache.init(current_task, .{
            .name = try .fromSlice("process"),
        });

        try Thread.init.initializeThreads(current_task);

        log.debug(current_task, "initializing process cleanup service", .{});
        try process_cleanup.init.initializeProcessCleanupService(current_task);
    }
};
