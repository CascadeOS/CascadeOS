// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const Step = std.Build.Step;

const ApplicationDescription = @import("ApplicationDescription.zig");
const CascadeTarget = @import("CascadeTarget.zig").CascadeTarget;
const Library = @import("Library.zig");
const Options = @import("Options.zig");
const StepCollection = @import("StepCollection.zig");

const Exes = std.AutoHashMapUnmanaged(CascadeTarget, *std.Build.Step.Compile);
pub const Collection = std.StringArrayHashMapUnmanaged(Application);

const Application = @This();

name: []const u8,

/// Executables for each supported Cascade architecture for cascade and the host.
exes: Exes,

/// Resolves all applications and their dependencies.
pub fn getApplications(
    b: *std.Build,
    step_collection: StepCollection,
    libraries: Library.Collection,
    options: Options,
    all_architectures: []const CascadeTarget.Architecture,
) !Collection {
    const application_descriptions: []const ApplicationDescription = @import("../user/listing.zig").applications;

    var applications: Collection = .{};
    try applications.ensureTotalCapacity(b.allocator, application_descriptions.len);

    for (application_descriptions) |application_description| {
        const app = try resolveApp(
            b,
            step_collection,
            libraries,
            application_description,
            options,
            all_architectures,
        );
        applications.putAssumeCapacityNoClobber(app.name, app);
    }

    return applications;
}

fn resolveApp(
    b: *std.Build,
    step_collection: StepCollection,
    libraries: Library.Collection,
    application_description: ApplicationDescription,
    options: Options,
    all_architectures: []const CascadeTarget.Architecture,
) !Application {
    const dependencies = blk: {
        var dependencies: std.ArrayList(*const Library) = try .initCapacity(
            b.allocator,
            application_description.dependencies.len,
        );
        defer dependencies.deinit(b.allocator);

        for (application_description.dependencies) |dep_name| {
            const dep_library = libraries.get(dep_name) orelse std.debug.panic(
                "application '{s}' has unresolvable dependency: {s}\n",
                .{ application_description.name, dep_name },
            );

            dependencies.appendAssumeCapacity(dep_library);
        }

        break :blk try dependencies.toOwnedSlice(b.allocator);
    };

    const root_file_name = try std.fmt.allocPrint(
        b.allocator,
        "{s}.zig",
        .{application_description.name},
    );

    const lazy_path = b.path(b.pathJoin(&.{
        "user",
        application_description.name,
        root_file_name,
    }));

    const all_build_and_test_step = b.step(
        try std.fmt.allocPrint(
            b.allocator,
            "{s}_test",
            .{application_description.name},
        ),
        try std.fmt.allocPrint(
            b.allocator,
            "Build the tests for {s} for every supported architecture and attempt to run non-cascade test binaries",
            .{application_description.name},
        ),
    );

    var exes: Exes = .{};

    for (all_architectures) |architecture| {
        // host
        {
            const host_target: CascadeTarget = .{
                .architecture = architecture,
                .context = .non_cascade,
            };

            const host_module = createModule(
                b,
                application_description,
                lazy_path,
                options,
                host_target,
                dependencies,
            );

            const host_exe = b.addExecutable(.{
                .name = application_description.name,
                .root_module = host_module,
            });
            try exes.putNoClobber(b.allocator, host_target, host_exe);

            // host check exe
            {
                const host_check_exe = b.addExecutable(.{
                    .name = try std.mem.concat(b.allocator, u8, &.{ application_description.name, "_host_check" }),
                    .root_module = host_module,
                });
                step_collection.registerCheck(host_check_exe);
            }

            // host test exe
            {
                const host_test_module = createModule(
                    b,
                    application_description,
                    lazy_path,
                    options,
                    host_target,
                    dependencies,
                );

                const host_test_exe = b.addTest(.{
                    .name = application_description.name,
                    .root_module = host_test_module,
                });

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
                    .{ application_description.name, architecture },
                );

                const host_test_step_description =
                    try std.fmt.allocPrint(
                        b.allocator,
                        "Build and attempt to run the tests for {s} on {t} targeting the host os",
                        .{ application_description.name, architecture },
                    );

                const host_test_step = b.step(host_test_step_name, host_test_step_description);
                host_test_step.dependOn(&host_test_run_step.step);

                all_build_and_test_step.dependOn(host_test_step);
                step_collection.registerNonCascadeApplication(architecture, host_test_step);
            }
        }

        // cascade
        {
            const cascade_target: CascadeTarget = .{
                .architecture = architecture,
                .context = .cascade,
            };

            const cascade_module = createModule(
                b,
                application_description,
                lazy_path,
                options,
                cascade_target,
                dependencies,
            );

            const cascade_exe = b.addExecutable(.{
                .name = application_description.name,
                .root_module = cascade_module,
            });
            try exes.putNoClobber(b.allocator, cascade_target, cascade_exe);

            // cascade check exe
            {
                const cascade_check_exe = b.addExecutable(.{
                    .name = try std.mem.concat(b.allocator, u8, &.{ application_description.name, "_cascade_check" }),
                    .root_module = cascade_module,
                });
                step_collection.registerCheck(cascade_check_exe);
            }

            // TODO: cascade test exe
            all_build_and_test_step.dependOn(&cascade_exe.step);
        }
    }

    // host run exe step
    blk: {
        const native_cascade_target = CascadeTarget.getNative(b) orelse break :blk;
        const host_exe = exes.get(native_cascade_target) orelse break :blk;

        const host_exe_install_step = b.addInstallArtifact(
            host_exe,
            .{
                .dest_dir = .{
                    .override = .{
                        .custom = b.pathJoin(&.{
                            @tagName(native_cascade_target.architecture),
                            "applications",
                            "non_cascade",
                        }),
                    },
                },
            },
        );

        const host_run_step = b.addRunArtifact(host_exe);
        host_run_step.step.dependOn(&host_exe_install_step.step); // ensure the test exe is installed

        const run_step = b.step(
            application_description.name,
            try std.fmt.allocPrint(
                b.allocator,
                "Run {s} targeting the host os",
                .{application_description.name},
            ),
        );

        run_step.dependOn(&host_run_step.step);
    }

    return .{
        .name = application_description.name,
        .exes = exes,
    };
}

fn createModule(
    b: *std.Build,
    application_description: ApplicationDescription,
    root_source_file: std.Build.LazyPath,
    options: Options,
    cascade_target: CascadeTarget,
    dependencies: []const *const Library,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = root_source_file,
        .target = cascade_target.getCrossTarget(b),
        .optimize = options.optimize,
        .sanitize_c = .off, // TODO: this should depend on if we are linking c code
        // .sanitize_c = switch (options.optimize) {
        //     .ReleaseFast => .off,
        //     .ReleaseSmall => .trap,
        //     else => .full,
        // },
    });

    // self reference
    module.addImport(application_description.name, module);

    switch (cascade_target.context) {
        .cascade => module.addImport("cascade_flag", options.cascade_detect_option_module),
        .non_cascade => module.addImport("cascade_flag", options.non_cascade_detect_option_module),
    }

    for (dependencies) |dependency| {
        const dependency_module = switch (cascade_target.context) {
            .cascade => dependency.cascade_modules.get(cascade_target.architecture) orelse unreachable,
            .non_cascade => dependency.non_cascade_modules.get(cascade_target.architecture) orelse unreachable,
        };

        module.addImport(dependency.name, dependency_module);
    }

    return module;
}
