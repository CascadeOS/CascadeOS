// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const x86_64 = @import("x86_64.zig");

// TODO: implement paging support for x86_64
pub const PageTable = extern struct {};
