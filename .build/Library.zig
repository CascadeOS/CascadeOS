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

name: []const u8,
root_file: std.Build.FileSource,
dependencies: []const *Library,
cascade_modules: std.AutoHashMapUnmanaged(CascadeTarget, *std.Build.Module),
non_cascade_modules: std.AutoHashMapUnmanaged(CascadeTarget, *std.Build.Module),

pub fn getRootFilePath(library: *const Library, b: *std.Build) []const u8 {
    return library.root_file.getPath(b);
}

pub fn getLibraries(
    b: *std.Build,
    step_collection: StepCollection,
    options: Options,
    all_targets: []const CascadeTarget,
) !Collection {
    const library_list: []const LibraryDescription = @import("../libraries/listing.zig").libraries;

    var libraries: Collection = .{};
    try libraries.ensureTotalCapacity(b.allocator, library_list.len);

    // The library descriptions still left to resolve
    var unresolved_libraries = try std.ArrayListUnmanaged(LibraryDescription).initCapacity(b.allocator, library_list.len);

    // Fill the unresolved list with all the libraries
    unresolved_libraries.appendSliceAssumeCapacity(library_list);

    while (unresolved_libraries.items.len != 0) {
        var resolved_any_this_loop = false;

        var i: usize = 0;
        while (i < unresolved_libraries.items.len) {
            const description: LibraryDescription = unresolved_libraries.items[i];

            if (try resolveLibrary(b, description, libraries, step_collection, options, all_targets)) |library| {
                libraries.putAssumeCapacityNoClobber(description.name, library);

                resolved_any_this_loop = true;
                _ = unresolved_libraries.swapRemove(i);
            } else {
                i += 1;
            }
        }

        if (!resolved_any_this_loop) {
            @panic("STUCK IN A LOOP"); // TODO: Report this better https://github.com/CascadeOS/CascadeOS/issues/9
        }
    }

    return libraries;
}

fn resolveLibrary(
    b: *std.Build,
    description: LibraryDescription,
    libraries: Collection,
    step_collection: StepCollection,
    options: Options,
    all_targets: []const CascadeTarget,
) !?*Library {
    const library_dependencies = blk: {
        var library_dependencies = try std.ArrayList(*Library).initCapacity(b.allocator, description.dependencies.len);
        defer library_dependencies.deinit();

        for (description.dependencies) |dep| {
            if (libraries.get(dep)) |dep_library| {
                library_dependencies.appendAssumeCapacity(dep_library);
            } else {
                return null;
            }
        }

        break :blk try library_dependencies.toOwnedSlice();
    };

    const root_file = try std.fmt.allocPrint(b.allocator, "{s}.zig", .{description.name});

    const root_path = helpers.pathJoinFromRoot(b, &.{
        "libraries",
        description.name,
        root_file,
    });

    const file_source: std.Build.FileSource = .{ .path = root_path };

    const supported_targets = if (description.supported_targets) |supported_targets| supported_targets else all_targets;

    var cascade_modules: std.AutoHashMapUnmanaged(CascadeTarget, *std.Build.Module) = .{};
    errdefer cascade_modules.deinit(b.allocator);

    var non_cascade_modules: std.AutoHashMapUnmanaged(CascadeTarget, *std.Build.Module) = .{};
    errdefer non_cascade_modules.deinit(b.allocator);

    const all_build_and_run_step_name = try std.fmt.allocPrint(
        b.allocator,
        "{s}",
        .{description.name},
    );
    const all_build_and_run_step_description = if (description.cascade_only)
        try std.fmt.allocPrint(
            b.allocator,
            "Build the tests for {s} for every supported target",
            .{description.name},
        )
    else
        try std.fmt.allocPrint(
            b.allocator,
            "Build the tests for {s} for every supported target and attempt to run non-cascade test binaries",
            .{description.name},
        );

    const all_build_and_run_step = b.step(all_build_and_run_step_name, all_build_and_run_step_description);

    for (supported_targets) |target| {
        { // cascade test executable and module
            const cascade_test_exe = try createTestExe(
                b,
                description,
                file_source,
                options,
                target,
                library_dependencies,
                true,
            );

            cascade_test_exe.override_dest_dir = .{
                .custom = b.pathJoin(&.{
                    @tagName(target),
                    "root",
                    "tests",
                }),
            };

            const cascade_install_step = b.addInstallArtifact(cascade_test_exe);

            const cascade_step_name = try std.fmt.allocPrint(
                b.allocator,
                "{s}_cascade_{s}",
                .{ description.name, @tagName(target) },
            );

            const cascade_step_description = try std.fmt.allocPrint(
                b.allocator,
                "Build the tests for {s} on {s} targeting cascade",
                .{ description.name, @tagName(target) },
            );

            const cascade_step = b.step(cascade_step_name, cascade_step_description);
            cascade_step.dependOn(&cascade_install_step.step);

            all_build_and_run_step.dependOn(cascade_step);
            step_collection.registerCascadeLibrary(target, cascade_step);

            const cascade_module = try createModule(b, file_source, options, target, library_dependencies, true);
            try cascade_modules.putNoClobber(b.allocator, target, cascade_module);
        }

        if (!description.cascade_only) { // NON-cascade test executable and module
            const non_cascade_test_exe = try createTestExe(
                b,
                description,
                file_source,
                options,
                target,
                library_dependencies,
                false,
            );

            non_cascade_test_exe.override_dest_dir = .{
                .custom = b.pathJoin(&.{
                    @tagName(target),
                    "non_cascade",
                    "tests",
                }),
            };

            const non_cascade_install_step = b.addInstallArtifact(non_cascade_test_exe);

            const non_cascade_run = b.addRunArtifact(non_cascade_test_exe);
            non_cascade_run.skip_foreign_checks = true;
            // TODO: Use https://github.com/ziglang/zig/pull/15852 once master tarballs are updated

            non_cascade_run.step.dependOn(&non_cascade_install_step.step);

            const non_cascade_step_name = try std.fmt.allocPrint(
                b.allocator,
                "{s}_host_{s}",
                .{ description.name, @tagName(target) },
            );

            const non_cascade_step_description =
                try std.fmt.allocPrint(
                b.allocator,
                "Build and attempt to run the tests for {s} on {s} targeting the host os",
                .{ description.name, @tagName(target) },
            );

            const non_cascade_step = b.step(non_cascade_step_name, non_cascade_step_description);
            non_cascade_step.dependOn(&non_cascade_run.step);

            all_build_and_run_step.dependOn(non_cascade_step);
            step_collection.registerNonCascadeLibrary(target, &non_cascade_install_step.step, non_cascade_step);

            const non_cascade_module = try createModule(b, file_source, options, target, library_dependencies, false);
            try non_cascade_modules.putNoClobber(b.allocator, target, non_cascade_module);
        }
    }

    var library = try b.allocator.create(Library);

    library.* = .{
        .name = description.name,
        .root_file = file_source,
        .cascade_modules = cascade_modules,
        .non_cascade_modules = non_cascade_modules,
        .dependencies = library_dependencies,
    };

    return library;
}

fn createTestExe(
    b: *std.Build,
    description: LibraryDescription,
    file_source: std.Build.FileSource,
    options: Options,
    target: CascadeTarget,
    library_dependencies: []const *Library,
    build_for_cascade: bool,
) !*Step.Compile {
    const cascade_test_exe = b.addTest(.{
        .name = description.name,
        .root_source_file = file_source,
        .optimize = options.optimize,
        .target = if (build_for_cascade) target.getCascadeTestCrossTarget() else target.getNonCascadeTestCrossTarget(),
    });

    // TODO: self-referential module https://github.com/CascadeOS/CascadeOS/issues/10
    // test_exe.addModule(description.name, module);

    if (build_for_cascade) {
        cascade_test_exe.addModule("cascade_flag", options.cascade_option_module);
    } else {
        cascade_test_exe.addModule("cascade_flag", options.non_cascade_option_module);
    }

    for (library_dependencies) |library| {
        const library_module = if (build_for_cascade)
            library.cascade_modules.get(target) orelse continue
        else
            library.non_cascade_modules.get(target) orelse continue;

        cascade_test_exe.addModule(library.name, library_module);
    }

    return cascade_test_exe;
}

fn createModule(
    b: *std.Build,
    file_source: std.Build.FileSource,
    options: Options,
    target: CascadeTarget,
    library_dependencies: []const *Library,
    build_for_cascade: bool,
) !*std.Build.Module {
    const module = b.createModule(.{
        .source_file = file_source,
    });

    // TODO: self-referential module https://github.com/CascadeOS/CascadeOS/issues/10
    // try module.dependencies.put(description.name, module);

    if (build_for_cascade) {
        try module.dependencies.put("cascade_flag", options.cascade_option_module);
    } else {
        try module.dependencies.put("cascade_flag", options.non_cascade_option_module);
    }

    for (library_dependencies) |library| {
        const library_module = if (build_for_cascade)
            library.cascade_modules.get(target) orelse continue
        else
            library.non_cascade_modules.get(target) orelse continue;

        try module.dependencies.put(library.name, library_module);
    }

    return module;
}
