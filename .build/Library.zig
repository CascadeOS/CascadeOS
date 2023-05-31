// SPDX-License-Identifier: MIT

const std = @import("std");
const Step = std.Build.Step;

const helpers = @import("helpers.zig");

const LibraryDescription = @import("LibraryDescription.zig");
const StepCollection = @import("StepCollection.zig");

const Library = @This();

pub const Collection = std.StringArrayHashMapUnmanaged(*Library);

name: []const u8,
root_file: std.Build.FileSource,
dependencies: []const *Library,
module: *std.Build.Module,

pub fn getRootFilePath(library: *const Library, b: *std.Build) []const u8 {
    return library.root_file.getPath(b);
}

pub fn getLibraries(b: *std.Build, step_collection: StepCollection, optimize: std.builtin.OptimizeMode) !Collection {
    const library_list: []const LibraryDescription = @import("../libraries/listing.zig").libraries;

    var libraries: Collection = .{};
    try libraries.ensureTotalCapacity(b.allocator, library_list.len);

    // The library descriptions still left to resolve
    var libraries_todo = try std.ArrayListUnmanaged(LibraryDescription).initCapacity(b.allocator, library_list.len);

    // Fill the todo list with all the libraries
    libraries_todo.appendSliceAssumeCapacity(library_list);

    while (libraries_todo.items.len != 0) {
        var resolved_any_this_loop = false;

        var i: usize = 0;
        while (i < libraries_todo.items.len) {
            const description: LibraryDescription = libraries_todo.items[i];

            if (try resolveLibrary(b, description, libraries, step_collection, optimize)) |library| {
                libraries.putAssumeCapacityNoClobber(description.name, library);

                resolved_any_this_loop = true;
                _ = libraries_todo.swapRemove(i);
            } else {
                i += 1;
            }
        }

        if (!resolved_any_this_loop) {
            @panic("STUCK IN A LOOP"); // TODO: Report this better
        }
    }

    return libraries;
}

fn resolveLibrary(
    b: *std.Build,
    description: LibraryDescription,
    libraries: Collection,
    step_collection: StepCollection,
    optimize: std.builtin.OptimizeMode,
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

    const module = blk: {
        const module = b.createModule(.{
            .source_file = file_source,
        });

        try module.dependencies.put(description.name, module);

        for (library_dependencies) |library| {
            try module.dependencies.put(library.name, library.module);
        }

        break :blk module;
    };

    if (description.supported_architectures) |supported_architectures| {
        for (supported_architectures) |arch| {
            const test_exe = b.addTest(.{
                .name = description.name,
                .root_source_file = file_source,
                .optimize = optimize,
                .target = arch.getTestCrossTarget(),
            });

            for (library_dependencies) |library| {
                test_exe.addModule(library.name, library.module);
            }

            const run_test_exe = b.addRunArtifact(test_exe);
            run_test_exe.skip_foreign_checks = true;

            const run_step_name = try std.fmt.allocPrint(
                b.allocator,
                "test_{s}_{s}",
                .{ description.name, @tagName(arch) },
            );
            const run_step_description = try std.fmt.allocPrint(
                b.allocator,
                "Run the tests for {s}_{s}",
                .{ description.name, @tagName(arch) },
            );

            const run_step = b.step(run_step_name, run_step_description);
            run_step.dependOn(&run_test_exe.step);

            step_collection.libraries_test_step.dependOn(run_step);
        }
    } else {
        // Don't provide a target so that the tests are built for the host
        const test_exe = b.addTest(.{
            .name = description.name,
            .root_source_file = file_source,
            .optimize = optimize,
        });

        for (library_dependencies) |library| {
            test_exe.addModule(library.name, library.module);
        }

        const run_test_exe = b.addRunArtifact(test_exe);

        const run_step_name = try std.fmt.allocPrint(
            b.allocator,
            "test_{s}",
            .{description.name},
        );
        const run_step_description = try std.fmt.allocPrint(
            b.allocator,
            "Run the tests for {s}",
            .{description.name},
        );

        const run_step = b.step(run_step_name, run_step_description);
        run_step.dependOn(&run_test_exe.step);

        step_collection.libraries_test_step.dependOn(run_step);
    }

    var library = try b.allocator.create(Library);

    library.* = .{
        .name = description.name,
        .root_file = file_source,
        .module = module,
        .dependencies = library_dependencies,
    };

    return library;
}
