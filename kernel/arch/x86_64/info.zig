// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const x86_64 = @import("x86_64.zig");

pub var has_syscall: bool = false;
pub var has_execute_disable: bool = false;
pub var has_gib_pages: bool = false;
