// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub const Collection = std.StringArrayHashMapUnmanaged(*Library);

const Library = @This();

/// The name of the library.
///
/// Used as:
///   - The name of the module provided by `@import("{name}");` (unless overridden with `LibraryDependency.import_name`)
///   - To build the root file path `lib/{name}/{name}.zig`
///   - In any build steps created for the library
name: []const u8,

/// The path to the directory containing this library.
directory_path: []const u8,

/// The list of dependencies.
dependencies: []const Dependency,

/// The modules for each supported Cascade architecture.
cascade_modules: Modules,

/// The modules for each supported non-Cascade architecture.
non_cascade_modules: Modules,

/// If this library supports the hosts architecture the native module from `non_cascade_modules` will be stored here.
non_cascade_module_for_host: ?*std.Build.Module,

pub const Dependency = struct {
    import_name: []const u8,
    library: *Library,
};

/// Resolves all libraries and their dependencies.
///
/// Resolves each library in `lib/listing.zig` and all of their dependencies.
///
/// Libraries are resolved recursively until all dependencies have been resolved.
///
/// Panics if a loop is detected in the dependency graph.
pub fn getLibraries(
    b: *std.Build,
    step_collection: StepCollection,
    options: Options,
    all_architectures: []const CascadeTarget.Architecture,
) !Collection {
    const all_library_descriptions: []const LibraryDescription = @import("../lib/listing.zig").libraries;

    var resolved_libraries: Collection = .{};
    try resolved_libraries.ensureTotalCapacity(b.allocator, all_library_descriptions.len);

    // The library descriptions still left to resolve
    var unresolved_library_descriptions = try std.ArrayListUnmanaged(LibraryDescription).initCapacity(b.allocator, all_library_descriptions.len);

    // Fill the unresolved list with all the libraries
    unresolved_library_descriptions.appendSliceAssumeCapacity(all_library_descriptions);

    while (unresolved_library_descriptions.items.len != 0) {
        var resolved_any_this_iteration = false;

        var i: usize = 0;
        while (i < unresolved_library_descriptions.items.len) {
            const library_description: LibraryDescription = unresolved_library_descriptions.items[i];

            if (try resolveLibrary(
                b,
                library_description,
                resolved_libraries,
                step_collection,
                options,
                all_architectures,
                all_library_descriptions,
            )) |library| {
                resolved_libraries.putAssumeCapacityNoClobber(library_description.name, library);

                resolved_any_this_iteration = true;
                _ = unresolved_library_descriptions.orderedRemove(i);
            } else {
                i += 1;
            }
        }

        if (!resolved_any_this_iteration) {
            @panic("STUCK IN A LOOP");
        }
    }

    return resolved_libraries;
}

/// Resolves a library if its dependencies have been resolved.
fn resolveLibrary(
    b: *std.Build,
    library_description: LibraryDescription,
    resolved_libraries: Collection,
    step_collection: StepCollection,
    options: Options,
    all_architectures: []const CascadeTarget.Architecture,
    all_library_descriptions: []const LibraryDescription,
) !?*Library {
    const dependencies = blk: {
        var dependencies = try std.ArrayList(Dependency).initCapacity(b.allocator, library_description.dependencies.len);
        defer dependencies.deinit();

        for (library_description.dependencies) |dep| {
            if (resolved_libraries.get(dep.name)) |dep_library| {
                dependencies.appendAssumeCapacity(.{
                    .import_name = dep.import_name orelse dep.name,
                    .library = dep_library,
                });
            } else {
                // check if the dependency is a library that actually exists
                for (all_library_descriptions) |desc| {
                    if (std.mem.eql(u8, dep.name, desc.name)) break;
                } else {
                    std.debug.panic(
                        "library '{s}' depends on non-existant library '{s}'",
                        .{ library_description.name, dep.name },
                    );
                }

                return null;
            }
        }

        break :blk try dependencies.toOwnedSlice();
    };

    const directory_path = b.pathJoin(&.{
        "lib",
        library_description.name,
    });

    const root_file_name = library_description.root_file_name orelse
        try std.fmt.allocPrint(b.allocator, "{s}.zig", .{library_description.name});

    const lazy_path = b.path(b.pathJoin(&.{
        directory_path,
        root_file_name,
    }));

    const supported_architectures = library_description.supported_architectures orelse all_architectures;

    var cascade_modules: Modules = .{};
    errdefer cascade_modules.deinit(b.allocator);

    var non_cascade_modules: Modules = .{};
    errdefer non_cascade_modules.deinit(b.allocator);

    const all_build_and_run_step_name = try std.fmt.allocPrint(
        b.allocator,
        "{s}",
        .{library_description.name},
    );
    const all_build_and_run_step_description = if (library_description.is_cascade_only)
        try std.fmt.allocPrint(
            b.allocator,
            "Build the tests for {s} for every supported architecture",
            .{library_description.name},
        )
    else
        try std.fmt.allocPrint(
            b.allocator,
            "Build the tests for {s} for every supported architecture and attempt to run non-cascade test binaries",
            .{library_description.name},
        );

    const all_build_and_run_step = b.step(all_build_and_run_step_name, all_build_and_run_step_description);

    var host_native_module: ?*std.Build.Module = null;

    for (supported_architectures) |architecture| {
        {
            const cascade_module = try createModule(
                b,
                library_description,
                lazy_path,
                options,
                .{
                    .architecture = architecture,
                    .context = .cascade,
                },
                .dependency,
                dependencies,
            );
            try cascade_modules.putNoClobber(b.allocator, architecture, cascade_module);
        }

        // host check exe
        {
            const check_module = try createModule(
                b,
                library_description,
                lazy_path,
                options,
                .{
                    .architecture = architecture,
                    .context = .non_cascade,
                },
                .exe_root,
                dependencies,
            );
            const check_test_exe = b.addTest(.{
                .name = try std.mem.concat(b.allocator, u8, &.{ library_description.name, "_check" }),
                .root_module = check_module,
            });
            step_collection.registerCheck(check_test_exe);
        }

        {
            const host_module = try createModule(
                b,
                library_description,
                lazy_path,
                options,
                .{
                    .architecture = architecture,
                    .context = .non_cascade,
                },
                .dependency,
                dependencies,
            );
            try non_cascade_modules.putNoClobber(b.allocator, architecture, host_module);

            if (architecture.isNative(b)) host_native_module = host_module;
        }

        {
            const host_test_module = try createModule(
                b,
                library_description,
                lazy_path,
                options,
                .{
                    .architecture = architecture,
                    .context = .non_cascade,
                },
                .exe_root,
                dependencies,
            );
            host_test_module.optimize = options.optimize;

            const host_test_exe = b.addTest(.{
                .name = library_description.name,
                .root_module = host_test_module,
            });

            if (library_description.need_llvm) {
                host_test_exe.use_llvm = true;
            }

            const host_test_install_step = b.addInstallArtifact(
                host_test_exe,
                .{
                    .dest_dir = .{
                        .override = .{
                            .custom = b.pathJoin(&.{
                                @tagName(architecture),
                                "tests",
                                "non_cascade",
                            }),
                        },
                    },
                },
            );

            const host_test_run_step = b.addRunArtifact(host_test_exe);
            host_test_run_step.skip_foreign_checks = true;
            host_test_run_step.failing_to_execute_foreign_is_an_error = false;

            host_test_run_step.step.dependOn(&host_test_install_step.step); // ensure the test exe is installed

            const host_test_step_name = try std.fmt.allocPrint(
                b.allocator,
                "{s}_host_{t}",
                .{ library_description.name, architecture },
            );

            const host_test_step_description =
                try std.fmt.allocPrint(
                    b.allocator,
                    "Build and attempt to run the tests for {s} on {t} targeting the host os",
                    .{ library_description.name, architecture },
                );

            const host_test_step = b.step(host_test_step_name, host_test_step_description);
            host_test_step.dependOn(&host_test_run_step.step);

            all_build_and_run_step.dependOn(host_test_step);
            step_collection.registerNonCascadeLibrary(architecture, host_test_step);
        }
    }

    const library = try b.allocator.create(Library);

    library.* = .{
        .name = library_description.name,
        .directory_path = directory_path,
        .cascade_modules = cascade_modules,
        .non_cascade_modules = non_cascade_modules,
        .dependencies = dependencies,
        .non_cascade_module_for_host = host_native_module,
    };

    return library;
}

/// Creates a module for a library.
fn createModule(
    b: *std.Build,
    library_description: LibraryDescription,
    lazy_path: std.Build.LazyPath,
    options: Options,
    cascade_target: CascadeTarget,
    purpose: enum { exe_root, dependency },
    dependencies: []const Dependency,
) !*std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = lazy_path,
        .sanitize_c = switch (options.optimize) {
            .ReleaseFast => .off,
            .ReleaseSmall => .trap,
            else => .full,
        },
    });

    if (purpose == .exe_root) {
        module.resolved_target = cascade_target.getCrossTarget(b);
    }

    // self reference
    module.addImport(library_description.name, module);

    switch (cascade_target.context) {
        .cascade => module.addImport("cascade_flag", options.cascade_detect_option_module),
        .non_cascade => module.addImport("cascade_flag", options.non_cascade_detect_option_module),
    }

    for (dependencies) |dependency| {
        const dependency_module = switch (cascade_target.context) {
            .cascade => dependency.library.cascade_modules.get(cascade_target.architecture) orelse unreachable,
            .non_cascade => dependency.library.non_cascade_modules.get(cascade_target.architecture) orelse unreachable,
        };

        module.addImport(dependency.import_name, dependency_module);
    }

    return module;
}

const std = @import("std");
const Step = std.Build.Step;

const CascadeTarget = @import("CascadeTarget.zig").CascadeTarget;
const LibraryDescription = @import("LibraryDescription.zig");
const Options = @import("Options.zig");
const StepCollection = @import("StepCollection.zig");
const Modules = std.AutoHashMapUnmanaged(CascadeTarget.Architecture, *std.Build.Module);
