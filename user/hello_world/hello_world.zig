// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const cascade = @import("cascade");

pub const _start = cascade.entry._cascade_entry;
comptime {
    cascade.entry.exportEntry();
}

pub fn main() void {
    // TODO: actually print "hello world"...
}
