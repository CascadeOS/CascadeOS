// SPDX-License-Identifier: MIT

const std = @import("std");
const kernel = @import("root");

const log = kernel.log.scoped(.setup);

pub fn setup() void {
    // we try to get output up and running as soon as possible so we can start logging
    kernel.arch.setup.setupEarlyOutput();

    // print starting message
    kernel.arch.setup.getEarlyOutputWriter().writeAll(
        comptime "starting CircuitOS " ++ kernel.info.version ++ "\n",
    ) catch {};

    log.info("hello world", .{});

    @panic("UNIMPLEMENTED"); // TODO: implement initial system setup
}
