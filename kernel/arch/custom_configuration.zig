// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: CascadeOS Contributors

const std = @import("std");

const CascadeTarget = @import("../../build/CascadeTarget.zig");
const Options = @import("../../build/Options.zig");

pub fn customConfiguration(
    b: *std.Build,
    architecture: CascadeTarget.Architecture,
    module: *std.Build.Module,
    options: Options,
    _: bool,
) anyerror!void {
    // architecture options
    module.addImport(
        "cascade_architecture",
        options.architecture_specific_kernel_options_modules.get(architecture).?,
    );

    // sbi
    if (architecture == .riscv) {
        module.addImport("sbi", b.dependency("sbi", .{}).module("sbi"));
    }

    // Add assembly files
    assembly_files_blk: {
        const io = b.graph.io;

        const assembly_files_dir_path = b.pathJoin(&.{
            "kernel",
            "arch",
            @tagName(architecture),
            "asm",
        });

        var assembly_files_dir = std.Io.Dir.cwd().openDir(
            b.graph.io,
            assembly_files_dir_path,
            .{ .iterate = true },
        ) catch break :assembly_files_blk;
        defer assembly_files_dir.close(io);

        var iter = assembly_files_dir.iterateAssumeFirstIteration();
        while (try iter.next(io)) |entry| {
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
