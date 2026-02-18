// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const cascade = @import("user_cascade");

pub const _start = cascade._cascade_start;
comptime {
    // TODO: well this is dumb, probably need a custom test runner
    if (!@import("builtin").is_test) @export(&_start, .{ .name = "_start" });
}

pub fn main() void {
    // TODO: actually print "hello world"...
}
