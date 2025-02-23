// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>

hartid: u32,

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const riscv = @import("riscv.zig");
const lib_riscv = @import("riscv");
