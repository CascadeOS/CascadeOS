// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const Step = std.Build.Step;

const helpers = @import("helpers.zig");

const CascadeTarget = @import("CascadeTarget.zig").CascadeTarget;
const Library = @import("Library.zig");
const Options = @import("Options.zig");
const Tool = @import("Tool.zig");
const StepCollection = @import("StepCollection.zig");

const Kernel = @This();

const kernel_dependencies = @import("../kernel/dependencies.zig");

b: *std.Build,

target: CascadeTarget,
options: Options,

final_kernel_binary_path: std.Build.LazyPath,

/// Installs the debug-info stripped kernel with SDF data embedded.
install_final_kernel_binary: *Step,

/// Installs the kernel debug-info in a seperate file.
install_seperated_debug_step: *Step,

/// only used for generating a dependency graph
dependencies: []const *const Library,

pub const Collection = std.AutoHashMapUnmanaged(CascadeTarget, Kernel);

pub fn getKernels(
    b: *std.Build,
    step_collection: StepCollection,
    libraries: Library.Collection,
    tools: Tool.Collection,
    options: Options,
    targets: []const CascadeTarget,
) !Collection {
    var kernels: Collection = .{};
    try kernels.ensureTotalCapacity(b.allocator, @intCast(targets.len));

    const sdf_builder = tools.get("sdf_builder").?;

    for (targets) |target| {
        const kernel = try Kernel.create(
            b,
            target,
            libraries,
            sdf_builder,
            options,
        );
        kernels.putAssumeCapacityNoClobber(target, kernel);
        step_collection.registerKernel(
            target,
            kernel.install_final_kernel_binary,
            kernel.install_seperated_debug_step,
        );
    }

    return kernels;
}

fn create(
    b: *std.Build,
    target: CascadeTarget,
    libraries: Library.Collection,
    sdf_builder: Tool,
    options: Options,
) !Kernel {
    const kernel_exe = b.addExecutable(.{
        .name = "kernel",
        .root_source_file = .{ .path = helpers.pathJoinFromRoot(b, &.{ "kernel", "kernel.zig" }) },
        .target = getKernelCrossTarget(target, b),
        .optimize = options.optimize,
    });

    kernel_exe.setLinkerScriptPath(.{
        .path = helpers.pathJoinFromRoot(b, &.{
            "kernel",
            "arch",
            @tagName(target),
            "linker.ld",
        }),
    });
    kernel_exe.entry = .disabled;

    // self reference
    kernel_exe.root_module.addImport("kernel", &kernel_exe.root_module);

    // target options
    kernel_exe.root_module.addImport("cascade_target", options.target_specific_kernel_options_modules.get(target).?);

    // kernel options
    kernel_exe.root_module.addImport("kernel_options", options.kernel_option_module);

    const dependencies = blk: {
        var dependencies = std.ArrayList(*const Library).init(b.allocator);
        defer dependencies.deinit();

        // core dependencies
        for (kernel_dependencies.core_dependencies) |dependency| {
            const library = libraries.get(dependency) orelse
                std.debug.panic("kernel depends on non-existant library '{s}'", .{dependency});

            const library_module = library.cascade_modules.get(target) orelse
                std.debug.panic("no module available for library '{s}' for target '{s}'", .{ library.name, @tagName(target) });

            kernel_exe.root_module.addImport(library.name, library_module);
            try dependencies.append(library);
        }

        // target specific dependencies
        switch (target) {
            inline else => |tag| {
                const decl_name = comptime @tagName(tag) ++ "_dependencies";

                if (@hasDecl(kernel_dependencies, decl_name)) {
                    for (@field(kernel_dependencies, decl_name)) |dependency| {
                        const library = libraries.get(dependency) orelse
                            std.debug.panic("kernel depends on non-existant library '{s}'", .{dependency});

                        const library_module = library.cascade_modules.get(target) orelse
                            std.debug.panic("no module available for library '{s}' for target '{s}'", .{ library.name, @tagName(target) });

                        kernel_exe.root_module.addImport(library.name, library_module);
                        try dependencies.append(library);
                    }
                }
            },
        }

        break :blk try dependencies.toOwnedSlice();
    };

    // source file modules
    for (try getSourceFileModules(b, options, dependencies)) |module| {
        kernel_exe.root_module.addImport(module.name, module.module);
    }

    kernel_exe.want_lto = false;
    kernel_exe.pie = true;
    kernel_exe.root_module.omit_frame_pointer = false;

    // apply target-specific configuration to the kernel
    switch (target) {
        .aarch64 => {},
        .x86_64 => {
            kernel_exe.root_module.code_model = .kernel;
            kernel_exe.root_module.red_zone = false;
        },
    }

    // Add assembly files
    assembly_files_blk: {
        const assembly_files_dir_path = helpers.pathJoinFromRoot(b, &.{
            "kernel",
            "arch",
            @tagName(target),
            "asm",
        });

        var assembly_files_dir = std.fs.cwd().openDir(assembly_files_dir_path, .{ .iterate = true }) catch break :assembly_files_blk;
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

    const generate_sdf = b.addRunArtifact(sdf_builder.release_safe_compile_step);
    // action
    generate_sdf.addArg("generate");
    // binary_input_path
    generate_sdf.addFileArg(kernel_exe.getEmittedBin());
    // binary_output_path
    const sdf_data_path = generate_sdf.addOutputFileArg("sdf.output");
    // directory_prefixes_to_strip
    generate_sdf.addArg(options.root_path);

    const stripped_kernel_exe = b.addObjCopy(kernel_exe.getEmittedBin(), .{
        .basename = kernel_exe.out_filename,
        .strip = .debug,
        .extract_to_separate_file = true,
    });

    const embed_sdf = b.addRunArtifact(sdf_builder.release_safe_compile_step);
    // action
    embed_sdf.addArg("embed");
    // binary_input_path
    embed_sdf.addFileArg(stripped_kernel_exe.getOutput());
    // binary_output_path
    const final_kernel_binary_path = embed_sdf.addOutputFileArg("kernel");
    // sdf_input_path
    embed_sdf.addFileArg(sdf_data_path);

    const install_final_kernel_binary = b.addInstallFile(
        final_kernel_binary_path,
        b.pathJoin(&.{ @tagName(target), "kernel" }),
    );

    const install_seperated_debug = b.addInstallFile(
        stripped_kernel_exe.getOutputSeparatedDebug().?,
        b.pathJoin(&.{ @tagName(target), "kernel.debug" }),
    );

    return Kernel{
        .b = b,
        .target = target,
        .options = options,

        .final_kernel_binary_path = final_kernel_binary_path,

        .install_final_kernel_binary = &install_final_kernel_binary.step,
        .install_seperated_debug_step = &install_seperated_debug.step,

        .dependencies = dependencies,
    };
}

/// Returns a CrossTarget for building the kernel for the given target.
fn getKernelCrossTarget(self: CascadeTarget, b: *std.Build) std.Build.ResolvedTarget {
    switch (self) {
        .aarch64 => {
            const features = std.Target.aarch64.Feature;
            var target_query = std.Target.Query{
                .cpu_arch = .aarch64,
                .os_tag = .freestanding,
                .abi = .none,
                .cpu_model = .{ .explicit = &std.Target.aarch64.cpu.generic },
            };

            // Remove neon and fp features
            target_query.cpu_features_sub.addFeature(@intFromEnum(features.neon));
            target_query.cpu_features_sub.addFeature(@intFromEnum(features.fp_armv8));

            return b.resolveTargetQuery(target_query);
        },

        .x86_64 => {
            const features = std.Target.x86.Feature;
            var target_query = std.Target.Query{
                .cpu_arch = .x86_64,
                .os_tag = .freestanding,
                .abi = .none,
                .cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64 }, // TODO: As we only support modern machines maybe make this v2 or v3?
            };

            // Remove all SSE/AVX features
            target_query.cpu_features_sub.addFeature(@intFromEnum(features.x87));
            target_query.cpu_features_sub.addFeature(@intFromEnum(features.mmx));
            target_query.cpu_features_sub.addFeature(@intFromEnum(features.sse));
            target_query.cpu_features_sub.addFeature(@intFromEnum(features.f16c));
            target_query.cpu_features_sub.addFeature(@intFromEnum(features.fma));
            target_query.cpu_features_sub.addFeature(@intFromEnum(features.sse2));
            target_query.cpu_features_sub.addFeature(@intFromEnum(features.sse3));
            target_query.cpu_features_sub.addFeature(@intFromEnum(features.sse4_1));
            target_query.cpu_features_sub.addFeature(@intFromEnum(features.sse4_2));
            target_query.cpu_features_sub.addFeature(@intFromEnum(features.ssse3));
            target_query.cpu_features_sub.addFeature(@intFromEnum(features.vzeroupper));
            target_query.cpu_features_sub.addFeature(@intFromEnum(features.avx));
            target_query.cpu_features_sub.addFeature(@intFromEnum(features.avx2));
            target_query.cpu_features_sub.addFeature(@intFromEnum(features.avx512bw));
            target_query.cpu_features_sub.addFeature(@intFromEnum(features.avx512cd));
            target_query.cpu_features_sub.addFeature(@intFromEnum(features.avx512dq));
            target_query.cpu_features_sub.addFeature(@intFromEnum(features.avx512f));
            target_query.cpu_features_sub.addFeature(@intFromEnum(features.avx512vl));

            // Add soft float
            target_query.cpu_features_add.addFeature(@intFromEnum(features.soft_float));

            return b.resolveTargetQuery(target_query);
        },
    }
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
fn getSourceFileModules(b: *std.Build, options: Options, dependencies: []*const Library) ![]const SourceFileModule {
    var modules = std.ArrayList(SourceFileModule).init(b.allocator);
    errdefer modules.deinit();

    var file_paths = std.ArrayList([]const u8).init(b.allocator);
    defer file_paths.deinit();

    // add the kernel's files
    try addFilesRecursive(b, &modules, &file_paths, options.root_path, helpers.pathJoinFromRoot(b, &.{"kernel"}));

    // add each dependencies files
    var processed_libraries = std.AutoHashMap(*const Library, void).init(b.allocator);
    for (dependencies) |library| {
        try addFilesFromLibrary(b, &modules, &file_paths, options.root_path, library, &processed_libraries);
    }

    const files_option = b.addOptions();
    files_option.addOption([]const []const u8, "file_paths", file_paths.items);
    try modules.append(.{ .name = "embedded_source_files", .module = files_option.createModule() });

    return try modules.toOwnedSlice();
}

const DependencyIterator = struct {
    current_state: union(enum) {
        core: struct {
            dependencies: []const []const u8,
            index: usize,
        },
    },
};

fn addFilesFromLibrary(
    b: *std.Build,
    modules: *std.ArrayList(SourceFileModule),
    file_paths: *std.ArrayList([]const u8),
    root_path: []const u8,
    library: *const Library,
    processed_libraries: *std.AutoHashMap(*const Library, void),
) !void {
    if (processed_libraries.contains(library)) return;

    try addFilesRecursive(b, modules, file_paths, root_path, library.directory_path);

    try processed_libraries.put(library, {});

    for (library.dependencies) |dep| {
        try addFilesFromLibrary(b, modules, file_paths, root_path, dep.library, processed_libraries);
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
    var dir = try std.fs.cwd().openDir(target_path, .{ .iterate = true });
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
                            .root_source_file = .{ .path = path },
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
