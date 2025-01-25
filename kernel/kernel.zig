// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>

pub const acpi = @import("acpi/acpi.zig");
pub const arch = @import("arch/arch.zig");
pub const boot = @import("boot/boot.zig");
pub const config = @import("config.zig");
pub const debug = @import("debug/debug.zig");
pub const entry = @import("entry.zig");
pub const Executor = @import("Executor.zig");
pub const heap = @import("heap.zig");
pub const pci = @import("pci.zig");
pub const pmm = @import("pmm.zig");
pub const ResourceArena = @import("ResourceArena.zig");
pub const scheduler = @import("scheduler.zig");
pub const Stack = @import("Stack.zig");
pub const sync = @import("sync/sync.zig");
pub const Task = @import("Task.zig");
pub const time = @import("time.zig");
pub const vmm = @import("vmm/vmm.zig");

pub var executors: []Executor = &.{};

/// Get the executor with the given id.
///
/// It is the caller's responsibility to ensure the executor exists.
pub inline fn getExecutor(id: Executor.Id) *Executor {
    return &executors[@intFromEnum(id)];
}

pub const init = @import("init/init.zig");

pub const Panic = debug.Panic;

comptime {
    boot.exportEntryPoints();
}

pub const std_options: std.Options = .{
    .log_level = debug.log.log_level,
    .logFn = debug.log.stdLogImpl,
};

const std = @import("std");
