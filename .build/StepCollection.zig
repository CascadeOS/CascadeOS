// SPDX-License-Identifier: MIT

const std = @import("std");
const Step = std.Build.Step;

const CascadeTarget = @import("CascadeTarget.zig").CascadeTarget;

const StepCollection = @This();

kernels_build_step_per_target: std.AutoHashMapUnmanaged(CascadeTarget, *Step),

images_build_step_per_target: std.AutoHashMapUnmanaged(CascadeTarget, *Step),

libraries_test_build_step_per_target: std.AutoHashMapUnmanaged(CascadeTarget, *Step),

pub fn registerKernel(self: StepCollection, target: CascadeTarget, step: *Step) void {
    self.kernels_build_step_per_target.get(target).?.dependOn(step);
}

pub fn registerImage(self: StepCollection, target: CascadeTarget, step: *Step) void {
    self.images_build_step_per_target.get(target).?.dependOn(step);
}

pub fn registerLibrary(self: StepCollection, target: CascadeTarget, step: *Step) void {
    self.libraries_test_build_step_per_target.get(target).?.dependOn(step);
}

pub fn create(b: *std.Build, all_targets: []const CascadeTarget) !StepCollection {
    const all_test_step = b.step(
        "test",
        "Run all the tests (also builds all code even if they don't have tests)",
    );
    b.default_step = all_test_step;

    // Kernels

    const all_kernels_build_step = b.step(
        "kernels",
        "Build all the kernels",
    );
    all_test_step.dependOn(all_kernels_build_step);

    const kernels_build_step_per_target = try buildPerTargetSteps(
        b,
        all_targets,
        all_kernels_build_step,
        "kernel_{s}",
        "Build the kernel for {s}",
    );

    // Images

    const all_images_build_step = b.step(
        "images",
        "Build all the images",
    );

    const images_build_step_per_target = try buildPerTargetSteps(
        b,
        all_targets,
        all_images_build_step,
        "image_{s}",
        "Build the image for {s}",
    );

    // Libraries

    const all_test_build_step = b.step(
        "build_tests",
        "Build all the tests",
    );
    all_test_step.dependOn(all_test_build_step);

    const libraries_test_build_step_per_target = try buildPerTargetSteps(
        b,
        all_targets,
        all_test_build_step,
        "build_tests_{s}",
        "Build all the tests for {s}",
    );

    return .{
        .kernels_build_step_per_target = kernels_build_step_per_target,

        .images_build_step_per_target = images_build_step_per_target,

        .libraries_test_build_step_per_target = libraries_test_build_step_per_target,
    };
}

fn buildPerTargetSteps(
    b: *std.Build,
    all_targets: []const CascadeTarget,
    relevant_all_step: *Step,
    comptime name_fmt: []const u8,
    comptime description_fmt: []const u8,
) !std.AutoHashMapUnmanaged(CascadeTarget, *Step) {
    var map: std.AutoHashMapUnmanaged(CascadeTarget, *Step) = .{};
    errdefer map.deinit(b.allocator);

    for (all_targets) |target| {
        const name = try std.fmt.allocPrint(b.allocator, name_fmt, .{@tagName(target)});
        const description = try std.fmt.allocPrint(b.allocator, description_fmt, .{@tagName(target)});

        const step = b.step(name, description);
        relevant_all_step.dependOn(step);

        try map.putNoClobber(b.allocator, target, step);
    }

    return map;
}
