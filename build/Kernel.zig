// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>

pub const Collection = std.AutoHashMapUnmanaged(CascadeTarget, Kernel);

const Kernel = @This();

b: *std.Build,

target: CascadeTarget,
options: Options,

final_kernel_binary_path: std.Build.LazyPath,

/// Installs both the stripped and fat kernel binaries.
install_kernel_binaries: *Step,

/// only used for generating a dependency graph
dependencies: []const Library.Dependency,

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
    const uacpi_dep = b.dependency("uacpi", .{});

    for (targets) |target| {
        const kernel = try Kernel.create(
            b,
            target,
            libraries,
            sdf_builder,
            options,
            step_collection,
            uacpi_dep,
        );
        kernels.putAssumeCapacityNoClobber(target, kernel);
    }

    return kernels;
}

fn getDependencies(
    b: *std.Build,
    target: CascadeTarget,
    libraries: Library.Collection,
) ![]const Library.Dependency {
    var dependencies = std.ArrayList(Library.Dependency).init(b.allocator);
    errdefer dependencies.deinit();

    for (kernel_dependencies.dependencies) |dep| {
        const library = libraries.get(dep.name) orelse
            std.debug.panic("kernel depends on non-existant library '{s}'", .{dep.name});

        const import_name = dep.import_name orelse library.name;

        try dependencies.append(.{ .import_name = import_name, .library = library });
    }

    // target specific dependencies
    switch (target) {
        inline else => |tag| {
            const decl_name = comptime @tagName(tag) ++ "_dependencies";

            if (@hasDecl(kernel_dependencies, decl_name)) {
                for (@field(kernel_dependencies, decl_name)) |dep| {
                    const library = libraries.get(dep.name) orelse
                        std.debug.panic("kernel depends on non-existant library '{s}'", .{dep.name});

                    const import_name = dep.import_name orelse library.name;

                    try dependencies.append(.{ .import_name = import_name, .library = library });
                }
            }
        },
    }

    return try dependencies.toOwnedSlice();
}

fn create(
    b: *std.Build,
    target: CascadeTarget,
    libraries: Library.Collection,
    sdf_builder: Tool,
    options: Options,
    step_collection: StepCollection,
    uacpi_dep: *std.Build.Dependency, // this is fine for one external dep but needs to be improved for multiple
) !Kernel {
    const dependencies = try getDependencies(b, target, libraries);

    const source_file_modules = try getSourceFileModules(b, options, dependencies);

    const kernel_module = try constructKernelModule(
        b,
        target,
        dependencies,
        source_file_modules,
        options,
        uacpi_dep,
    );

    {
        const check_exe = b.addExecutable(.{
            .name = "kernel",
            .root_module = kernel_module,
        });
        step_collection.registerCheck(check_exe);
    }

    const kernel_exe = b.addExecutable(.{
        .name = "kernel",
        .root_module = kernel_module,
    });

    kernel_exe.entry = .disabled;
    kernel_exe.want_lto = false;
    kernel_exe.pie = true; // allow kaslr
    kernel_exe.linkage = .static;

    kernel_exe.setLinkerScript(b.path(
        b.pathJoin(&.{
            "kernel",
            "arch",
            @tagName(target),
            "linker.ld",
        }),
    ));

    const generate_sdf = b.addRunArtifact(sdf_builder.release_safe_exe);
    // action
    generate_sdf.addArg("generate");
    // binary_input_path
    generate_sdf.addFileArg(kernel_exe.getEmittedBin());
    // binary_output_path
    const sdf_data_path = generate_sdf.addOutputFileArg("sdf.output");
    // directory_prefixes_to_strip
    generate_sdf.addArg(options.root_path);

    const fat_kernel_with_sdf = blk: {
        const embed_sdf = b.addRunArtifact(sdf_builder.release_safe_exe);
        // action
        embed_sdf.addArg("embed");
        // binary_input_path
        embed_sdf.addFileArg(kernel_exe.getEmittedBin());
        // binary_output_path
        const kernel_path = embed_sdf.addOutputFileArg("kernel");
        // sdf_input_path
        embed_sdf.addFileArg(sdf_data_path);

        break :blk kernel_path;
    };

    const install_fat_kernel_with_sdf = b.addInstallFile(
        fat_kernel_with_sdf,
        b.pathJoin(&.{ @tagName(target), "kernel-dwarf" }),
    );

    const stripped_kernel = blk: {
        const copy = b.addObjCopy(kernel_exe.getEmittedBin(), .{
            .basename = kernel_exe.out_filename,
            .strip = .debug_and_symbols,
        });
        break :blk copy.getOutput();
    };

    const stripped_kernel_with_sdf = blk: {
        const embed_sdf = b.addRunArtifact(sdf_builder.release_safe_exe);
        // action
        embed_sdf.addArg("embed");
        // binary_input_path
        embed_sdf.addFileArg(stripped_kernel);
        // binary_output_path
        const kernel_path = embed_sdf.addOutputFileArg("kernel");
        // sdf_input_path
        embed_sdf.addFileArg(sdf_data_path);

        break :blk kernel_path;
    };

    const install_stripped_kernel_with_sdf = b.addInstallFile(
        stripped_kernel_with_sdf,
        b.pathJoin(&.{ @tagName(target), "kernel" }),
    );

    const install_both_kernel_binaries = try b.allocator.create(Step);
    install_both_kernel_binaries.* = Step.init(.{
        .id = .custom,
        .name = "install_both_kernel_binaries",
        .owner = b,
    });

    install_both_kernel_binaries.dependOn(&install_fat_kernel_with_sdf.step);
    install_both_kernel_binaries.dependOn(&install_stripped_kernel_with_sdf.step);

    step_collection.registerKernel(target, install_both_kernel_binaries);

    return Kernel{
        .b = b,
        .target = target,
        .options = options,

        .install_kernel_binaries = install_both_kernel_binaries,

        .final_kernel_binary_path = stripped_kernel_with_sdf,

        .dependencies = dependencies,
    };
}

fn constructKernelModule(
    b: *std.Build,
    target: CascadeTarget,
    dependencies: []const Library.Dependency,
    source_file_modules: []const SourceFileModule,
    options: Options,
    uacpi_dep: *std.Build.Dependency,
) !*std.Build.Module {
    const kernel_module = b.createModule(.{
        .root_source_file = b.path(b.pathJoin(&.{ "kernel", "kernel.zig" })),
        .target = getKernelCrossTarget(target, b),
        .optimize = options.optimize,
    });

    for (dependencies) |dep| {
        const library_module = dep.library.cascade_modules.get(target) orelse
            std.debug.panic("no module available for library '{s}' for target '{s}'", .{ dep.library.name, @tagName(target) });

        kernel_module.addImport(dep.import_name, library_module);
    }

    // self reference
    kernel_module.addImport("kernel", kernel_module);

    // target options
    kernel_module.addImport("cascade_target", options.target_specific_kernel_options_modules.get(target).?);

    // kernel options
    kernel_module.addImport("kernel_options", options.kernel_option_module);

    // ssfn
    kernel_module.addCSourceFile(.{ .file = b.path("kernel/init/framebuffer/ssfn.c") });
    kernel_module.addIncludePath(b.path(("kernel/init/framebuffer")));

    const uacpi_log_level: []const u8 =
        if (options.kernel_force_debug_log or std.mem.indexOf(
        u8,
        options.kernel_forced_debug_log_scopes,
        "uacpi",
    ) != null)
        "-DUACPI_DEFAULT_LOG_LEVEL=UACPI_LOG_TRACE"
    else
        "-DUACPI_DEFAULT_LOG_LEVEL=UACPI_LOG_WARN";

    // uacpi
    kernel_module.addCSourceFiles(.{
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
    kernel_module.addIncludePath(uacpi_dep.path("include"));

    // source file modules
    for (source_file_modules) |module| {
        kernel_module.addImport(module.name, module.module);
    }

    // stop dwarf info from being stripped, we need it to generate the SDF data, it is split into a seperate file anyways
    kernel_module.strip = false;
    kernel_module.omit_frame_pointer = false;

    // apply target-specific configuration to the kernel
    switch (target) {
        .arm64 => {},
        .x64 => {
            kernel_module.code_model = .kernel;
            kernel_module.red_zone = false;
        },
    }

    // Add assembly files
    assembly_files_blk: {
        const assembly_files_dir_path = b.pathJoin(&.{
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
            kernel_module.addAssemblyFile(b.path(file_path));
        }
    }

    return kernel_module;
}

/// Returns a CrossTarget for building the kernel for the given target.
fn getKernelCrossTarget(self: CascadeTarget, b: *std.Build) std.Build.ResolvedTarget {
    switch (self) {
        .arm64 => {
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

        .x64 => {
            const features = std.Target.x86.Feature;
            var target_query = std.Target.Query{
                .cpu_arch = .x86_64,
                .os_tag = .freestanding,
                .abi = .none,
                // TODO: Is v3 too new? v2 might be better but then we lose BMI and BMI2.
                .cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64_v3 },
            };

            // Remove all SSE/AVX features
            target_query.cpu_features_sub.addFeature(@intFromEnum(features.x87));
            target_query.cpu_features_sub.addFeature(@intFromEnum(features.mmx));
            target_query.cpu_features_sub.addFeature(@intFromEnum(features.sse));
            target_query.cpu_features_sub.addFeature(@intFromEnum(features.f16c));
            target_query.cpu_features_sub.addFeature(@intFromEnum(features.fma));
            target_query.cpu_features_sub.addFeature(@intFromEnum(features.fxsr));
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
            target_query.cpu_features_sub.addFeature(@intFromEnum(features.evex512));

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
fn getSourceFileModules(b: *std.Build, options: Options, dependencies: []const Library.Dependency) ![]const SourceFileModule {
    var modules = std.ArrayList(SourceFileModule).init(b.allocator);
    errdefer modules.deinit();

    var file_paths = std.ArrayList([]const u8).init(b.allocator);
    defer file_paths.deinit();

    // add the kernel's files
    try addFilesRecursive(b, &modules, &file_paths, options.root_path, b.pathJoin(&.{"kernel"}));

    // add each dependencies files
    var processed_libraries = std.AutoHashMap(*const Library, void).init(b.allocator);
    for (dependencies) |dep| {
        try addFilesFromLibrary(b, &modules, &file_paths, options.root_path, dep.library, &processed_libraries);
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

                    try files.append(path);
                    const module = b.createModule(.{
                        .root_source_file = b.path(path),
                    });
                    try modules.append(.{ .name = path, .module = module });
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

const std = @import("std");
const Step = std.Build.Step;

const helpers = @import("helpers.zig");

const CascadeTarget = @import("CascadeTarget.zig").CascadeTarget;
const Library = @import("Library.zig");
const Options = @import("Options.zig");
const Tool = @import("Tool.zig");
const StepCollection = @import("StepCollection.zig");

const kernel_dependencies = @import("../kernel/dependencies.zig");
