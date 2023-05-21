// SPDX-License-Identifier: MIT

const std = @import("std");
const kernel = @import("root");

const limine = kernel.spec.limine;

fn setup() void {
    @panic("UNIMPLEMENTED"); // TODO: implement initial system setup
}

/// Entry point.
export fn _start() callconv(.Naked) noreturn {
    @call(.never_inline, setup, .{});
    @panic("setup returned");
}
