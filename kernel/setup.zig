// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

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

    log.info("performing early system initialization", .{});
    kernel.arch.setup.earlyArchInitialization();

    log.info("capturing bootloader information", .{});
    kernel.boot.captureBootloaderInformation();

    log.info("capturing system information", .{});
    kernel.arch.setup.captureSystemInformation();

    log.info("configuring system features", .{});
    kernel.arch.setup.configureSystemFeatures();

    core.panic("UNIMPLEMENTED"); // TODO: implement initial system setup
}
