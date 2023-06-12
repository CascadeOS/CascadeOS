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
modules: std.AutoHashMapUnmanaged(CascadeTarget, *std.Build.Module),

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

    var modules: std.AutoHashMapUnmanaged(CascadeTarget, *std.Build.Module) = .{};
    errdefer modules.deinit(b.allocator);

    try modules.ensureTotalCapacity(b.allocator, @intCast(u32, supported_targets.len));

    for (supported_targets) |target| {
        const test_exe = b.addTest(.{
            .name = description.name,
            .root_source_file = file_source,
            .optimize = options.optimize,
            .target = target.getTestCrossTarget(),
        });

        test_exe.override_dest_dir = .{
            .custom = b.pathJoin(&.{
                @tagName(target),
                "root",
                "tests",
            }),
        };

        const install_step = b.addInstallArtifact(test_exe);
        step_collection.libraries_test_build_step_per_target.get(target).?.dependOn(&install_step.step);

        const module = b.createModule(.{
            .source_file = file_source,
        });

        // TODO: self-referential module https://github.com/CascadeOS/CascadeOS/issues/10
        // test_exe.addModule(description.name, module);
        // try module.dependencies.put(description.name, module);

        const target_option_module = options.target_option_modules.get(target).?;
        test_exe.addModule("cascade_target", target_option_module);
        try module.dependencies.put("cascade_target", target_option_module);

        for (library_dependencies) |library| {
            const library_module = library.modules.get(target) orelse continue;
            test_exe.addModule(library.name, library_module);
            try module.dependencies.put(library.name, library_module);
        }

        modules.putAssumeCapacityNoClobber(target, module);
    }

    var library = try b.allocator.create(Library);

    library.* = .{
        .name = description.name,
        .root_file = file_source,
        .modules = modules,
        .dependencies = library_dependencies,
    };

    return library;
}
