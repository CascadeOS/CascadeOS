// SPDX-License-Identifier: MIT

const std = @import("std");
const Step = std.Build.Step;

const helpers = @import("helpers.zig");

const CascadeTarget = @import("CascadeTarget.zig").CascadeTarget;
const LibraryDescription = @import("LibraryDescription.zig");
const Options = @import("Options.zig");
const StepCollection = @import("StepCollection.zig");

const Library = @This();

pub const Collection = std.StringArrayHashMapUnmanaged(*Library);

/// The name of the library.
///
/// Used as:
///   - The name of the module provided by `@import("{name}");`
///   - To build the root file path `libraries/{name}/{name}.zig`
///   - In any build steps created for the library
name: []const u8,

/// The path to the directory containing this library.
directory_path: []const u8,

/// The list of library dependencies.
dependencies: []const *Library,

/// The modules for each supported Cascade target.
cascade_modules: std.AutoHashMapUnmanaged(CascadeTarget, *std.Build.Module),

/// The modules for each supported non-Cascade target.
non_cascade_modules: std.AutoHashMapUnmanaged(CascadeTarget, *std.Build.Module),

/// If this library supports the hosts architecture the native module from `non_cascade_modules` will be stored here.
non_cascade_module_for_host: ?*std.Build.Module,

/// Resolves all libraries and their dependencies.
///
/// Resolves each library in `libraries/listing.zig` and all of their dependencies.
///
/// Libraries are resolved recursively until all dependencies have been resolved.
///
/// Panics if a loop is detected in the dependency graph.
pub fn getLibraries(
    b: *std.Build,
    step_collection: StepCollection,
    options: Options,
    targets: []const CascadeTarget,
) !Collection {
    const library_descriptions: []const LibraryDescription = @import("../libraries/listing.zig").libraries;

    var resolved_libraries: Collection = .{};
    try resolved_libraries.ensureTotalCapacity(b.allocator, library_descriptions.len);

    // The library descriptions still left to resolve
    var unresolved_library_descriptions = try std.ArrayListUnmanaged(LibraryDescription).initCapacity(b.allocator, library_descriptions.len);

    // Fill the unresolved list with all the libraries
    unresolved_library_descriptions.appendSliceAssumeCapacity(library_descriptions);

    while (unresolved_library_descriptions.items.len != 0) {
        var resolved_any_this_iteration = false;

        var i: usize = 0;
        while (i < unresolved_library_descriptions.items.len) {
            const library_description: LibraryDescription = unresolved_library_descriptions.items[i];

            if (try resolveLibrary(b, library_description, resolved_libraries, step_collection, options, targets)) |library| {
                resolved_libraries.putAssumeCapacityNoClobber(library_description.name, library);

                resolved_any_this_iteration = true;
                _ = unresolved_library_descriptions.swapRemove(i);
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
    targets: []const CascadeTarget,
) !?*Library {
    const dependencies = blk: {
        var dependencies = try std.ArrayList(*Library).initCapacity(b.allocator, library_description.dependencies.len);
        defer dependencies.deinit();

        for (library_description.dependencies) |dep| {
            if (resolved_libraries.get(dep)) |dep_library| {
                dependencies.appendAssumeCapacity(dep_library);
            } else {
                return null;
            }
        }

        break :blk try dependencies.toOwnedSlice();
    };

    const directory_path = helpers.pathJoinFromRoot(b, &.{
        "libraries",
        library_description.name,
    });

    const root_file_name = try std.fmt.allocPrint(b.allocator, "{s}.zig", .{library_description.name});

    const root_file_path = helpers.pathJoinFromRoot(b, &.{
        directory_path,
        root_file_name,
    });

    const lazy_path: std.Build.LazyPath = .{ .path = root_file_path };

    const supported_targets = library_description.supported_targets orelse targets;

    var cascade_modules: std.AutoHashMapUnmanaged(CascadeTarget, *std.Build.Module) = .{};
    errdefer cascade_modules.deinit(b.allocator);

    var non_cascade_modules: std.AutoHashMapUnmanaged(CascadeTarget, *std.Build.Module) = .{};
    errdefer non_cascade_modules.deinit(b.allocator);

    const all_build_and_run_step_name = try std.fmt.allocPrint(
        b.allocator,
        "{s}",
        .{library_description.name},
    );
    const all_build_and_run_step_description = if (library_description.is_cascade_only)
        try std.fmt.allocPrint(
            b.allocator,
            "Build the tests for {s} for every supported target",
            .{library_description.name},
        )
    else
        try std.fmt.allocPrint(
            b.allocator,
            "Build the tests for {s} for every supported target and attempt to run non-cascade test binaries",
            .{library_description.name},
        );

    const all_build_and_run_step = b.step(all_build_and_run_step_name, all_build_and_run_step_description);

    var host_native_module: ?*std.Build.Module = null;

    for (supported_targets) |target| {
        try cascadeTestExecutableAndModule(
            b,
            library_description,
            lazy_path,
            options,
            target,
            dependencies,
            all_build_and_run_step,
            step_collection,
            &cascade_modules,
        );

        // host test executable and module
        if (!library_description.is_cascade_only) {
            if (try hostTestExecutableAndModule(
                b,
                library_description,
                lazy_path,
                options,
                target,
                dependencies,
                all_build_and_run_step,
                step_collection,
                &non_cascade_modules,
            )) |module| host_native_module = module;
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

/// Creates a test executable and module for `library_description` targeting `target` for cascade.
fn cascadeTestExecutableAndModule(
    b: *std.Build,
    library_description: LibraryDescription,
    lazy_path: std.Build.LazyPath,
    options: Options,
    target: CascadeTarget,
    dependencies: []*Library,
    all_build_and_run_step: *std.Build.Step,
    step_collection: StepCollection,
    cascade_modules: *std.AutoHashMapUnmanaged(CascadeTarget, *std.Build.Module),
) !void {
    const test_exe = try createTestExe(
        b,
        library_description,
        lazy_path,
        options,
        target,
        dependencies,
        true,
    );

    const install_step = b.addInstallArtifact(
        test_exe,
        .{
            .dest_dir = .{
                .override = .{
                    .custom = b.pathJoin(&.{
                        @tagName(target),
                        "tests",
                        "cascade",
                    }),
                },
            },
        },
    );

    const build_step_name = try std.fmt.allocPrint(
        b.allocator,
        "{s}_cascade_{s}",
        .{ library_description.name, @tagName(target) },
    );

    const build_step_description = try std.fmt.allocPrint(
        b.allocator,
        "Build the tests for {s} on {s} targeting cascade",
        .{ library_description.name, @tagName(target) },
    );

    const build_step = b.step(build_step_name, build_step_description);
    build_step.dependOn(&install_step.step);

    all_build_and_run_step.dependOn(build_step);
    step_collection.registerCascadeLibrary(target, build_step);

    const module = try createModule(
        b,
        library_description,
        lazy_path,
        options,
        target,
        dependencies,
        true,
    );
    try cascade_modules.putNoClobber(b.allocator, target, module);
}

/// Creates a test executable and module for `library_description` targeting the host system.
fn hostTestExecutableAndModule(
    b: *std.Build,
    library_description: LibraryDescription,
    lazy_path: std.Build.LazyPath,
    options: Options,
    target: CascadeTarget,
    dependencies: []*Library,
    all_build_and_run_step: *std.Build.Step,
    step_collection: StepCollection,
    non_cascade_modules: *std.AutoHashMapUnmanaged(CascadeTarget, *std.Build.Module),
) !?*std.Build.Module {
    const test_exe = try createTestExe(
        b,
        library_description,
        lazy_path,
        options,
        target,
        dependencies,
        false,
    );

    const install_step = b.addInstallArtifact(
        test_exe,
        .{
            .dest_dir = .{
                .override = .{
                    .custom = b.pathJoin(&.{
                        @tagName(target),
                        "tests",
                        "non_cascade",
                    }),
                },
            },
        },
    );

    const run_step = b.addRunArtifact(test_exe);
    run_step.skip_foreign_checks = true;
    run_step.failing_to_execute_foreign_is_an_error = false;

    run_step.step.dependOn(&install_step.step);

    const build_step_name = try std.fmt.allocPrint(
        b.allocator,
        "{s}_host_{s}",
        .{ library_description.name, @tagName(target) },
    );

    const build_step_description =
        try std.fmt.allocPrint(
        b.allocator,
        "Build and attempt to run the tests for {s} on {s} targeting the host os",
        .{ library_description.name, @tagName(target) },
    );

    const build_step = b.step(build_step_name, build_step_description);
    build_step.dependOn(&run_step.step);

    all_build_and_run_step.dependOn(build_step);
    step_collection.registerNonCascadeLibrary(target, build_step);

    const module = try createModule(
        b,
        library_description,
        lazy_path,
        options,
        target,
        dependencies,
        false,
    );
    try non_cascade_modules.putNoClobber(b.allocator, target, module);

    if (target.isNative(b)) return module;
    return null;
}

/// Creates a test executable for a library.
fn createTestExe(
    b: *std.Build,
    library_description: LibraryDescription,
    lazy_path: std.Build.LazyPath,
    options: Options,
    target: CascadeTarget,
    dependencies: []const *Library,
    build_for_cascade: bool,
) !*Step.Compile {
    const test_exe = b.addTest(.{
        .name = library_description.name,
        .root_source_file = lazy_path,
        .optimize = options.optimize,
        .target = if (build_for_cascade) target.getCascadeTestCrossTarget(b) else target.getNonCascadeTestCrossTarget(b),
    });

    addDependenciesToModule(
        &test_exe.root_module,
        library_description,
        options,
        target,
        dependencies,
        build_for_cascade,
    );

    return test_exe;
}

/// Creates a module for a library.
fn createModule(
    b: *std.Build,
    library_description: LibraryDescription,
    lazy_path: std.Build.LazyPath,
    options: Options,
    target: CascadeTarget,
    dependencies: []const *Library,
    build_for_cascade: bool,
) !*std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = lazy_path,
    });

    addDependenciesToModule(
        module,
        library_description,
        options,
        target,
        dependencies,
        build_for_cascade,
    );

    return module;
}

fn addDependenciesToModule(
    module: *std.Build.Module,
    library_description: LibraryDescription,
    options: Options,
    target: CascadeTarget,
    dependencies: []const *Library,
    build_for_cascade: bool,
) void {
    // self reference
    module.addImport(library_description.name, module);

    if (build_for_cascade) {
        module.addImport("cascade_flag", options.cascade_os_options_module);
    } else {
        module.addImport("cascade_flag", options.non_cascade_os_options_module);
    }

    for (dependencies) |dependency| {
        const dependency_module = if (build_for_cascade)
            dependency.cascade_modules.get(target) orelse continue
        else
            dependency.non_cascade_modules.get(target) orelse continue;

        module.addImport(dependency.name, dependency_module);
    }
}
