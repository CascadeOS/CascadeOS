// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

//! Represents a userspace process.

const Process = @This();

name: Name,

/// The number of references to this process.
///
/// Each task within the process has a reference to the process.
reference_count: std.atomic.Value(usize),

address_space: kernel.mem.AddressSpace,

tasks_lock: kernel.sync.RwLock = .{},
tasks: std.AutoArrayHashMapUnmanaged(*kernel.Task, void) = .{},

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
pub fn create(current_task: *kernel.Task, scheduler_locked: core.LockState, options: CreateOptions) !struct { *Process, *kernel.Task } {
    const process = blk: {
        const process = try globals.cache.allocate(current_task);
        errdefer globals.cache.deallocate(current_task, process);

        process.name = options.name;
        process.address_space.rename(
            kernel.mem.AddressSpace.Name.fromSlice(
                options.name.constSlice(),
            ) catch unreachable, // ensured in `kernel.config`
        );

        break :blk process;
    };

    const entry_task = try process.createUserTask(
        current_task,
        scheduler_locked,
        options.initial_task_options,
    );
    errdefer entry_task.decrementReferenceCount(current_task, scheduler_locked);
    std.debug.assert(process.reference_count.load(.monotonic) == 1);

    {
        kernel.processes_lock.writeLock(current_task);
        defer kernel.processes_lock.writeUnlock(current_task);

        const gop = try kernel.processes.getOrPut(kernel.mem.heap.allocator, process);
        if (gop.found_existing) @panic("process already in processes list");
    }
    errdefer comptime unreachable;

    return .{ process, entry_task };
}

pub const CreateTaskOptions = struct {
    name: ?kernel.Task.Name = null,

    start_function: kernel.arch.scheduling.NewTaskFunction,
    arg1: u64,
    arg2: u64,
};

/// Creates a task in the given process.
///
/// The task is in the `ready` state and is not scheduled.
pub fn createUserTask(
    process: *Process,
    current_task: *kernel.Task,
    scheduler_locked: core.LockState,
    options: CreateTaskOptions,
) !*kernel.Task {
    var name: kernel.Task.Name = .{};
    if (options.name) |provided_name|
        name = provided_name
    else
        try name.writer().print(
            "{d}",
            .{process.next_task_id.fetchAdd(1, .monotonic)},
        );

    const entry_task = try kernel.Task.internal.create(current_task, .{
        .name = name,
        .start_function = options.start_function,
        .arg1 = options.arg1,
        .arg2 = options.arg2,
        .context = .{ .user = process },
    });
    errdefer {
        entry_task.state = .{ .dropped = .{} }; // `destroy` will assert this
        kernel.Task.internal.destroy(current_task, entry_task);
    }

    process.incrementReferenceCount();
    errdefer process.decrementReferenceCount(current_task, scheduler_locked);

    {
        process.tasks_lock.writeLock(current_task);
        defer process.tasks_lock.writeUnlock(current_task);

        const gop = try process.tasks.getOrPut(kernel.mem.heap.allocator, entry_task);
        if (gop.found_existing) @panic("task already in tasks list");
    }
    errdefer comptime unreachable;

    return entry_task;
}

pub fn incrementReferenceCount(process: *Process) void {
    _ = process.reference_count.fetchAdd(1, .acq_rel);
}

pub fn decrementReferenceCount(process: *Process, current_task: *kernel.Task, scheduler_locked: core.LockState) void {
    if (process.reference_count.fetchSub(1, .acq_rel) != 1) return;
    kernel.services.process_cleanup.queueProcessForCleanup(current_task, process, scheduler_locked);
}

pub fn format(process: *const Process, writer: *std.Io.Writer) !void {
    try writer.print("Process('{s}')", .{process.name.constSlice()});
}

pub const internal = struct {
    pub fn destroy(current_task: *kernel.Task, process: *Process) void {
        std.debug.assert(process.reference_count.load(.monotonic) == 0);

        std.debug.assert(process.queued_for_cleanup.load(.monotonic));
        process.queued_for_cleanup.store(false, .monotonic);

        std.debug.assert(!process.tasks_lock.isReadLocked() and !process.tasks_lock.isWriteLocked());
        std.debug.assert(process.tasks.count() == 0);
        process.tasks.clearAndFree(kernel.mem.heap.allocator);

        if (true) { // TODO: actually implement cleanup of the address space
            log.err("process destroy called - not fully implemented - leaking address space", .{});

            const frame = kernel.mem.phys.allocator.allocate() catch
                @panic("janky leaking process destory failed to allocate frame");

            const page_table: kernel.arch.paging.PageTable = kernel.arch.paging.PageTable.create(frame);
            kernel.mem.globals.core_page_table.copyTopLevelInto(page_table);

            process.address_space.init(current_task, .{
                .name = kernel.mem.AddressSpace.Name.fromSlice(
                    process.name.constSlice(),
                ) catch unreachable, // ensured in `kernel.config`
                .range = kernel.config.user_address_space_range,
                .page_table = page_table,
                .context = .{ .user = process },
            }) catch @panic("janky leaking process destroy failed to init address space");
        } else {
            // TODO: not called as `reinitialize` is not implemented
            process.address_space.reinitialize(current_task);
        }

        globals.cache.deallocate(current_task, process);
    }
};

pub const Name = std.BoundedArray(u8, kernel.config.process_name_length);

fn cacheConstructor(process: *Process, current_task: *kernel.Task) kernel.mem.cache.ConstructorError!void {
    var temp_name: Name = .{};
    temp_name.writer().print("temp {*}", .{process}) catch @panic("failed to set temporary name");

    process.* = .{
        .name = temp_name,
        .reference_count = .init(0),
        .address_space = undefined, // initialized below
    };

    const frame = kernel.mem.phys.allocator.allocate() catch |err| {
        log.warn("process constructor failed during frame allocation: {s}", .{@errorName(err)});
        return error.ObjectConstructionFailed;
    };
    errdefer {
        var frame_list: kernel.mem.phys.FrameList = .{};
        frame_list.push(frame);
        kernel.mem.phys.allocator.deallocate(frame_list);
    }

    const page_table: kernel.arch.paging.PageTable = kernel.arch.paging.PageTable.create(frame);
    kernel.mem.globals.core_page_table.copyTopLevelInto(page_table);

    process.address_space.init(current_task, .{
        .name = kernel.mem.AddressSpace.Name.fromSlice(
            temp_name.constSlice(),
        ) catch unreachable, // ensured in `kernel.config`
        .range = kernel.config.user_address_space_range,
        .page_table = page_table,
        .context = .{ .user = process },
    }) catch |err| {
        log.warn(
            "process constructor failed during address space initialization: {s}",
            .{@errorName(err)},
        );
        return error.ObjectConstructionFailed;
    };
}

fn cacheDestructor(process: *Process, current_task: *kernel.Task) void {
    const page_table = process.address_space.page_table;

    process.address_space.deinit(current_task);

    var frame_list: kernel.mem.phys.FrameList = .{};
    frame_list.push(page_table.physical_frame);
    kernel.mem.phys.allocator.deallocate(frame_list);
}

pub const globals = struct {
    /// The source of process objects.
    ///
    /// Initialized during `init.initializeCache`.
    var cache: kernel.mem.cache.Cache(
        Process,
        cacheConstructor,
        cacheDestructor,
    ) = undefined;
};

pub const init = struct {
    pub fn initializeProcesses(current_task: *kernel.Task) !void {
        log.debug("initializing process cache", .{});
        globals.cache.init(.{
            .name = try .fromSlice("process"),
        });

        log.debug("initializing process cleanup service", .{});
        try kernel.services.process_cleanup.init.initializeProcessCleanupService(current_task);
    }
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const log = kernel.debug.log.scoped(.process);
const builtin = @import("builtin");
