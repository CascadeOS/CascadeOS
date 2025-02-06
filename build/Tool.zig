// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>

pub const Collection = std.StringArrayHashMapUnmanaged(Tool);

const Tool = @This();

name: []const u8,

/// The exe using the user provided `OptimizeMode`.
normal_exe: *Step.Compile,

/// The exe using `OptimizeMode.ReleaseSafe`.
///
/// If the user provided `OptimizeMode` is `.ReleaseSafe` then `release_safe_exe == normal_exe`.
release_safe_exe: *Step.Compile,

test_exe: *Step.Compile,

/// Installs the artifact produced by `normal_exe`
exe_install_step: *Step,

/// only used for generating a dependency graph
dependencies: []const Library.Dependency,

/// Resolves all tools and their dependencies.
pub fn getTools(
    b: *std.Build,
    step_collection: StepCollection,
    libraries: Library.Collection,
    optimize_mode: std.builtin.OptimizeMode,
) !Collection {
    const tool_descriptions: []const ToolDescription = @import("../tool/listing.zig").tools;

    var tools: Collection = .{};
    try tools.ensureTotalCapacity(b.allocator, tool_descriptions.len);

    for (tool_descriptions) |tool_description| {
        const tool = try resolveTool(b, step_collection, libraries, tool_description, optimize_mode);
        tools.putAssumeCapacityNoClobber(tool_description.name, tool);
    }

    return tools;
}

fn resolveTool(
    b: *std.Build,
    step_collection: StepCollection,
    libraries: Library.Collection,
    tool_description: ToolDescription,
    optimize_mode: std.builtin.OptimizeMode,
) !Tool {
    const dependencies = blk: {
        var dependencies = try std.ArrayList(Library.Dependency).initCapacity(b.allocator, tool_description.dependencies.len);
        defer dependencies.deinit();

        for (tool_description.dependencies) |dep| {
            if (libraries.get(dep.name)) |dep_library| {
                dependencies.appendAssumeCapacity(.{
                    .import_name = dep.import_name orelse dep.name,
                    .library = dep_library,
                });
            } else {
                std.debug.panic("tool '{s}' has unresolvable dependency: {s}\n", .{ tool_description.name, dep.name });
            }
        }

        break :blk try dependencies.toOwnedSlice();
    };

    const root_file_name = try std.fmt.allocPrint(b.allocator, "{s}.zig", .{tool_description.name});

    const test_name = try std.mem.concat(b.allocator, u8, &.{ tool_description.name, "_test" });

    const lazy_path = b.path(b.pathJoin(&.{
        "tool",
        tool_description.name,
        root_file_name,
    }));

    const normal_module = b.createModule(.{
        .root_source_file = lazy_path,
        .target = b.graph.host,
        .optimize = optimize_mode,
    });
    addDependenciesToModule(normal_module, tool_description, dependencies);
    handleToolConfiguration(b, tool_description, normal_module);

    { // FIXME: `-fno-emit-bin` + c files is broken https://github.com/CascadeOS/CascadeOS/issues/96
        // const check_exe = b.addExecutable(.{
        //     .name = tool_description.name,
        //     .root_module = normal_module,
        // });
        // step_collection.registerCheck(check_exe);
    }

    const normal_exe = b.addExecutable(.{
        .name = tool_description.name,
        .root_module = normal_module,
    });

    const release_safe_exe = if (optimize_mode == .ReleaseSafe)
        normal_exe
    else release_safe_exe: {
        const release_safe_module = b.createModule(.{
            .root_source_file = lazy_path,
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        });
        addDependenciesToModule(release_safe_module, tool_description, dependencies);
        handleToolConfiguration(b, tool_description, release_safe_module);

        break :release_safe_exe b.addExecutable(.{
            .name = tool_description.name,
            .root_module = release_safe_module,
        });
    };

    const exe_install_step = b.addInstallArtifact(
        normal_exe,
        .{
            .dest_dir = .{
                .override = .{
                    .custom = b.pathJoin(&.{
                        "tool",
                        tool_description.name,
                    }),
                },
            },
        },
    );

    const build_step_name = try std.fmt.allocPrint(
        b.allocator,
        "{s}_build",
        .{tool_description.name},
    );

    const build_step_description =
        try std.fmt.allocPrint(
        b.allocator,
        "Build the {s} tool",
        .{tool_description.name},
    );

    const build_step = b.step(build_step_name, build_step_description);
    build_step.dependOn(&exe_install_step.step);

    { // FIXME: `-fno-emit-bin` + c files is broken https://github.com/CascadeOS/CascadeOS/issues/96
        // const check_test_exe = b.addTest(.{
        //     .name = test_name,
        //     .root_module = normal_module,
        // });
        // step_collection.registerCheck(check_test_exe);
    }

    // FIXME: workaround for `-fno-emit-bin` + c files is broken https://github.com/CascadeOS/CascadeOS/issues/96
    const test_exe = b.addTest(.{
        .name = test_name,
        .root_module = normal_module,
    });
    step_collection.registerCheck(test_exe);

    const test_install_step = b.addInstallArtifact(
        test_exe,
        .{
            .dest_dir = .{
                .override = .{
                    .custom = b.pathJoin(&.{
                        "tool",
                        tool_description.name,
                    }),
                },
            },
        },
    );

    const run_test = b.addRunArtifact(test_exe);
    run_test.step.dependOn(&test_install_step.step); // ensure the test exe is installed

    const test_step_name = try std.fmt.allocPrint(
        b.allocator,
        "{s}_test",
        .{tool_description.name},
    );

    const test_step_description =
        try std.fmt.allocPrint(
        b.allocator,
        "Run the tests for {s} on the host os",
        .{tool_description.name},
    );

    const test_step = b.step(test_step_name, test_step_description);
    test_step.dependOn(&run_test.step);

    step_collection.registerTool(build_step, test_step);

    const run_step_name = try std.fmt.allocPrint(
        b.allocator,
        "{s}",
        .{tool_description.name},
    );

    const run_step_description =
        try std.fmt.allocPrint(
        b.allocator,
        "Run {s}",
        .{tool_description.name},
    );

    const run = b.addRunArtifact(normal_exe);
    run.step.dependOn(&exe_install_step.step);

    if (b.args) |args| {
        run.addArgs(args);
    }

    const run_step = b.step(run_step_name, run_step_description);
    run_step.dependOn(&run.step);

    return .{
        .name = tool_description.name,
        .normal_exe = normal_exe,
        .release_safe_exe = release_safe_exe,
        .test_exe = test_exe,
        .exe_install_step = &exe_install_step.step,

        .dependencies = dependencies,
    };
}

fn handleToolConfiguration(b: *std.Build, tool_description: ToolDescription, module: *std.Build.Module) void {
    switch (tool_description.configuration) {
        .simple => {},
        .link_c => module.link_libc = true,
        .custom => |f| f(b, tool_description, module),
    }
}

fn addDependenciesToModule(
    module: *std.Build.Module,
    tool_description: ToolDescription,
    dependencies: []const Library.Dependency,
) void {
    // self reference
    module.addImport(tool_description.name, module);

    for (dependencies) |dep| {
        const dep_module = dep.library.non_cascade_module_for_host orelse {
            std.debug.panic(
                "tool '{s}' depends on '{s}' that does not support the host architecture.\n",
                .{ tool_description.name, dep.library.name },
            );
        };
        module.addImport(dep.import_name, dep_module);
    }
}

const std = @import("std");
const Step = std.Build.Step;

const helpers = @import("helpers.zig");

const Library = @import("Library.zig");
const StepCollection = @import("StepCollection.zig");
const ToolDescription = @import("ToolDescription.zig");
const Options = @import("Options.zig");
