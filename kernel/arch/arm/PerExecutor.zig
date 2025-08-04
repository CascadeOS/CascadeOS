// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

mpidr: u64,

const kernel = @import("kernel");

const arm = @import("arm.zig");
const core = @import("core");
const lib_arm = @import("arm");
const std = @import("std");
