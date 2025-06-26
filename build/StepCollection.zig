// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const StepCollection = @This();

/// A map from `CascadeTarget.Architecture` to their kernel build steps.
kernel_build_steps_per_architecture: Steps,

/// A map from `CascadeTarget.Architecture` to their image build steps.
image_build_steps_per_architecture: Steps,

/// A map from `CascadeTarget.Architecture` to their non-Cascade library test steps.
non_cascade_library_test_steps_per_architecture: Steps,

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

/// Registers a kernel build step for a `CascadeTarget.Architecture`.
pub fn registerKernel(
    step_collection: StepCollection,
    architecture: CascadeTarget.Architecture,
    install_both_kernel_binaries: *Step,
) void {
    step_collection.kernel_build_steps_per_architecture.get(architecture).?.dependOn(install_both_kernel_binaries);
}

/// Registers an image build step for an architecturt.
pub fn registerImage(step_collection: StepCollection, architecture: CascadeTarget.Architecture, step: *Step) void {
    step_collection.image_build_steps_per_architecture.get(architecture).?.dependOn(step);
}

/// Registers a Cascade library build step for an architecturt.
pub fn registerCascadeLibrary(step_collection: StepCollection, architecture: CascadeTarget.Architecture, install_step: *Step) void {
    step_collection.cascade_library_build_steps_per_architecture.get(architecture).?.dependOn(install_step);
}

/// Registers non-Cascade library build and run steps for an architecture.
pub fn registerNonCascadeLibrary(step_collection: StepCollection, architecture: CascadeTarget.Architecture, run_step: *Step) void {
    step_collection.non_cascade_library_test_steps_per_architecture.get(architecture).?.dependOn(run_step);
}

pub fn create(b: *std.Build, all_architectures: []const CascadeTarget.Architecture) !StepCollection {
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

    const kernel_build_steps_per_architecture = try buildPerArchitectureSteps(
        b,
        all_architectures,
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

    const image_build_steps_per_architecture = try buildPerArchitectureSteps(
        b,
        all_architectures,
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

    const all_library_host_test_step = b.step(
        "libraries_host",
        "Attempt to run all the library tests targeting the host os",
    );
    all_library_step.dependOn(all_library_host_test_step);

    const non_cascade_library_test_steps_per_architecture = try buildPerArchitectureSteps(
        b,
        all_architectures,
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

        .kernel_build_steps_per_architecture = kernel_build_steps_per_architecture,

        .image_build_steps_per_architecture = image_build_steps_per_architecture,

        .non_cascade_library_test_steps_per_architecture = non_cascade_library_test_steps_per_architecture,

        .tools_build_step = all_tools_build_step,
        .tools_test_step = all_tools_test_step,
    };
}

/// Builds steps for each architecture that depend on the relevant "all" step.
fn buildPerArchitectureSteps(
    b: *std.Build,
    all_architectures: []const CascadeTarget.Architecture,
    relevant_all_step: *Step,
    comptime name_fmt: []const u8,
    comptime description_fmt: []const u8,
) !Steps {
    var map: Steps = .{};
    errdefer map.deinit(b.allocator);

    for (all_architectures) |architecture| {
        const name = try std.fmt.allocPrint(b.allocator, name_fmt, .{@tagName(architecture)});
        const description = try std.fmt.allocPrint(b.allocator, description_fmt, .{@tagName(architecture)});

        const step = b.step(name, description);
        relevant_all_step.dependOn(step);

        try map.putNoClobber(b.allocator, architecture, step);
    }

    return map;
}

const std = @import("std");
const Step = std.Build.Step;

const CascadeTarget = @import("CascadeTarget.zig").CascadeTarget;
const Options = @import("Options.zig");
const Steps = std.AutoHashMapUnmanaged(CascadeTarget.Architecture, *Step);
