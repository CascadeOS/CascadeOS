// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub const Collection = std.AutoHashMapUnmanaged(CascadeTarget.Architecture, Kernel);

const Kernel = @This();

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
    const sdf_builder = tools.get("sdf_builder").?;

    var kernels: Collection = .{};
    try kernels.ensureTotalCapacity(b.allocator, @intCast(all_architectures.len));

    for (all_architectures) |architecture| {
        kernels.putAssumeCapacityNoClobber(
            architecture,
            try constructKernel(
                b,
                step_collection,
                libraries,
                sdf_builder,
                options,
                architecture,
            ),
        );
    }

    return kernels;
}

fn constructKernel(
    b: *std.Build,
    step_collection: StepCollection,
    all_libraries: Library.Collection,
    sdf_builder: Tool,
    options: Options,
    architecture: CascadeTarget.Architecture,
) !Kernel {
    { // check exe
        const check_module = try constructKernelModule(
            b,
            all_libraries,
            options,
            architecture,
            true,
        );
        const check_exe = b.addExecutable(.{
            .name = "kernel_check",
            .root_module = check_module,
        });
        step_collection.registerCheck(check_exe);
    }

    const kernel_module = try constructKernelModule(
        b,
        all_libraries,
        options,
        architecture,
        false,
    );

    const kernel_exe = b.addExecutable(.{
        .name = "kernel",
        .root_module = kernel_module,
    });

    if (architecture == .x64) {
        // TODO: disable the x86 backend for now, as it does not support disabling SSE
        // https://github.com/CascadeOS/CascadeOS/issues/99
        kernel_exe.use_llvm = true;
    }

    kernel_exe.entry = .disabled;
    kernel_exe.want_lto = false;
    kernel_exe.pie = true; // allow kaslr
    kernel_exe.linkage = .static;

    // TODO: is there a better way to do this?
    kernel_exe.setLinkerScript(b.path(
        b.pathJoin(&.{
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

    return .{
        .install_kernel_binaries = install_both_kernel_binaries,
        .final_kernel_binary_path = fat_kernel_with_sdf,
    };
}

fn constructKernelModule(
    b: *std.Build,
    all_libraries: Library.Collection,
    options: Options,
    architecture: CascadeTarget.Architecture,
    is_check: bool,
) !*std.Build.Module {
    const required_components = try getAllRequiredComponents(b);
    const required_libraries = try getAllRequiredLibraries(b, all_libraries, required_components);

    try configureComponents(
        b,
        architecture,
        required_components,
        required_libraries,
        options,
        is_check,
    );

    const kernel_module = required_components.get("cascade").?.module;

    kernel_module.resolved_target = kernelCrossTarget(architecture, b);
    kernel_module.optimize = options.optimize;
    kernel_module.sanitize_c = switch (options.optimize) {
        .ReleaseFast => .off,
        .ReleaseSmall => .trap,
        else => .full,
    };

    // stop dwarf info from being stripped, we need it to generate the SDF data, it is split into a seperate file anyways
    kernel_module.strip = false;
    kernel_module.omit_frame_pointer = false;

    // apply architecture-specific configuration to the kernel
    switch (architecture) {
        .arm => {},
        .riscv => {},
        .x64 => {
            kernel_module.code_model = .kernel;
            kernel_module.red_zone = false;
        },
    }

    const source_file_modules = try getSourceFileModules(
        b,
        required_components,
        required_libraries,
    );
    for (source_file_modules) |module| {
        kernel_module.addImport(module.name, module.module);
    }

    return kernel_module;
}

/// Returns the kernel components required to build the kernel.
///
/// The modules for each component are created but not configured in any way.
fn getAllRequiredComponents(
    b: *std.Build,
) !WipComponent.Collection {
    var todo_components: std.StringArrayHashMapUnmanaged(void) = .empty;
    try todo_components.putNoClobber(b.allocator, "cascade", {});

    var required_components: WipComponent.Collection = .{};

    while (todo_components.pop()) |entry| {
        const component_name = entry.key;
        if (required_components.contains(component_name)) continue;

        const component = kernel_components.get(component_name) orelse {
            std.debug.panic(
                "kernel dependency graph contains non-existant kernel component '{s}'",
                .{component_name},
            );
        };

        for (component.component_dependencies) |dep| {
            try todo_components.put(b.allocator, dep, {});
        }

        try required_components.putNoClobber(b.allocator, component_name, .{
            .kernel_component = component,
            .directory_path = b.pathJoin(&.{
                "kernel",
                component.name,
            }),
            .module = b.createModule(.{}),
        });
    }

    return required_components;
}

const WipComponent = struct {
    kernel_component: *const KernelComponent,
    directory_path: []const u8,
    module: *std.Build.Module,
    const Collection = std.StringArrayHashMapUnmanaged(WipComponent);
};

/// Returns the libraries required to build the kernel for the given architecture.
fn getAllRequiredLibraries(
    b: *std.Build,
    all_libraries: Library.Collection,
    components: WipComponent.Collection,
) !Library.Collection {
    var required_libraries: Library.Collection = .{};

    for (components.values()) |component| {
        for (component.kernel_component.library_dependencies) |dep| {
            if (required_libraries.contains(dep)) continue;

            const library = all_libraries.get(dep) orelse {
                std.debug.panic(
                    "kernel component '{s}' depends on non-existant library '{s}'",
                    .{ component.kernel_component.name, dep },
                );
            };

            try required_libraries.putNoClobber(b.allocator, dep, library);
        }
    }

    return required_libraries;
}

/// Configure each component in the given collection.
fn configureComponents(
    b: *std.Build,
    architecture: CascadeTarget.Architecture,
    components: WipComponent.Collection,
    libraries: Library.Collection,
    options: Options,
    is_check: bool,
) !void {
    for (components.values()) |c| {
        const kernel_component = c.kernel_component;
        const module = c.module;

        // root source file
        module.root_source_file = blk: {
            const root_file_name = try std.fmt.allocPrint(
                b.allocator,
                "{s}.zig",
                .{kernel_component.name},
            );

            break :blk b.path(b.pathJoin(&.{
                c.directory_path,
                root_file_name,
            }));
        };

        // library dependencies
        for (kernel_component.library_dependencies) |dep| {
            const library = libraries.get(dep) orelse {
                std.debug.panic(
                    "kernel component '{s}' depends on non-existant library '{s}'",
                    .{ kernel_component.name, dep },
                );
            };

            module.addImport(
                dep,
                library.cascade_modules.get(architecture) orelse unreachable,
            );
        }

        // component dependencies
        for (kernel_component.component_dependencies) |dep| {
            const component = components.get(dep) orelse {
                std.debug.panic(
                    "kernel component '{s}' depends on non-existant kernel component '{s}'",
                    .{ kernel_component.name, dep },
                );
            };

            module.addImport(dep, component.module);
        }

        // self reference
        module.addImport(kernel_component.name, module);

        // custom configuration
        if (kernel_component.configuration) |configuration| {
            try configuration(
                b,
                architecture,
                module,
                options,
                is_check,
            );
        }
    }
}

/// Build the data for a source file map.
///
/// Returns a `std.Build.Module` per source file with the name of the file as the module import name,
/// with a `embedded_source_files` module containing an array of the file names.
///
/// This allows combining `ComptimeStringHashMap` and `@embedFile(file_name)`, providing access to the contents of
/// source files by file path key, which is exactly what is needed for printing source code in stacktraces.
fn getSourceFileModules(
    b: *std.Build,
    required_components: WipComponent.Collection,
    required_libraries: Library.Collection,
) ![]const SourceFileModule {
    var modules = std.array_list.Managed(SourceFileModule).init(b.allocator);
    errdefer modules.deinit();

    var file_paths = std.array_list.Managed([]const u8).init(b.allocator);
    defer file_paths.deinit();

    // add each component's files
    for (required_components.values()) |component| {
        try addFilesRecursive(
            b,
            &modules,
            &file_paths,
            component.directory_path,
        );
    }

    // add each libraries files
    var processed_libraries = std.AutoHashMap(*const Library, void).init(b.allocator);
    for (required_libraries.values()) |library| {
        try addFilesFromLibrary(b, &modules, &file_paths, library, &processed_libraries);
    }

    const files_option = b.addOptions();
    files_option.addOption([]const []const u8, "file_paths", file_paths.items);
    try modules.append(.{ .name = "embedded_source_files", .module = files_option.createModule() });

    return try modules.toOwnedSlice();
}

fn addFilesFromLibrary(
    b: *std.Build,
    modules: *std.array_list.Managed(SourceFileModule),
    file_paths: *std.array_list.Managed([]const u8),
    library: *const Library,
    processed_libraries: *std.AutoHashMap(*const Library, void),
) !void {
    if (processed_libraries.contains(library)) return;

    try addFilesRecursive(b, modules, file_paths, library.directory_path);

    try processed_libraries.put(library, {});

    for (library.dependencies) |dep| {
        try addFilesFromLibrary(b, modules, file_paths, dep, processed_libraries);
    }
}

/// Adds all files recursively in the given target path to the build.
///
/// Creates a `SourceFileModule` for each `.zig` file found, and adds the file path to the `files` array.
fn addFilesRecursive(
    b: *std.Build,
    modules: *std.array_list.Managed(SourceFileModule),
    files: *std.array_list.Managed([]const u8),
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
                try addFilesRecursive(b, modules, files, path);
            },
            else => {},
        }
    }
}

/// Module created from a source file.
const SourceFileModule = struct {
    /// The file name and also the name of the module.
    name: []const u8,
    module: *std.Build.Module,
};

/// Returns a CrossTarget for building the kernel for the given architecture.
pub fn kernelCrossTarget(architecture: CascadeTarget.Architecture, b: *std.Build) std.Build.ResolvedTarget {
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

const kernel_components: std.StaticStringMap(*const KernelComponent) = .initComptime(blk: {
    const component_listing = @import("../kernel/listing.zig").components;

    var components: [component_listing.len]struct { []const u8, *const KernelComponent } = undefined;

    for (component_listing, 0..) |component, i| {
        components[i] = .{ component.name, &component };
    }

    break :blk components;
});

const std = @import("std");
const Step = std.Build.Step;

const CascadeTarget = @import("CascadeTarget.zig").CascadeTarget;
const KernelComponent = @import("KernelComponent.zig");
const Library = @import("Library.zig");
const Options = @import("Options.zig");
const Tool = @import("Tool.zig");
const StepCollection = @import("StepCollection.zig");
