// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub const maximum_number_of_io_apics = 8;

const kernel = @import("kernel");

const core = @import("core");
const std = @import("std");
