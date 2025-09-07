// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const CascadeTarget = @import("../../build/CascadeTarget.zig").CascadeTarget;
const Options = @import("../../build/Options.zig");

pub fn customConfiguration(
    b: *std.Build,
    _: CascadeTarget.Architecture,
    module: *std.Build.Module,
    options: Options,
    is_check: bool,
) anyerror!void {
    // kernel options
    if (is_check) {
        module.addImport("kernel_options", options.all_enabled_kernel_option_module);
    } else {
        module.addImport("kernel_options", options.kernel_option_module);
    }

    // uacpi
    {
        // in uACPI DEBUG is more verbose than TRACE
        const uacpi_log_level: []const u8 = blk: {
            if (options.kernel_log_level) |force_log_level|
                break :blk switch (force_log_level) {
                    .debug => "-DUACPI_DEFAULT_LOG_LEVEL=UACPI_LOG_TRACE",
                    .verbose => "-DUACPI_DEFAULT_LOG_LEVEL=UACPI_LOG_DEBUG",
                };

            for (options.kernel_log_scopes) |scope| {
                if (std.mem.eql(u8, scope, "uacpi")) break :blk "-DUACPI_DEFAULT_LOG_LEVEL=UACPI_LOG_DEBUG";
            }

            break :blk "-DUACPI_DEFAULT_LOG_LEVEL=UACPI_LOG_WARN";
        };

        const uacpi_dep = b.dependency("uacpi", .{});

        module.addCSourceFiles(.{
            .root = uacpi_dep.path("source"),
            .files = &.{
                "default_handlers.c",
                "event.c",
                "interpreter.c",
                "io.c",
                "mutex.c",
                "namespace.c",
                "notify.c",
                "opcodes.c",
                "opregion.c",
                "osi.c",
                "registers.c",
                "resources.c",
                "shareable.c",
                "sleep.c",
                "stdlib.c",
                "tables.c",
                "types.c",
                "uacpi.c",
                "utilities.c",
            },
            .flags = &.{uacpi_log_level},
        });
        module.addIncludePath(uacpi_dep.path("include"));
    }

    // devicetree
    module.addImport("DeviceTree", b.dependency("devicetree", .{}).module("DeviceTree"));
}
