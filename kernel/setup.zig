// SPDX-License-Identifier: MIT

const std = @import("std");
const kernel = @import("root");

const log = kernel.log.scoped(.setup);

pub fn setup() void {
    // we try to get output up and running as soon as possible
    kernel.arch.setup.setupEarlyOutput();

    // now that we have early output, we can switch to a simple panic handler
    kernel.panic_implementation.switchTo(.simple);

    // print starting message
    kernel.arch.setup.getEarlyOutputWriter().writeAll(
        comptime "starting CircuitOS " ++ kernel.info.version ++ "\n",
    ) catch {};

    log.info("starting architecture specific initialization", .{});
    kernel.arch.setup.earlyArchInitialization();

    kernel.utils.panic("UNIMPLEMENTED"); // TODO: implement initial system setup
}