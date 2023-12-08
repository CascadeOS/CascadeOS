// SPDX-License-Identifier: MIT

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");
const x86_64 = @import("x86_64.zig");

pub var has_syscall: bool = false;
pub var has_execute_disable: bool = false;
pub var has_gib_pages: bool = false;
