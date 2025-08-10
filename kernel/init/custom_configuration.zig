// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub fn customConfiguration(
    b: *std.Build,
    _: CascadeTarget.Architecture,
    module: *std.Build.Module,
    _: Options,
    _: bool,
) anyerror!void {

    // ssfn
    module.addCSourceFile(.{
        .file = b.path("kernel/init/output/ssfn.h"),
        .flags = &.{"-DSSFN_CONSOLEBITMAP_TRUECOLOR=1"},
        .language = .c,
    });
    module.addIncludePath(b.path(("kernel/init/output")));

    // devicetree
    module.addImport("DeviceTree", b.dependency("devicetree", .{}).module("DeviceTree"));
}

const std = @import("std");
const CascadeTarget = @import("../../build/CascadeTarget.zig").CascadeTarget;
const Options = @import("../../build/Options.zig");
