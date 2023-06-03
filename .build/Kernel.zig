// SPDX-License-Identifier: MIT

const std = @import("std");
const Step = std.Build.Step;

const helpers = @import("helpers.zig");

const CascadeTarget = @import("CascadeTarget.zig").CascadeTarget;
const Library = @import("Library.zig");
const Options = @import("Options.zig");
const StepCollection = @import("StepCollection.zig");

const Kernel = @This();

pub const Collection = std.AutoHashMapUnmanaged(CascadeTarget, Kernel);

b: *std.Build,

target: CascadeTarget,
options: Options,

install_step: *Step.InstallArtifact,

pub fn getKernels(
    b: *std.Build,
    libraries: Library.Collection,
    step_collection: StepCollection,
    options: Options,
    all_targets: []const CascadeTarget,
) !Collection {
    var kernels: Collection = .{};
    try kernels.ensureTotalCapacity(b.allocator, @intCast(u32, all_targets.len));

    for (all_targets) |target| {
        const kernel = try Kernel.create(b, target, libraries, options);

        const build_step_name = try std.fmt.allocPrint(
            b.allocator,
            "kernel_{s}",
            .{@tagName(target)},
        );
        const build_step_description = try std.fmt.allocPrint(
            b.allocator,
            "Build the kernel for {s}",
            .{@tagName(target)},
        );

        const build_step = b.step(build_step_name, build_step_description);
        build_step.dependOn(&kernel.install_step.step);

        step_collection.kernels_test_step.dependOn(build_step);

        kernels.putAssumeCapacityNoClobber(target, kernel);
    }

    return kernels;
}

fn create(b: *std.Build, target: CascadeTarget, libraries: Library.Collection, options: Options) !Kernel {
    const kernel_exe = b.addExecutable(.{
        .name = "kernel",
        .root_source_file = .{ .path = helpers.pathJoinFromRoot(b, &.{ "kernel", "root.zig" }) },
        .target = target.getCrossTarget(),
        .optimize = options.optimize,
    });

    kernel_exe.override_dest_dir = .{
        .custom = b.pathJoin(&.{
            @tagName(target),
            "root",
            "boot",
        }),
    };

    kernel_exe.setLinkerScriptPath(.{ .path = target.linkerScriptPath(b) });

    const kernel_module = blk: {
        const kernel_module = b.createModule(.{
            .source_file = .{ .path = helpers.pathJoinFromRoot(b, &.{ "kernel", "kernel.zig" }) },
        });

        // self reference
        try kernel_module.dependencies.put("kernel", kernel_module);

        // kernel options
        try kernel_module.dependencies.put("kernel_options", options.kernel_option_modules.get(target).?);

        // dependencies
        const kernel_dependencies: []const []const u8 = @import("../kernel/dependencies.zig").dependencies;
        for (kernel_dependencies) |dependency| {
            const library = libraries.get(dependency).?;
            try kernel_module.dependencies.put(library.name, library.module);
        }

        break :blk kernel_module;
    };

    kernel_exe.addModule("kernel", kernel_module);

    // TODO: LTO cannot be enabled https://github.com/CascadeOS/CascadeOS/issues/8
    kernel_exe.want_lto = false;
    kernel_exe.omit_frame_pointer = false;
    kernel_exe.disable_stack_probing = true;
    kernel_exe.pie = true;

    target.targetSpecificSetup(kernel_exe);

    return Kernel{
        .b = b,
        .target = target,
        .options = options,
        .install_step = b.addInstallArtifact(kernel_exe),
    };
}
