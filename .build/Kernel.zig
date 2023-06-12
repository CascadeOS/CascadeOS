// SPDX-License-Identifier: MIT

const std = @import("std");
const Step = std.Build.Step;

const helpers = @import("helpers.zig");

const CascadeTarget = @import("CascadeTarget.zig").CascadeTarget;
const Library = @import("Library.zig");
const Options = @import("Options.zig");
const StepCollection = @import("StepCollection.zig");

const Kernel = @This();

b: *std.Build,

target: CascadeTarget,
options: Options,

install_step: *Step.InstallArtifact,

pub fn registerKernels(
    b: *std.Build,
    step_collection: StepCollection,
    libraries: Library.Collection,
    options: Options,
    all_targets: []const CascadeTarget,
) !void {
    const source_file_modules = try getSourceFileModules(b, libraries);

    for (all_targets) |target| {
        const kernel = try Kernel.create(b, target, libraries, options, source_file_modules);
        step_collection.registerKernel(target, &kernel.install_step.step);
    }
}

fn create(
    b: *std.Build,
    target: CascadeTarget,
    libraries: Library.Collection,
    options: Options,
    source_file_modules: []const SourceFileModule,
) !Kernel {
    const kernel_exe = b.addExecutable(.{
        .name = "kernel",
        .root_source_file = .{ .path = helpers.pathJoinFromRoot(b, &.{ "kernel", "root.zig" }) },
        .target = target.getCrossTarget(),
        .optimize = options.optimize,
    });

    kernel_exe.override_dest_dir = .{
        .custom = b.pathJoin(&.{
            @tagName(target),
            "root",
            "boot",
        }),
    };

    kernel_exe.setLinkerScriptPath(.{ .path = target.linkerScriptPath(b) });

    const kernel_module = blk: {
        const kernel_module = b.createModule(.{
            .source_file = .{ .path = helpers.pathJoinFromRoot(b, &.{ "kernel", "kernel.zig" }) },
        });

        // self reference
        try kernel_module.dependencies.put("kernel", kernel_module);

        // target options
        try kernel_module.dependencies.put("cascade_target", options.target_option_modules.get(target).?);

        // kernel options
        try kernel_module.dependencies.put("kernel_options", options.kernel_option_module);

        // dependencies
        const kernel_dependencies: []const []const u8 = @import("../kernel/dependencies.zig").dependencies;
        for (kernel_dependencies) |dependency| {
            const library = libraries.get(dependency).?;
            const library_module = library.modules.get(target) orelse continue;
            try kernel_module.dependencies.put(library.name, library_module);
        }

        // source file modules
        for (source_file_modules) |module| {
            try kernel_module.dependencies.put(module.name, module.module);
        }

        break :blk kernel_module;
    };

    kernel_exe.addModule("kernel", kernel_module);

    // TODO: LTO cannot be enabled https://github.com/CascadeOS/CascadeOS/issues/8
    kernel_exe.want_lto = false;
    kernel_exe.omit_frame_pointer = false;
    kernel_exe.disable_stack_probing = true;
    kernel_exe.pie = true;

    target.targetSpecificSetup(kernel_exe);

    return Kernel{
        .b = b,
        .target = target,
        .options = options,
        .install_step = b.addInstallArtifact(kernel_exe),
    };
}

const SourceFileModule = struct {
    name: []const u8,
    module: *std.Build.Module,
};

fn getSourceFileModules(b: *std.Build, libraries: Library.Collection) ![]const SourceFileModule {
    var modules = std.ArrayList(SourceFileModule).init(b.allocator);
    errdefer modules.deinit();

    var file_paths = std.ArrayList([]const u8).init(b.allocator);
    defer file_paths.deinit();

    const root_path = std.fmt.allocPrint(
        b.allocator,
        comptime "{s}" ++ std.fs.path.sep_str,
        .{b.build_root.path.?},
    ) catch unreachable;

    // add the kernel's files
    try addFilesRecursive(b, &modules, &file_paths, root_path, helpers.pathJoinFromRoot(b, &.{"kernel"}));

    // add each dependencies files
    const kernel_dependencies: []const []const u8 = @import("../kernel/dependencies.zig").dependencies;
    for (kernel_dependencies) |dependency| {
        const library = libraries.get(dependency).?;
        const root_file_path = library.getRootFilePath(b);
        try addFilesRecursive(b, &modules, &file_paths, root_path, std.fs.path.dirname(root_file_path).?);
    }

    // TODO: compress the embeded files https://github.com/CascadeOS/CascadeOS/issues/48
    // TODO: embed the std lib (all of it or parts?) https://github.com/CascadeOS/CascadeOS/issues/49

    const files_option = b.addOptions();
    files_option.addOption([]const []const u8, "file_paths", file_paths.items);
    try modules.append(.{ .name = "embedded_source_files", .module = files_option.createModule() });

    return try modules.toOwnedSlice();
}

fn addFilesRecursive(
    b: *std.Build,
    modules: *std.ArrayList(SourceFileModule),
    files: *std.ArrayList([]const u8),
    root_path: []const u8,
    target_path: []const u8,
) !void {
    var dir = try std.fs.cwd().openIterableDir(target_path, .{});
    defer dir.close();

    var it = dir.iterate();

    while (try it.next()) |file| {
        switch (file.kind) {
            .file => {
                const extension = std.fs.path.extension(file.name);
                // for now only zig files should be included
                if (std.mem.eql(u8, extension, ".zig")) {
                    const path = b.pathJoin(&.{ target_path, file.name });

                    if (removeRootPrefixFromPath(path, root_path)) |name| {
                        try files.append(name);
                        const module = b.createModule(.{
                            .source_file = .{ .path = path },
                        });
                        try modules.append(.{ .name = name, .module = module });
                    } else {
                        // If the file does not start with the root path, what does that even mean?
                        std.debug.panic("file is not in root path: '{s}'", .{path});
                    }
                }
            },
            .directory => {
                if (file.name[0] == '.') continue; // skip hidden directories

                const path = b.pathJoin(&.{ target_path, file.name });
                try addFilesRecursive(b, modules, files, root_path, path);
            },
            else => {},
        }
    }
}

fn removeRootPrefixFromPath(path: []const u8, root_prefix: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, path, root_prefix)) {
        return path[(root_prefix.len)..];
    }
    return null;
}
