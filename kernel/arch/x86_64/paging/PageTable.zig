// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const x86_64 = @import("../x86_64.zig");

const paging = @import("paging.zig");

const bitjuggle = @import("bitjuggle");
const Boolean = bitjuggle.Boolean;
const Bitfield = bitjuggle.Bitfield;

pub const PageTable = extern struct {
};

