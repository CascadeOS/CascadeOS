// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

pub const acpi = @import("acpi/acpi.zig");
pub const config = @import("config.zig");
pub const debug = @import("debug/debug.zig");
pub const entry = @import("entry.zig");
pub const Executor = @import("Executor.zig");
pub const init = @import("init/init.zig");
pub const mem = @import("mem/mem.zig");
pub const pci = @import("pci.zig");
pub const sync = @import("sync/sync.zig");
pub const Task = @import("task/Task.zig");
pub const time = @import("time.zig");
pub const user = @import("user/user.zig");

pub const Context = union(Type) {
    kernel,
    user: *user.Process,

    pub const Type = enum {
        kernel,
        user,
    };
};
