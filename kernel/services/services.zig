// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub const process_cleanup = @import("process_cleanup.zig");
pub const task_cleanup = @import("task_cleanup.zig");

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
