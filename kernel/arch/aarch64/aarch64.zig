// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");

const aarch64 = @This();

pub usingnamespace @import("lib_aarch64");

pub const init = @import("init.zig");

pub const ArchProcessor = struct {};

pub inline fn getProcessor() *kernel.Processor {
    return @ptrFromInt(aarch64.TPIDR_EL1.read());
}

pub inline fn earlyGetProcessor() ?*kernel.Processor {
    return @ptrFromInt(aarch64.TPIDR_EL1.read());
}

pub const paging = struct {
    pub const small_page_size = core.Size.from(4, .kib);
    pub const medium_page_size = core.Size.from(2, .mib);
    pub const large_page_size = core.Size.from(1, .gib);

    pub const standard_page_size = small_page_size;

    pub const higher_half = core.VirtualAddress.fromInt(0xffff800000000000);

    pub const PageTable = struct {};

    pub inline fn largestPageSize() core.Size {
        // FIXME: Are large pages an optional feature like x86?
        return large_page_size;
    }

    pub const init = struct {};
};

pub const scheduling = struct {};

comptime {
    if (kernel.info.arch != .aarch64) {
        @compileError("aarch64 implementation has been referenced when building " ++ @tagName(kernel.info.arch));
    }
}
