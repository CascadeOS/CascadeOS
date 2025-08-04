// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

hartid: u32,

const kernel = @import("kernel");

const core = @import("core");
const lib_riscv = @import("riscv");
const riscv = @import("riscv.zig");
const std = @import("std");
