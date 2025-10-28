// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

//! Represents a userspace process.

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const core = @import("core");

const log = cascade.debug.log.scoped(.process);

const Process = @This();

name: Name,

/// The number of references to this process.
///
/// Each task within the process has a reference to the process.
reference_count: std.atomic.Value(usize),

address_space: cascade.mem.AddressSpace,

tasks_lock: cascade.sync.RwLock = .{},
tasks: std.AutoArrayHashMapUnmanaged(*cascade.Task, void) = .{},

/// Tracks if this process has been queued for cleanup.
queued_for_cleanup: std.atomic.Value(bool) = .init(false),

/// Used for the process cleanup queue.
cleanup_node: std.SinglyLinkedList.Node = .{},

/// Used for generating task names.
next_task_id: std.atomic.Value(usize) = .init(0),

pub const CreateOptions = struct {
    name: Name,

    initial_task_options: CreateTaskOptions,
};

/// Create a process with an initial task.
pub fn create(context: *cascade.Task.Context, options: CreateOptions) !struct { *Process, *cascade.Task } {
    const process = blk: {
        const process = try globals.cache.allocate(context);
        errdefer comptime unreachable;

        process.name = options.name;
        process.address_space.retarget(process);

        break :blk process;
    };

    const entry_task = process.createUserTask(context, options.initial_task_options) catch |err| {
        globals.cache.deallocate(context, process);
        return err;
    };
    errdefer entry_task.decrementReferenceCount(context);
    if (core.is_debug) std.debug.assert(process.reference_count.load(.monotonic) == 1);

    {
        cascade.globals.processes_lock.writeLock(context);
        defer cascade.globals.processes_lock.writeUnlock(context);

        const gop = try cascade.globals.processes.getOrPut(cascade.mem.heap.allocator, process);
        if (gop.found_existing) @panic("process already in processes list");
    }
    errdefer comptime unreachable;

    return .{ process, entry_task };
}

pub const CreateTaskOptions = struct {
    name: ?cascade.Task.Name = null,
    function: arch.scheduling.TaskFunction,
    arg1: u64 = 0,
    arg2: u64 = 0,
};

/// Creates a task in the given process.
///
/// The task is in the `ready` state and is not scheduled.
pub fn createUserTask(
    process: *Process,
    context: *cascade.Task.Context,
    options: CreateTaskOptions,
) !*cascade.Task {
    const entry_task = try cascade.Task.internal.create(context, .{
        .name = if (options.name) |provided_name|
            provided_name
        else
            try .initPrint(
                "{d}",
                .{process.next_task_id.fetchAdd(1, .monotonic)},
            ),
        .function = options.function,
        .arg1 = options.arg1,
        .arg2 = options.arg2,
        .environment = .{ .user = process },
    });
    errdefer {
        entry_task.state = .{ .dropped = .{} }; // `destroy` will assert this
        cascade.Task.internal.destroy(context, entry_task);
    }

    process.incrementReferenceCount();
    errdefer process.decrementReferenceCount(context);

    {
        process.tasks_lock.writeLock(context);
        defer process.tasks_lock.writeUnlock(context);

        const gop = try process.tasks.getOrPut(cascade.mem.heap.allocator, entry_task);
        if (gop.found_existing) @panic("task already in tasks list");
    }
    errdefer comptime unreachable;

    return entry_task;
}

pub fn incrementReferenceCount(process: *Process) void {
    _ = process.reference_count.fetchAdd(1, .acq_rel);
}

pub fn decrementReferenceCount(process: *Process, context: *cascade.Task.Context) void {
    if (process.reference_count.fetchSub(1, .acq_rel) != 1) return;
    cascade.services.process_cleanup.queueProcessForCleanup(context, process);
}

pub fn format(process: *const Process, writer: *std.Io.Writer) !void {
    try writer.print("Process('{s}')", .{process.name.constSlice()});
}

pub const internal = struct {
    pub fn destroy(context: *cascade.Task.Context, process: *Process) void {
        if (core.is_debug) {
            std.debug.assert(process.reference_count.load(.monotonic) == 0);
            std.debug.assert(process.queued_for_cleanup.load(.monotonic));
        }
        process.queued_for_cleanup.store(false, .monotonic);

        if (core.is_debug) {
            std.debug.assert(!process.tasks_lock.isReadLocked() and !process.tasks_lock.isWriteLocked());
            std.debug.assert(process.tasks.count() == 0);
        }
        process.tasks.clearAndFree(cascade.mem.heap.allocator);

        if (true) { // TODO: actually implement cleanup of the address space
            log.err(context, "process destroy called - not fully implemented - leaking address space", .{});

            const frame = cascade.mem.phys.allocator.allocate(context) catch
                @panic("janky leaking process destory failed to allocate frame");

            const page_table: arch.paging.PageTable = arch.paging.PageTable.create(frame);
            cascade.mem.globals.core_page_table.copyTopLevelInto(page_table);

            process.address_space.init(context, .{
                .name = cascade.mem.AddressSpace.Name.fromSlice(
                    process.name.constSlice(),
                ) catch unreachable, // ensured in `cascade.config`
                .range = cascade.config.user_address_space_range,
                .page_table = page_table,
                .environment = .{ .user = process },
            }) catch @panic("janky leaking process destroy failed to init address space");
        } else {
            // TODO: not called as `reinitializeAndUnmapAll` is not implemented
            process.address_space.reinitializeAndUnmapAll(context);
        }

        globals.cache.deallocate(context, process);
    }
};

pub const Name = core.containers.BoundedArray(u8, cascade.config.process_name_length);

fn cacheConstructor(process: *Process, context: *cascade.Task.Context) cascade.mem.cache.ConstructorError!void {
    const temp_name = Process.Name.initPrint("temp {*}", .{process}) catch unreachable;

    process.* = .{
        .name = temp_name,
        .reference_count = .init(0),
        .address_space = undefined, // initialized below
    };

    const frame = cascade.mem.phys.allocator.allocate(context) catch |err| {
        log.warn(context, "process constructor failed during frame allocation: {t}", .{err});
        return error.ItemConstructionFailed;
    };
    errdefer {
        var frame_list: cascade.mem.phys.FrameList = .{};
        frame_list.push(frame);
        cascade.mem.phys.allocator.deallocate(context, frame_list);
    }

    const page_table: arch.paging.PageTable = arch.paging.PageTable.create(frame);
    cascade.mem.globals.core_page_table.copyTopLevelInto(page_table);

    process.address_space.init(context, .{
        .name = cascade.mem.AddressSpace.Name.fromSlice(
            temp_name.constSlice(),
        ) catch unreachable, // ensured in `cascade.config`
        .range = cascade.config.user_address_space_range,
        .page_table = page_table,
        .environment = .{ .user = process },
    }) catch |err| {
        log.warn(
            context,
            "process constructor failed during address space initialization: {t}",
            .{err},
        );
        return error.ObjectConstructionFailed;
    };
}

fn cacheDestructor(process: *Process, context: *cascade.Task.Context) void {
    const page_table = process.address_space.page_table;

    process.address_space.deinit(context);

    var frame_list: cascade.mem.phys.FrameList = .{};
    frame_list.push(page_table.physical_frame);
    cascade.mem.phys.allocator.deallocate(context, frame_list);
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
    pub fn initializeProcesses(context: *cascade.Task.Context) !void {
        log.debug(context, "initializing process cache", .{});
        globals.cache.init(context, .{
            .name = try .fromSlice("process"),
        });

        log.debug(context, "initializing process cleanup service", .{});
        try cascade.services.process_cleanup.init.initializeProcessCleanupService(context);
    }
};
