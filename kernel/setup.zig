// SPDX-License-Identifier: MIT

const std = @import("std");
const kernel = @import("root");

pub fn setup() void {
    // we try to get output up and running as soon as possible.
    kernel.arch.interface.setupEarlyOutput();

    // print starting message
    kernel.arch.interface.earlyOutputRaw(comptime "starting CircuitOS " ++ kernel.info.version ++ "\n");

    // now that we have basic output functionality we can start using the logging system
    const log = kernel.log.scoped(.setup);

    // switch the panic implementation to use it out basic output functionality
    // log.info("loading simplified panic handler", .{});
    // kernel.setPanicFunction(simplePanic);

    log.info("hello world", .{});

    @panic("UNIMPLEMENTED"); // TODO: implement initial system setup
}
