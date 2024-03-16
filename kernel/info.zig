// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

// This must be kept in sync with the linker scripts.
pub const kernel_base_address = core.VirtualAddress.fromInt(0xffffffff80000000);
