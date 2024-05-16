// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const Step = std.Build.Step;

const helpers = @import("helpers.zig");

const Library = @import("Library.zig");
const StepCollection = @import("StepCollection.zig");
const ToolDescription = @import("ToolDescription.zig");
const Options = @import("Options.zig");

const Tool = @This();

pub const Collection = std.StringArrayHashMapUnmanaged(Tool);

name: []const u8,

/// The compile step using the user provided `OptimizeMode`.
compile_step: *Step.Compile,

/// The compile step using `OptimizeMode.ReleaseSafe`.
///
/// If the user provided `OptimizeMode` is `.ReleaseSafe` then `release_safe_compile_step == compile_step`.
release_safe_compile_step: *Step.Compile,

test_compile_step: *Step.Compile,

/// Installs the artifact produced by `compile_step`
compile_step_install_step: *Step,

/// only used for generating a dependency graph
dependencies: []const Library.Dependency,

/// Resolves all tools and their dependencies.
pub fn getTools(
    b: *std.Build,
    step_collection: StepCollection,
    libraries: Library.Collection,
    optimize_mode: std.builtin.OptimizeMode,
) !Collection {
    const tool_descriptions: []const ToolDescription = @import("../tools/listing.zig").tools;

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

    const lazy_path = b.path(b.pathJoin(&.{
        "tools",
        tool_description.name,
        root_file_name,
    }));

    const compile_step = try createExe(
        b,
        tool_description,
        lazy_path,
        dependencies,
        optimize_mode,
    );

    const release_safe_compile_step = if (optimize_mode == .ReleaseSafe)
        compile_step
    else
        try createExe(
            b,
            tool_description,
            lazy_path,
            dependencies,
            .ReleaseSafe,
        );

    const compile_step_install_step = b.addInstallArtifact(
        compile_step,
        .{
            .dest_dir = .{
                .override = .{
                    .custom = b.pathJoin(&.{
                        "tools",
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
    build_step.dependOn(&compile_step_install_step.step);

    const test_compile_step = try createTestExe(b, tool_description, lazy_path, dependencies);
    const test_install_step = b.addInstallArtifact(
        test_compile_step,
        .{
            .dest_dir = .{
                .override = .{
                    .custom = b.pathJoin(&.{
                        "tools",
                        tool_description.name,
                    }),
                },
            },
        },
    );

    const run_test = b.addRunArtifact(test_compile_step);
    run_test.step.dependOn(&test_install_step.step);

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

    const run = b.addRunArtifact(compile_step);
    run.step.dependOn(&compile_step_install_step.step);

    if (b.args) |args| {
        run.addArgs(args);
    }

    const run_step = b.step(run_step_name, run_step_description);
    run_step.dependOn(&run.step);

    return .{
        .name = tool_description.name,
        .compile_step = compile_step,
        .release_safe_compile_step = release_safe_compile_step,
        .test_compile_step = test_compile_step,
        .compile_step_install_step = &compile_step_install_step.step,

        .dependencies = dependencies,
    };
}

fn createExe(
    b: *std.Build,
    tool_description: ToolDescription,
    lazy_path: std.Build.LazyPath,
    dependencies: []const Library.Dependency,
    optimize_mode: std.builtin.OptimizeMode,
) !*Step.Compile {
    const exe = b.addExecutable(.{
        .name = tool_description.name,
        .root_source_file = lazy_path,
        .target = b.host,
        .optimize = optimize_mode,
    });

    addDependenciesToModule(&exe.root_module, tool_description, dependencies);

    if (tool_description.custom_configuration) |f| f(b, tool_description, exe);

    return exe;
}

fn createTestExe(
    b: *std.Build,
    tool_description: ToolDescription,
    lazy_path: std.Build.LazyPath,
    dependencies: []const Library.Dependency,
) !*Step.Compile {
    const test_exe = b.addTest(.{
        .name = try std.mem.concat(b.allocator, u8, &.{ tool_description.name, "_test" }),
        .root_source_file = lazy_path,
    });

    addDependenciesToModule(&test_exe.root_module, tool_description, dependencies);

    if (tool_description.custom_configuration) |f| f(b, tool_description, test_exe);

    return test_exe;
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
