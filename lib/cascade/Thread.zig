// SPDX-License-Identifier: 0BSD
// SPDX-FileCopyrightText: CascadeOS Contributors

const cascade = @import("cascade.zig");

pub const Thread = enum(u64) {
    _,

    pub fn exitCurrent() noreturn {
        _ = cascade.Syscall.call0(.thread_exit_current);
        unreachable;
    }
};
