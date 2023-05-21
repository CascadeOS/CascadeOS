// SPDX-License-Identifier: MIT

const std = @import("std");
const kernel = @import("root");

pub const aarch64 = @import("aarch64/aarch64.zig");
pub const x86_64 = @import("x86_64/x86_64.zig");

pub const current = switch (kernel.info.arch) {
    .aarch64 => aarch64,
    .x86_64 => x86_64,
};
