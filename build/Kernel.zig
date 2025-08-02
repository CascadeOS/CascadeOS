// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub const Collection = std.AutoHashMapUnmanaged(CascadeTarget.Architecture, Kernel);

const Kernel = @This();

b: *std.Build,

architecture: CascadeTarget.Architecture,
options: Options,

final_kernel_binary_path: std.Build.LazyPath,

/// Installs both the stripped and fat kernel binaries.
install_kernel_binaries: *Step,

pub fn getKernels(
    b: *std.Build,
    step_collection: StepCollection,
    libraries: Library.Collection,
    tools: Tool.Collection,
    options: Options,
    all_architectures: []const CascadeTarget.Architecture,
) !Collection {
    var kernels: Collection = .{};
    try kernels.ensureTotalCapacity(b.allocator, @intCast(all_architectures.len));

    const sdf_builder = tools.get("sdf_builder").?;

    for (all_architectures) |architecture| {
        const kernel = try Kernel.create(
            b,
            architecture,
            libraries,
            sdf_builder,
            options,
            step_collection,
        );
        kernels.putAssumeCapacityNoClobber(architecture, kernel);
    }

    return kernels;
}

fn getDependencies(
    b: *std.Build,
    architecture: CascadeTarget.Architecture,
    libraries: Library.Collection,
) ![]const Library.Dependency {
    var dependencies = std.ArrayList(Library.Dependency).init(b.allocator);
    errdefer dependencies.deinit();

    const kernel_component = @import("../kernel/listing.zig").components[0];
    std.debug.assert(std.mem.eql(u8, kernel_component.name, "kernel"));

    for (kernel_component.library_dependencies) |dep| {
        switch (dep.condition) {
            .always => {},
            .architecture => |dep_architectures| blk: {
                for (dep_architectures) |dep_architecture| {
                    if (architecture == dep_architecture) break :blk;
                }
                continue;
            },
        }

        const library = libraries.get(dep.name) orelse
            std.debug.panic("kernel depends on non-existant library '{s}'", .{dep.name});

        try dependencies.append(.{ .import_name = dep.name, .library = library });
    }

    return try dependencies.toOwnedSlice();
}

fn create(
    b: *std.Build,
    architecture: CascadeTarget.Architecture,
    libraries: Library.Collection,
    sdf_builder: Tool,
    options: Options,
    step_collection: StepCollection,
) !Kernel {
    const dependencies = try getDependencies(b, architecture, libraries);

    const source_file_modules = try getSourceFileModules(b, options, dependencies);

    const ssfn_static_lib = try constructSSFNStaticLib(b, architecture);
    const uacpi_static_lib = try constructUACPIStaticLib(b, options, architecture);

    {
        const check_kernel_module = try constructKernelModule(
            b,
            architecture,
            dependencies,
            source_file_modules,
            options,
            options.all_enabled_kernel_option_module,
            ssfn_static_lib,
            uacpi_static_lib,
        );

        const check_exe = b.addExecutable(.{
            .name = "kernel_check",
            .root_module = check_kernel_module,
        });
        step_collection.registerCheck(check_exe);
    }

    const kernel_module = try constructKernelModule(
        b,
        architecture,
        dependencies,
        source_file_modules,
        options,
        options.kernel_option_module,
        ssfn_static_lib,
        uacpi_static_lib,
    );

    const kernel_exe = b.addExecutable(.{
        .name = "kernel",
        .root_module = kernel_module,
    });

    // TODO: disable the x86 backend for now, as it does not support disabling SSE
    // https://github.com/CascadeOS/CascadeOS/issues/99
    kernel_exe.use_llvm = true;

    kernel_exe.entry = .disabled;
    kernel_exe.want_lto = false;
    kernel_exe.pie = true; // allow kaslr
    kernel_exe.linkage = .static;

    kernel_exe.setLinkerScript(b.path(
        b.pathJoin(&.{
            "kernel",
            "kernel",
            "arch",
            @tagName(architecture),
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
        b.pathJoin(&.{ @tagName(architecture), "kernel-dwarf" }),
    );

    const install_fat_kernel_with_sdf_to_stripped_filepath = b.addInstallFile(
        fat_kernel_with_sdf,
        b.pathJoin(&.{ @tagName(architecture), "kernel" }),
    );

    // TODO: strip dwarf debug info https://github.com/CascadeOS/CascadeOS/issues/103
    // const stripped_kernel = blk: {
    //     const copy = b.addObjCopy(kernel_exe.getEmittedBin(), .{
    //         .basename = kernel_exe.out_filename,
    //         .strip = .debug_and_symbols,
    //     });
    //     break :blk copy.getOutput();
    // };

    // const stripped_kernel_with_sdf = blk: {
    //     const embed_sdf = b.addRunArtifact(sdf_builder.release_safe_exe);
    //     // action
    //     embed_sdf.addArg("embed");
    //     // binary_input_path
    //     embed_sdf.addFileArg(stripped_kernel);
    //     // binary_output_path
    //     const kernel_path = embed_sdf.addOutputFileArg("kernel");
    //     // sdf_input_path
    //     embed_sdf.addFileArg(sdf_data_path);

    //     break :blk kernel_path;
    // };

    // const install_stripped_kernel_with_sdf = b.addInstallFile(
    //     stripped_kernel_with_sdf,
    //     b.pathJoin(&.{ @tagName(architecture), "kernel" }),
    // );

    const install_both_kernel_binaries = try b.allocator.create(Step);
    install_both_kernel_binaries.* = Step.init(.{
        .id = .custom,
        .name = "install_both_kernel_binaries",
        .owner = b,
    });

    install_both_kernel_binaries.dependOn(&install_fat_kernel_with_sdf.step);
    install_both_kernel_binaries.dependOn(&install_fat_kernel_with_sdf_to_stripped_filepath.step);
    // install_both_kernel_binaries.dependOn(&install_stripped_kernel_with_sdf.step);

    step_collection.registerKernel(architecture, install_both_kernel_binaries);

    return Kernel{
        .b = b,
        .architecture = architecture,
        .options = options,

        .install_kernel_binaries = install_both_kernel_binaries,

        .final_kernel_binary_path = fat_kernel_with_sdf,
    };
}

fn constructSSFNStaticLib(b: *std.Build, architecture: CascadeTarget.Architecture) !*std.Build.Step.Compile {
    const ssfn_static_lib = b.addLibrary(.{
        .name = "ssfn",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = getKernelCrossTarget(architecture, b),
            .optimize = .ReleaseFast,
            .pic = true,
        }),
    });
    try ssfn_static_lib.installed_headers.append(.{
        .file = .{
            .source = b.path("kernel/kernel/init/output/ssfn.h"),
            .dest_rel_path = "ssfn.h",
        },
    });
    ssfn_static_lib.addCSourceFile(.{
        .file = b.path("kernel/kernel/init/output/ssfn.h"),
        .flags = &.{"-DSSFN_CONSOLEBITMAP_TRUECOLOR=1"},
        .language = .c,
    });
    return ssfn_static_lib;
}

fn constructUACPIStaticLib(
    b: *std.Build,
    options: Options,
    architecture: CascadeTarget.Architecture,
) !*std.Build.Step.Compile {
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

    const uacpi_static_lib = b.addLibrary(.{
        .name = "uacpi",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = getKernelCrossTarget(architecture, b),
            .optimize = .ReleaseFast,
            .pic = true,
        }),
    });

    uacpi_static_lib.addCSourceFiles(.{
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
    uacpi_static_lib.addIncludePath(uacpi_dep.path("include"));

    uacpi_static_lib.installHeadersDirectory(uacpi_dep.path("include"), "", .{});

    return uacpi_static_lib;
}

fn constructKernelModule(
    b: *std.Build,
    architecture: CascadeTarget.Architecture,
    dependencies: []const Library.Dependency,
    source_file_modules: []const SourceFileModule,
    options: Options,
    kernel_option_module: *std.Build.Module,
    ssfn_static_lib: *std.Build.Step.Compile,
    uacpi_static_lib: *std.Build.Step.Compile,
) !*std.Build.Module {
    const kernel_module = b.createModule(.{
        .root_source_file = b.path(b.pathJoin(&.{ "kernel", "kernel", "kernel.zig" })),
        .target = getKernelCrossTarget(architecture, b),
        .optimize = options.optimize,
        .sanitize_c = switch (options.optimize) {
            .ReleaseFast => .off,
            .ReleaseSmall => .trap,
            else => .full,
        },
    });

    for (dependencies) |dep| {
        const library_module = dep.library.cascade_modules.get(architecture) orelse
            std.debug.panic(
                "no module available for library '{s}' for architecture '{t}'",
                .{ dep.library.name, architecture },
            );

        kernel_module.addImport(dep.import_name, library_module);
    }

    // self reference
    kernel_module.addImport("kernel", kernel_module);

    // architecture options
    kernel_module.addImport(
        "cascade_architecture",
        options.architecture_specific_kernel_options_modules.get(architecture).?,
    );

    // kernel options
    kernel_module.addImport("kernel_options", kernel_option_module);

    // ssfn
    kernel_module.linkLibrary(ssfn_static_lib);

    // uacpi
    kernel_module.linkLibrary(uacpi_static_lib);

    // devicetree
    kernel_module.addImport("DeviceTree", b.dependency("devicetree", .{}).module("DeviceTree"));

    // sbi
    if (architecture == .riscv) {
        kernel_module.addImport("sbi", b.dependency("sbi", .{}).module("sbi"));
    }

    // source file modules
    for (source_file_modules) |module| {
        kernel_module.addImport(module.name, module.module);
    }

    // stop dwarf info from being stripped, we need it to generate the SDF data, it is split into a seperate file anyways
    kernel_module.strip = false;
    ssfn_static_lib.root_module.strip = false;
    uacpi_static_lib.root_module.strip = false;
    kernel_module.omit_frame_pointer = false;
    ssfn_static_lib.root_module.omit_frame_pointer = false;
    uacpi_static_lib.root_module.omit_frame_pointer = false;

    // apply architecture-specific configuration to the kernel
    switch (architecture) {
        .arm => {},
        .riscv => {},
        .x64 => {
            kernel_module.code_model = .kernel;
            ssfn_static_lib.root_module.code_model = .kernel;
            uacpi_static_lib.root_module.code_model = .kernel;
            kernel_module.red_zone = false;
            ssfn_static_lib.root_module.red_zone = false;
            uacpi_static_lib.root_module.red_zone = false;
        },
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
            kernel_module.addAssemblyFile(b.path(file_path));
        }
    }

    return kernel_module;
}

/// Returns a CrossTarget for building the kernel for the given architecture.
fn getKernelCrossTarget(architecture: CascadeTarget.Architecture, b: *std.Build) std.Build.ResolvedTarget {
    switch (architecture) {
        .arm => {
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

        .riscv => {
            const features = std.Target.riscv.Feature;
            var target_query = std.Target.Query{
                .cpu_arch = .riscv64,
                .os_tag = .freestanding,
                .abi = .none,
                .cpu_model = .{ .explicit = &std.Target.riscv.cpu.generic_rv64 },
            };
            target_query.cpu_features_add.addFeature(@intFromEnum(features.a));
            target_query.cpu_features_add.addFeature(@intFromEnum(features.m));
            // The compiler will not emit instructions from the below features but it is better to be explicit.
            target_query.cpu_features_add.addFeature(@intFromEnum(features.zicsr));
            target_query.cpu_features_add.addFeature(@intFromEnum(features.zifencei));
            target_query.cpu_features_add.addFeature(@intFromEnum(features.zihintpause));
            return b.resolveTargetQuery(target_query);
        },

        .x64 => {
            const features = std.Target.x86.Feature;
            var target_query = std.Target.Query{
                .cpu_arch = .x86_64,
                .os_tag = .freestanding,
                .abi = .none,
                .cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64_v2 },
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

const CascadeTarget = @import("CascadeTarget.zig").CascadeTarget;
const Library = @import("Library.zig");
const Options = @import("Options.zig");
const Tool = @import("Tool.zig");
const StepCollection = @import("StepCollection.zig");
