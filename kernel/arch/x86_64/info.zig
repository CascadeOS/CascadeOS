// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const x86_64 = @import("x86_64.zig");

pub var syscall: bool = false;
pub var execute_disable: bool = false;
pub var gib_pages: bool = false;
