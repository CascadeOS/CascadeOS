// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const builtin = @import("builtin");

pub const Syscall = @import("syscall.zig").Syscall;

/// This must be exported with the name `_start` in the root file like `pub export const _start = cascade._cascade_start;`
pub const _cascade_start = @import("entry.zig")._cascade_start;

pub fn exitThread() noreturn {
    _ = Syscall.call0(.exit_thread);
    unreachable;
}
