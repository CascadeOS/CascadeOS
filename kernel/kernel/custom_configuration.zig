// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub fn customConfiguration(
    b: *std.Build,
    architecture: CascadeTarget.Architecture,
    module: *std.Build.Module,
    options: Options,
) anyerror!void {
    // architecture options
    module.addImport(
        "cascade_architecture",
        options.architecture_specific_kernel_options_modules.get(architecture).?,
    );

    // kernel options
    module.addImport("kernel_options", options.kernel_option_module);

    // ssfn
    module.addCSourceFile(.{
        .file = b.path("kernel/kernel/init/output/ssfn.h"),
        .flags = &.{"-DSSFN_CONSOLEBITMAP_TRUECOLOR=1"},
        .language = .c,
    });
    module.addIncludePath(b.path(("kernel/kernel/init/output")));

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
    module.addImport(
        "DeviceTree",
        b.dependency("devicetree", .{}).module("DeviceTree"),
    );

    // sbi
    if (architecture == .riscv) {
        module.addImport("sbi", b.dependency("sbi", .{}).module("sbi"));
    }

    // Add assembly files
    assembly_files_blk: {
        const assembly_files_dir_path = b.pathJoin(&.{
            "kernel",
            "kernel",
            "arch",
            @tagName(architecture),
            "asm",
        });

        var assembly_files_dir = std.fs.cwd().openDir(assembly_files_dir_path, .{ .iterate = true }) catch break :assembly_files_blk;
        defer assembly_files_dir.close();

        var iter = assembly_files_dir.iterateAssumeFirstIteration();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) {
                std.debug.panic(
                    "found entry '{s}' with unexpected type '{t}' in assembly directory '{s}'\n",
                    .{ entry.name, entry.kind, assembly_files_dir_path },
                );
            }

            // only add assembly files with the .s or .S extension
            if (!std.mem.endsWith(u8, entry.name, ".s") and
                !std.mem.endsWith(u8, entry.name, ".S"))
            {
                continue;
            }

            const file_path = b.pathJoin(&.{ assembly_files_dir_path, entry.name });
            module.addAssemblyFile(b.path(file_path));
        }
    }
}

const std = @import("std");
const CascadeTarget = @import("../../build/CascadeTarget.zig").CascadeTarget;
const Options = @import("../../build/Options.zig");
