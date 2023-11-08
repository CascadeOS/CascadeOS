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

/// only used for generating a dependency graph
dependencies: []const *const Library,

pub const Collection = std.AutoHashMapUnmanaged(CascadeTarget, Kernel);

pub fn getKernels(
    b: *std.Build,
    step_collection: StepCollection,
    libraries: Library.Collection,
    options: Options,
    targets: []const CascadeTarget,
) !Collection {
    var kernels: Collection = .{};
    try kernels.ensureTotalCapacity(b.allocator, @intCast(targets.len));

    const source_file_modules = try getSourceFileModules(b, libraries);

    for (targets) |target| {
        const kernel = try Kernel.create(b, target, libraries, options, source_file_modules);
        kernels.putAssumeCapacityNoClobber(target, kernel);
        step_collection.registerKernel(target, &kernel.install_step.step);
    }

    return kernels;
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

    kernel_exe.setLinkerScriptPath(.{ .path = target.linkerScriptPath(b) });

    const declared_dependencies: []const []const u8 = @import("../kernel/dependencies.zig").dependencies;
    var dependencies = try std.ArrayListUnmanaged(*const Library).initCapacity(b.allocator, declared_dependencies.len);
    defer dependencies.deinit(b.allocator);

    const kernel_module = blk: {
        const kernel_module = b.createModule(.{
            .source_file = .{ .path = helpers.pathJoinFromRoot(b, &.{ "kernel", "kernel.zig" }) },
        });

        // self reference
        try kernel_module.dependencies.put("kernel", kernel_module);

        // target options
        try kernel_module.dependencies.put("cascade_target", options.target_specific_kernel_options_modules.get(target).?);

        // kernel options
        try kernel_module.dependencies.put("kernel_options", options.kernel_option_module);

        // dependencies

        for (declared_dependencies) |dependency| {
            const library = libraries.get(dependency).?;
            const library_module = library.cascade_modules.get(target) orelse continue;
            try kernel_module.dependencies.put(library.name, library_module);
            dependencies.appendAssumeCapacity(library);
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
    kernel_exe.pie = true;

    // TODO: Implement DWARF based stack unwinding
    kernel_exe.omit_frame_pointer = false;

    target.targetSpecificSetup(kernel_exe);

    // Add assembly files
    assembly_files_blk: {
        const assembly_files_dir_path = helpers.pathJoinFromRoot(b, &.{
            "kernel",
            "arch",
            @tagName(target),
            "asm",
        });

        var assembly_files_dir = std.fs.cwd().openIterableDir(assembly_files_dir_path, .{}) catch break :assembly_files_blk;
        defer assembly_files_dir.close();

        var iter = assembly_files_dir.iterateAssumeFirstIteration();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) {
                std.debug.panic(
                    "found entry '{s}' with unexpected type '{s}' in assembly directory '{s}'\n",
                    .{ entry.name, @tagName(entry.kind), assembly_files_dir_path },
                );
            }

            const file_path = b.pathJoin(&.{ assembly_files_dir_path, entry.name });
            kernel_exe.addAssemblyFile(.{ .path = file_path });
        }
    }

    const install_step = b.addInstallArtifact(
        kernel_exe,
        .{ .dest_dir = .{ .override = .{ .custom = b.pathJoin(&.{@tagName(target)}) } } },
    );

    return Kernel{
        .b = b,
        .target = target,
        .options = options,
        .install_step = install_step,

        .dependencies = try dependencies.toOwnedSlice(b.allocator),
    };
}

/// Module created from a source file.
const SourceFileModule = struct {
    /// The file name and also the name of the module.
    name: []const u8,
    module: *std.Build.Module,
};

/// Build the data for a source file map.
///
/// Returns a `std.Build.Module` per source file with the name of the file as the module import name,
/// with a `embedded_source_files` module containing an array of the file names.
///
/// This allows combining `ComptimeStringHashMap` and `@embedFile(file_name)`, providing access to the contents of
/// source files by file path key, which is exactly what is needed for printing source code in stacktraces.
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
    var processed_libraries = std.AutoHashMap(*Library, void).init(b.allocator);

    for (kernel_dependencies) |library_name| {
        const library: *Library = libraries.get(library_name).?;
        try addFilesFromLibrary(b, &modules, &file_paths, root_path, libraries, library, &processed_libraries);
    }

    // TODO: compress the embeded files https://github.com/CascadeOS/CascadeOS/issues/48
    // TODO: embed the std lib (all of it or parts?) https://github.com/CascadeOS/CascadeOS/issues/49

    const files_option = b.addOptions();
    files_option.addOption([]const []const u8, "file_paths", file_paths.items);
    try modules.append(.{ .name = "embedded_source_files", .module = files_option.createModule() });

    return try modules.toOwnedSlice();
}

fn addFilesFromLibrary(
    b: *std.Build,
    modules: *std.ArrayList(SourceFileModule),
    file_paths: *std.ArrayList([]const u8),
    root_path: []const u8,
    libraries: Library.Collection,
    library: *Library,
    processed_libraries: *std.AutoHashMap(*Library, void),
) !void {
    if (processed_libraries.contains(library)) return;

    try addFilesRecursive(b, modules, file_paths, root_path, library.directory_path);

    try processed_libraries.put(library, {});

    for (library.dependencies) |dep| {
        try addFilesFromLibrary(b, modules, file_paths, root_path, libraries, dep, processed_libraries);
    }
}

/// Adds all files recursively in the given target path to the build.
///
/// Creates a `SourceFileModule` for each `.zig` file found, and adds the file path to the `files` array.
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

/// Returns the path without the root prefix, or `null` if the path did not start with the root prefix.
fn removeRootPrefixFromPath(path: []const u8, root_prefix: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, path, root_prefix)) {
        return path[(root_prefix.len)..];
    }
    return null;
}
