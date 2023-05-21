// SPDX-License-Identifier: MIT

const std = @import("std");
const kernel = @import("root");

pub const aarch64 = @import("aarch64/aarch64.zig");
pub const x86_64 = @import("x86_64/x86_64.zig");

const current = switch (kernel.info.arch) {
    .aarch64 => aarch64,
    .x86_64 => x86_64,
};

comptime {
    // ensure any architecture specific code is referenced
    _ = current;
}

pub fn disableInterruptsAndHalt() void {
    current.disableInterruptsAndHalt();
}
