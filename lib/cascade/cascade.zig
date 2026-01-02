// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

pub const Syscall = @import("syscall.zig").Syscall;

const entry = @import("entry.zig");
pub const getEntryPoint = entry.getEntryPoint;

pub fn exitThread() noreturn {
    _ = Syscall.zeroArg(.exit_thread);
    unreachable;
}
