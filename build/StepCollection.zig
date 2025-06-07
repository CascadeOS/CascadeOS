// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const StepCollection = @This();

/// A map from targets to their kernel build steps.
kernel_build_steps_per_target: Steps,

/// A map from targets to their image build steps.
image_build_steps_per_target: Steps,

/// A map from targets to their non-Cascade library test steps.
non_cascade_library_test_steps_per_target: Steps,

tools_build_step: *Step,
tools_test_step: *Step,

check_step: *Step,

/// Registers a check step.
pub fn registerCheck(step_collection: StepCollection, exe: *Step.Compile) void {
    step_collection.check_step.dependOn(&exe.step);
}

/// Registers a tool.
pub fn registerTool(step_collection: StepCollection, build_step: *Step, test_step: *Step) void {
    step_collection.tools_build_step.dependOn(build_step);
    step_collection.tools_test_step.dependOn(test_step);
}

/// Registers a kernel build step for a target.
pub fn registerKernel(
    step_collection: StepCollection,
    target: CascadeTarget,
    install_both_kernel_binaries: *Step,
) void {
    step_collection.kernel_build_steps_per_target.get(target).?.dependOn(install_both_kernel_binaries);
}

/// Registers an image build step for a target.
pub fn registerImage(step_collection: StepCollection, target: CascadeTarget, step: *Step) void {
    step_collection.image_build_steps_per_target.get(target).?.dependOn(step);
}

/// Registers a Cascade library build step for a target.
pub fn registerCascadeLibrary(step_collection: StepCollection, target: CascadeTarget, install_step: *Step) void {
    step_collection.cascade_library_build_steps_per_target.get(target).?.dependOn(install_step);
}

/// Registers non-Cascade library build and run steps for a target.
pub fn registerNonCascadeLibrary(step_collection: StepCollection, target: CascadeTarget, run_step: *Step) void {
    step_collection.non_cascade_library_test_steps_per_target.get(target).?.dependOn(run_step);
}

pub fn create(b: *std.Build, targets: []const CascadeTarget) !StepCollection {
    const check_step = b.step("check", "Build all code with -fno-emit-bin");

    const all_test_step = b.step(
        "test",
        "Run all the tests (also builds all code even if they don't have tests)",
    );

    // Kernels
    const all_kernels_build_step = b.step(
        "kernels",
        "Build all the kernels",
    );
    all_test_step.dependOn(all_kernels_build_step);

    const kernel_build_steps_per_target = try buildPerTargetSteps(
        b,
        targets,
        all_kernels_build_step,
        "kernel_{s}",
        "Build the kernel for {s}",
    );

    // Images
    const all_images_build_step = b.step(
        "images",
        "Build all the images",
    );
    all_test_step.dependOn(all_images_build_step);

    const image_build_steps_per_target = try buildPerTargetSteps(
        b,
        targets,
        all_images_build_step,
        "image_{s}",
        "Build the image for {s}",
    );

    // Libraries
    const all_library_step = b.step(
        "libraries",
        "Build and run all the library tests",
    );
    all_test_step.dependOn(all_library_step);

    // const all_library_cascade_test_step = b.step(
    //     "libraries_cascade",
    //     "Build all the library tests targeting cascade",
    // );
    // all_library_step.dependOn(all_library_cascade_test_step);

    // const cascade_library_build_steps_per_target = try buildPerTargetSteps(
    //     b,
    //     targets,
    //     all_library_cascade_test_step,
    //     "libraries_cascade_{s}",
    //     "Build all the library tests for {s} targeting cascade",
    // );

    const all_library_host_test_step = b.step(
        "libraries_host",
        "Attempt to run all the library tests targeting the host os",
    );
    all_library_step.dependOn(all_library_host_test_step);

    const non_cascade_library_test_steps_per_target = try buildPerTargetSteps(
        b,
        targets,
        all_library_host_test_step,
        "libraries_host_{s}",
        "Attempt to run all the library tests for {s} targeting the host os",
    );

    // Tools
    const all_tools_step = b.step(
        "tools",
        "Build all the tools and run all of their tests",
    );
    all_test_step.dependOn(all_tools_step);

    const all_tools_build_step = b.step(
        "tools_build",
        "Build all the tools",
    );
    all_tools_step.dependOn(all_tools_build_step);

    const all_tools_test_step = b.step(
        "tools_test",
        "Run all of the tools tests",
    );
    all_tools_step.dependOn(all_tools_test_step);

    return .{
        .check_step = check_step,

        .kernel_build_steps_per_target = kernel_build_steps_per_target,

        .image_build_steps_per_target = image_build_steps_per_target,

        // .cascade_library_build_steps_per_target = cascade_library_build_steps_per_target,

        .non_cascade_library_test_steps_per_target = non_cascade_library_test_steps_per_target,

        .tools_build_step = all_tools_build_step,
        .tools_test_step = all_tools_test_step,
    };
}

/// Builds steps for each target that depend on the relevant "all" step.
fn buildPerTargetSteps(
    b: *std.Build,
    targets: []const CascadeTarget,
    relevant_all_step: *Step,
    comptime name_fmt: []const u8,
    comptime description_fmt: []const u8,
) !Steps {
    var map: Steps = .{};
    errdefer map.deinit(b.allocator);

    for (targets) |target| {
        const name = try std.fmt.allocPrint(b.allocator, name_fmt, .{@tagName(target)});
        const description = try std.fmt.allocPrint(b.allocator, description_fmt, .{@tagName(target)});

        const step = b.step(name, description);
        relevant_all_step.dependOn(step);

        try map.putNoClobber(b.allocator, target, step);
    }

    return map;
}

const std = @import("std");
const Step = std.Build.Step;

const CascadeTarget = @import("CascadeTarget.zig").CascadeTarget;
const Options = @import("Options.zig");
const Steps = std.AutoHashMapUnmanaged(CascadeTarget, *Step);
