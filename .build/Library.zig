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

/// The source file for the root file of the library.
root_file: std.Build.FileSource,

/// The list of library dependencies.
dependencies: []const *Library,

/// The modules for each supported Cascade target.
cascade_modules: std.AutoHashMapUnmanaged(CascadeTarget, *std.Build.Module),

/// The modules for each supported non-Cascade target.
non_cascade_modules: std.AutoHashMapUnmanaged(CascadeTarget, *std.Build.Module),

/// Returns the path to the root source file of the library.
pub fn getRootFilePath(library: *const Library, b: *std.Build) []const u8 {
    return library.root_file.getPath(b);
}

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
            @panic("STUCK IN A LOOP"); // TODO: Report this better https://github.com/CascadeOS/CascadeOS/issues/9
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

    const root_file_name = try std.fmt.allocPrint(b.allocator, "{s}.zig", .{library_description.name});

    const root_file_path = helpers.pathJoinFromRoot(b, &.{
        "libraries",
        library_description.name,
        root_file_name,
    });

    const file_source: std.Build.FileSource = .{ .path = root_file_path };

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

    for (supported_targets) |target| {
        try cascadeTestExecutableAndModule(
            b,
            library_description,
            file_source,
            options,
            target,
            dependencies,
            all_build_and_run_step,
            step_collection,
            &cascade_modules,
        );

        // host test executable and module
        if (!library_description.is_cascade_only) {
            try hostTestExecutableAndModule(
                b,
                library_description,
                file_source,
                options,
                target,
                dependencies,
                all_build_and_run_step,
                step_collection,
                &non_cascade_modules,
            );
        }
    }

    var library = try b.allocator.create(Library);

    library.* = .{
        .name = library_description.name,
        .root_file = file_source,
        .cascade_modules = cascade_modules,
        .non_cascade_modules = non_cascade_modules,
        .dependencies = dependencies,
    };

    return library;
}

/// Creates a test executable and module for `library_description` targeting `target` for cascade.
fn cascadeTestExecutableAndModule(
    b: *std.Build,
    library_description: LibraryDescription,
    file_source: std.Build.FileSource,
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
        file_source,
        options,
        target,
        dependencies,
        true,
    );

    test_exe.override_dest_dir = .{
        .custom = b.pathJoin(&.{
            @tagName(target),
            "root",
            "tests",
        }),
    };

    const install_step = b.addInstallArtifact(test_exe);

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

    const module = try createModule(b, file_source, options, target, dependencies, true);
    try cascade_modules.putNoClobber(b.allocator, target, module);
}

/// Creates a test executable and module for `library_description` targeting the host system.
fn hostTestExecutableAndModule(
    b: *std.Build,
    library_description: LibraryDescription,
    file_source: std.Build.FileSource,
    options: Options,
    target: CascadeTarget,
    dependencies: []*Library,
    all_build_and_run_step: *std.Build.Step,
    step_collection: StepCollection,
    non_cascade_modules: *std.AutoHashMapUnmanaged(CascadeTarget, *std.Build.Module),
) !void {
    const test_exe = try createTestExe(
        b,
        library_description,
        file_source,
        options,
        target,
        dependencies,
        false,
    );

    test_exe.override_dest_dir = .{
        .custom = b.pathJoin(&.{
            @tagName(target),
            "non_cascade",
            "tests",
        }),
    };

    const install_step = b.addInstallArtifact(test_exe);

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
    step_collection.registerNonCascadeLibrary(target, &install_step.step, build_step);

    const module = try createModule(b, file_source, options, target, dependencies, false);
    try non_cascade_modules.putNoClobber(b.allocator, target, module);
}

/// Creates a test executable for a library.
fn createTestExe(
    b: *std.Build,
    library_description: LibraryDescription,
    file_source: std.Build.FileSource,
    options: Options,
    target: CascadeTarget,
    dependencies: []const *Library,
    build_for_cascade: bool,
) !*Step.Compile {
    const test_exe = b.addTest(.{
        .name = library_description.name,
        .root_source_file = file_source,
        .optimize = options.optimize,
        .target = if (build_for_cascade) target.getCascadeTestCrossTarget() else target.getNonCascadeTestCrossTarget(),
    });

    // TODO: self-referential module https://github.com/CascadeOS/CascadeOS/issues/10
    // test_exe.addModule(library_description.name, module);

    if (build_for_cascade) {
        test_exe.addModule("cascade_flag", options.cascade_os_options_module);
    } else {
        test_exe.addModule("cascade_flag", options.non_cascade_os_options_module);
    }

    for (dependencies) |dependency| {
        const dependency_module = if (build_for_cascade)
            dependency.cascade_modules.get(target) orelse continue
        else
            dependency.non_cascade_modules.get(target) orelse continue;

        test_exe.addModule(dependency.name, dependency_module);
    }

    return test_exe;
}

/// Creates a module for a library.
fn createModule(
    b: *std.Build,
    file_source: std.Build.FileSource,
    options: Options,
    target: CascadeTarget,
    dependencies: []const *Library,
    build_for_cascade: bool,
) !*std.Build.Module {
    const module = b.createModule(.{
        .source_file = file_source,
    });

    // TODO: self-referential module https://github.com/CascadeOS/CascadeOS/issues/10
    // try module.dependencies.put(library_description.name, module);

    if (build_for_cascade) {
        try module.dependencies.put("cascade_flag", options.cascade_os_options_module);
    } else {
        try module.dependencies.put("cascade_flag", options.non_cascade_os_options_module);
    }

    for (dependencies) |dependency| {
        const dependency_module = if (build_for_cascade)
            dependency.cascade_modules.get(target) orelse continue
        else
            dependency.non_cascade_modules.get(target) orelse continue;

        try module.dependencies.put(dependency.name, dependency_module);
    }

    return module;
}
