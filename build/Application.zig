// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const Step = std.Build.Step;

const helpers = @import("helpers.zig");

const CascadeTarget = @import("CascadeTarget.zig").CascadeTarget;

const Library = @import("Library.zig");
const StepCollection = @import("StepCollection.zig");
const ApplicationDescription = @import("ApplicationDescription.zig");
const Options = @import("Options.zig");

const Application = @This();

pub const Collection = std.StringArrayHashMapUnmanaged(std.AutoHashMapUnmanaged(CascadeTarget, Application));

name: []const u8,

target: CascadeTarget,

/// The compile step using the user provided `OptimizeMode`.
compile_step: *Step.Compile,

// test_compile_step: *Step.Compile,

/// Installs the artifact produced by `compile_step`
compile_step_install_step: *Step,

/// only used for generating a dependency graph
dependencies: []const Library.Dependency,

/// Resolves all applications and their dependencies.
pub fn getApplications(
    b: *std.Build,
    step_collection: StepCollection,
    libraries: Library.Collection,
    optimize_mode: std.builtin.OptimizeMode,
    targets: []const CascadeTarget,
) !Collection {
    const application_descriptions: []const ApplicationDescription = @import("../apps/listing.zig").applications;

    var applications: Collection = .{};
    try applications.ensureTotalCapacity(b.allocator, application_descriptions.len);

    for (application_descriptions) |application_description| {
        var per_target: std.AutoHashMapUnmanaged(CascadeTarget, Application) = .{};

        const all_build_and_run_step_name = try std.fmt.allocPrint(
            b.allocator,
            "{s}",
            .{application_description.name},
        );
        const all_build_and_run_step_description = try std.fmt.allocPrint(
            b.allocator,
            "Build {s} for every supported target",
            .{application_description.name},
        );

        const all_build_and_run_step = b.step(all_build_and_run_step_name, all_build_and_run_step_description);

        for (targets) |target| {
            const application = try resolveApplication(
                b,
                step_collection,
                libraries,
                application_description,
                all_build_and_run_step,
                optimize_mode,
                target,
            );
            try per_target.put(b.allocator, target, application);
        }

        try applications.put(b.allocator, application_description.name, per_target);
    }

    return applications;
}

fn resolveApplication(
    b: *std.Build,
    step_collection: StepCollection,
    libraries: Library.Collection,
    application_description: ApplicationDescription,
    all_build_and_run_step: *std.Build.Step,
    optimize_mode: std.builtin.OptimizeMode,
    target: CascadeTarget,
) !Application {
    const dependencies = blk: {
        var dependencies = std.ArrayList(Library.Dependency).init(b.allocator);
        defer dependencies.deinit();

        for (application_description.dependencies) |dep| {
            const library = libraries.get(dep.name) orelse
                std.debug.panic("application '{s}'' depends on non-existant library '{s}'", .{
                application_description.name,
                dep.name,
            });

            const import_name = dep.import_name orelse library.name;

            try dependencies.append(.{ .import_name = import_name, .library = library });
        }

        break :blk try dependencies.toOwnedSlice();
    };

    const root_file_name = try std.fmt.allocPrint(b.allocator, "{s}.zig", .{application_description.name});

    const root_file_path = helpers.pathJoinFromRoot(b, &.{
        "apps",
        application_description.name,
        root_file_name,
    });

    const lazy_path: std.Build.LazyPath = .{ .path = root_file_path };

    const compile_step = try createExe(
        b,
        application_description,
        lazy_path,
        dependencies,
        optimize_mode,
        target,
    );

    const compile_step_install_step = b.addInstallArtifact(
        compile_step,
        .{
            .dest_dir = .{
                .override = .{
                    .custom = b.pathJoin(&.{
                        @tagName(target),
                        "apps",
                    }),
                },
            },
        },
    );

    const build_step_name = try std.fmt.allocPrint(
        b.allocator,
        "{s}_build_{s}",
        .{ application_description.name, @tagName(target) },
    );

    const build_step_description = try std.fmt.allocPrint(
        b.allocator,
        "Build {s} for {s}",
        .{ application_description.name, @tagName(target) },
    );

    const build_step = b.step(build_step_name, build_step_description);
    build_step.dependOn(&compile_step_install_step.step);

    all_build_and_run_step.dependOn(build_step);

    // const test_compile_step = try createTestExe(
    //     b,
    //     application_description,
    //     lazy_path,
    //     dependencies,
    //     target,
    // );
    // const test_install_step = b.addInstallArtifact(
    //     test_compile_step,
    //     .{
    //         .dest_dir = .{
    //             .override = .{
    //                 .custom = b.pathJoin(&.{
    //                     @tagName(target),
    //                     "tests",
    //                     "cascade",
    //                     application_description.name,
    //                 }),
    //             },
    //         },
    //     },
    // );
    //
    // const build_test_step_name = try std.fmt.allocPrint(
    //     b.allocator,
    //    "{s}_build_test_{s}",
    //    .{ application_description.name, @tagName(target) },
    // );
    //
    // const build_test_step_description =
    //     try std.fmt.allocPrint(
    //     b.allocator,
    //     "Build the tests for {s} on {s}",
    //     .{application_description.name, @tagName(target)},
    // );

    // const test_step = b.step(build_test_step_name, build_test_step_description);
    // test_step.dependOn(&test_install_step.step);
    //
    // all_build_and_run_step.dependOn(test_step);

    step_collection.registerApplication(build_step); // test_step);

    return .{
        .name = application_description.name,

        .target = target,

        .compile_step = compile_step,
        // .test_compile_step = test_compile_step,
        .compile_step_install_step = &compile_step_install_step.step,

        .dependencies = dependencies,
    };
}

fn createExe(
    b: *std.Build,
    application_description: ApplicationDescription,
    lazy_path: std.Build.LazyPath,
    dependencies: []const Library.Dependency,
    optimize_mode: std.builtin.OptimizeMode,
    target: CascadeTarget,
) !*Step.Compile {
    const exe = b.addExecutable(.{
        .name = application_description.name,
        .root_source_file = lazy_path,
        .target = target.getCascadeCrossTarget(b),
        .optimize = optimize_mode,
    });

    addDependenciesToModule(&exe.root_module, application_description, dependencies);

    if (application_description.custom_configuration) |f| f(b, application_description, exe);

    return exe;
}

fn createTestExe(
    b: *std.Build,
    application_description: ApplicationDescription,
    lazy_path: std.Build.LazyPath,
    dependencies: []const Library.Dependency,
    target: CascadeTarget,
) !*Step.Compile {
    const test_exe = b.addTest(.{
        .name = try std.mem.concat(b.allocator, u8, &.{ application_description.name, "_test" }),
        .root_source_file = lazy_path,
        .target = target.getCascadeCrossTarget(b),
    });

    addDependenciesToModule(&test_exe.root_module, application_description, dependencies);

    if (application_description.custom_configuration) |f| f(b, application_description, test_exe);

    return test_exe;
}

fn addDependenciesToModule(
    module: *std.Build.Module,
    application_description: ApplicationDescription,
    dependencies: []const Library.Dependency,
) void {
    // self reference
    module.addImport(application_description.name, module);

    for (dependencies) |dep| {
        const dep_module = dep.library.non_cascade_module_for_host orelse {
            std.debug.panic(
                "application '{s}' depends on '{s}' that does not support the host architecture.\n",
                .{ application_description.name, dep.library.name },
            );
        };
        module.addImport(dep.import_name, dep_module);
    }
}
