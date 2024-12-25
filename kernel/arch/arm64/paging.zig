// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

pub const higher_half_start = core.VirtualAddress.fromInt(0xffff800000000000);

const std = @import("std");
const core = @import("core");
const kernel = @import("../../kernel.zig");
const arm64 = @import("arm64.zig");
const lib_arm64 = @import("arm64");
