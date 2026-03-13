// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub const exportEntry = @import("entry.zig").exportEntry;
pub const Syscall = @import("syscall.zig").Syscall;

pub fn exitThread() noreturn {
    _ = Syscall.call0(.exit_thread);
    unreachable;
}
