// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");

const log = kernel.debug.log.scoped(.time);

pub const init = struct {
    pub fn initTime() linksection(kernel.info.init_code) void {
        log.debug("registering architectural time sources", .{});
        kernel.arch.init.registerArchitecturalTimeSources();
    }
};
