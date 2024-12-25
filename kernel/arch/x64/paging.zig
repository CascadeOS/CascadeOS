// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

pub const higher_half_start = core.VirtualAddress.fromInt(0xffff800000000000);

const std = @import("std");
const core = @import("core");
const kernel = @import("../../kernel.zig");
const x64 = @import("x64.zig");
const lib_x64 = @import("x64");
