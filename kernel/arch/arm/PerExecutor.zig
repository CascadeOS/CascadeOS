// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

mpidr: u64,

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const arm = @import("arm.zig");
const lib_arm = @import("arm");
