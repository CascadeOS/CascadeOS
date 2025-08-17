// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

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
        var dependencies: std.ArrayList(*const Library) = try .initCapacity(
            b.allocator,
            tool_description.dependencies.len,
        );
        defer dependencies.deinit(b.allocator);

        for (tool_description.dependencies) |dep_name| {
            const dep_library = libraries.get(dep_name) orelse std.debug.panic(
                "tool '{s}' has unresolvable dependency: {s}\n",
                .{ tool_description.name, dep_name },
            );

            dependencies.appendAssumeCapacity(dep_library);
        }

        break :blk try dependencies.toOwnedSlice(b.allocator);
    };

    const root_file_name = try std.fmt.allocPrint(b.allocator, "{s}.zig", .{tool_description.name});

    const lazy_path = b.path(b.pathJoin(&.{
        "tool",
        tool_description.name,
        root_file_name,
    }));

    const normal_module = createModule(
        b,
        tool_description,
        lazy_path,
        optimize_mode,
        dependencies,
    );

    {
        const check_exe = b.addExecutable(.{
            .name = try std.mem.concat(b.allocator, u8, &.{ tool_description.name, "_check" }),
            .root_module = normal_module,
        });
        step_collection.registerCheck(check_exe);
    }

    const normal_exe = b.addExecutable(.{
        .name = tool_description.name,
        .root_module = normal_module,
    });

    const release_safe_exe = if (optimize_mode == .ReleaseSafe)
        normal_exe
    else release_safe_exe: {
        const release_safe_module = createModule(
            b,
            tool_description,
            lazy_path,
            .ReleaseSafe,
            dependencies,
        );

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

    const test_name = try std.mem.concat(b.allocator, u8, &.{ tool_description.name, "_test" });

    {
        const check_test_exe = b.addTest(.{
            .name = try std.mem.concat(b.allocator, u8, &.{ test_name, "_check" }),
            .root_module = normal_module,
        });
        step_collection.registerCheck(check_test_exe);
    }

    const test_exe = b.addTest(.{
        .name = test_name,
        .root_module = normal_module,
    });

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
    };
}

fn createModule(
    b: *std.Build,
    tool_description: ToolDescription,
    root_source_file: std.Build.LazyPath,
    optimize_mode: std.builtin.OptimizeMode,
    dependencies: []const *const Library,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = root_source_file,
        .target = b.graph.host,
        .optimize = optimize_mode,
        .sanitize_c = switch (optimize_mode) {
            .ReleaseFast => .off,
            .ReleaseSmall => .trap,
            else => .full,
        },
    });

    // self reference
    module.addImport(tool_description.name, module);

    for (dependencies) |dep| {
        const dep_module = dep.non_cascade_module_for_host orelse {
            std.debug.panic(
                "tool '{s}' depends on '{s}' that does not support the host architecture.\n",
                .{ tool_description.name, dep.name },
            );
        };
        module.addImport(dep.name, dep_module);
    }

    switch (tool_description.configuration) {
        .simple => {},
        .link_c => module.link_libc = true,
        .custom => |f| f(b, tool_description, module),
    }

    return module;
}

const std = @import("std");
const Step = std.Build.Step;

const Library = @import("Library.zig");
const StepCollection = @import("StepCollection.zig");
const ToolDescription = @import("ToolDescription.zig");
const Options = @import("Options.zig");
