// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub const acpi = @import("acpi/acpi.zig");
pub const arch = @import("arch/arch.zig");
pub const boot = @import("boot/boot.zig");
pub const config = @import("config.zig");
pub const debug = @import("debug/debug.zig");
pub const entry = @import("entry.zig");
pub const Executor = @import("Executor.zig");
pub const mem = @import("mem/mem.zig");
pub const pci = @import("pci.zig");
pub const Process = @import("Process.zig");
pub const scheduler = @import("scheduler.zig");
pub const services = @import("services/services.zig");
pub const sync = @import("sync/sync.zig");
pub const Task = @import("Task.zig");
pub const time = @import("time.zig");

pub var executors: []Executor = &.{};

/// Get the executor with the given id.
///
/// It is the caller's responsibility to ensure the executor exists.
pub inline fn getExecutor(id: Executor.Id) *Executor {
    return &executors[@intFromEnum(id)];
}

pub var processes_lock: sync.RwLock = .{};
pub var processes: std.AutoArrayHashMapUnmanaged(*Process, void) = .{};

pub const Context = union(Type) {
    kernel,
    user: *Process,

    pub const Type = enum {
        kernel,
        user,
    };
};

/// All currently living kernel tasks.
///
/// This does not include the per-executor scheduler or bootstrap init tasks.
pub var kernel_tasks: std.AutoArrayHashMapUnmanaged(*Task, void) = .{};
pub var kernel_tasks_lock: sync.RwLock = .{};

pub const init = @import("init/init.zig");

pub const panic = debug.panic_interface;

comptime {
    boot.exportEntryPoints();
}

pub const std_options: std.Options = .{
    .log_level = debug.log.log_level.toStd(),
    .logFn = debug.log.stdLogImpl,
};

const std = @import("std");
