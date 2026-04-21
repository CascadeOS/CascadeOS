// SPDX-License-Identifier: BSD-3-Clause
// SPDX-FileCopyrightText: CascadeOS Contributors

pub const exportEntry = @import("entry.zig").exportEntry;
pub const Syscall = @import("syscall.zig").Syscall;

pub fn exitThread() noreturn {
    _ = Syscall.call0(.exit_thread);
    unreachable;
}
