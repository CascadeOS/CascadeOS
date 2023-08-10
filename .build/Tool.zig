// SPDX-License-Identifier: MIT

const std = @import("std");
const Step = std.Build.Step;

const helpers = @import("helpers.zig");

const Library = @import("Library.zig");
const StepCollection = @import("StepCollection.zig");
const ToolDescription = @import("ToolDescription.zig");

const Tool = @This();

pub const Collection = std.StringArrayHashMapUnmanaged(*Tool);

name: []const u8,

exe: *Step.Compile,

test_exe: *Step.Compile,

exe_install_step: *Step,

/// Resolves all tools and their dependencies.
pub fn getTools(
    b: *std.Build,
    step_collection: StepCollection,
    libraries: Library.Collection,
) !Collection {
    const tool_descriptions: []const ToolDescription = @import("../tools/listing.zig").tools;

    var tools: Collection = .{};
    try tools.ensureTotalCapacity(b.allocator, tool_descriptions.len);

    for (tool_descriptions) |tool_description| {
        const tool = try resolveTool(b, step_collection, libraries, tool_description);
        tools.putAssumeCapacityNoClobber(tool_description.name, tool);
    }

    return tools;
}

fn resolveTool(
    b: *std.Build,
    step_collection: StepCollection,
    libraries: Library.Collection,
    tool_description: ToolDescription,
) !*Tool {
    const dependencies = blk: {
        var dependencies = try std.ArrayList(*Library).initCapacity(b.allocator, tool_description.dependencies.len);
        defer dependencies.deinit();

        for (tool_description.dependencies) |dep| {
            if (libraries.get(dep)) |dep_library| {
                dependencies.appendAssumeCapacity(dep_library);
            } else {
                std.debug.panic("tool '{s}' has unresolvable dependency: {s}\n", .{ tool_description.name, dep });
            }
        }

        break :blk try dependencies.toOwnedSlice();
    };

    const root_file_name = try std.fmt.allocPrint(b.allocator, "{s}.zig", .{tool_description.name});

    const root_file_path = helpers.pathJoinFromRoot(b, &.{
        "tools",
        tool_description.name,
        root_file_name,
    });

    const file_source: std.Build.FileSource = .{ .path = root_file_path };

    const exe = try createExe(b, tool_description, file_source, dependencies);

    const exe_install_step = b.addInstallArtifact(
        exe,
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

    const test_exe = try createTestExe(b, tool_description, file_source, dependencies);
    const run_test = b.addRunArtifact(test_exe);

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

    step_collection.registerTool(&exe_install_step.step, &run_test.step);

    const run = b.addRunArtifact(exe);

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

    const run_step = b.step(run_step_name, run_step_description);
    run_step.dependOn(&run.step);

    var tool = try b.allocator.create(Tool);

    tool.* = .{
        .name = tool_description.name,
        .exe = exe,
        .test_exe = test_exe,
        .exe_install_step = &exe_install_step.step,
    };

    return tool;
}

fn createExe(
    b: *std.Build,
    tool_description: ToolDescription,
    file_source: std.Build.FileSource,
    dependencies: []const *Library,
) !*Step.Compile {
    const exe = b.addExecutable(.{
        .name = tool_description.name,
        .root_source_file = file_source,
    });

    // TODO: self-referential module https://github.com/CascadeOS/CascadeOS/issues/10

    for (dependencies) |dep| {
        const module = dep.non_cascade_module_for_host orelse {
            std.debug.panic(
                "tool '{s}' depends on '{s}' that does not support the host architecture.\n",
                .{ tool_description.name, dep.name },
            );
        };
        exe.addModule(dep.name, module);
    }

    return exe;
}

fn createTestExe(
    b: *std.Build,
    tool_description: ToolDescription,
    file_source: std.Build.FileSource,
    dependencies: []const *Library,
) !*Step.Compile {
    const test_exe = b.addTest(.{
        .name = tool_description.name,
        .root_source_file = file_source,
    });

    // TODO: self-referential module https://github.com/CascadeOS/CascadeOS/issues/10

    for (dependencies) |dep| {
        const module = dep.non_cascade_module_for_host orelse {
            std.debug.panic(
                "tool '{s}' depends on '{s}' that does not support the host architecture.\n",
                .{ tool_description.name, dep.name },
            );
        };
        test_exe.addModule(dep.name, module);
    }

    return test_exe;
}
