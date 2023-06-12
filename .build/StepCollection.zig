// SPDX-License-Identifier: MIT

const std = @import("std");
const Step = std.Build.Step;

const CascadeTarget = @import("CascadeTarget.zig").CascadeTarget;

const StepCollection = @This();

all_test_step: *Step,
test_step_per_target: std.AutoHashMapUnmanaged(CascadeTarget, *Step),

all_kernels_build_step: *Step,
kernels_build_step_per_target: std.AutoHashMapUnmanaged(CascadeTarget, *Step),

all_images_build_step: *Step,
images_build_step_per_target: std.AutoHashMapUnmanaged(CascadeTarget, *Step),

all_libraries_test_build_step: *Step,
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
        "test_all",
        "Run all the tests (also builds all code even if they don't have tests)",
    );

    var test_step_per_target: std.AutoHashMapUnmanaged(CascadeTarget, *Step) = .{};
    errdefer test_step_per_target.deinit(b.allocator);
    try test_step_per_target.ensureTotalCapacity(b.allocator, @intCast(u32, all_targets.len));

    // test_step_per_target
    for (all_targets) |target| {
        const name = try std.fmt.allocPrint(
            b.allocator,
            "test_{s}",
            .{@tagName(target)},
        );
        const description = try std.fmt.allocPrint(
            b.allocator,
            "Run all the tests (also builds all code even if they don't have tests) for {s}",
            .{@tagName(target)},
        );

        const step = b.step(name, description);
        all_test_step.dependOn(step);

        test_step_per_target.putAssumeCapacityNoClobber(target, step);
    }

    const all_kernels_build_step = b.step(
        "kernels",
        "Build all the kernels",
    );

    var kernels_build_step_per_target: std.AutoHashMapUnmanaged(CascadeTarget, *Step) = .{};
    errdefer kernels_build_step_per_target.deinit(b.allocator);
    try kernels_build_step_per_target.ensureTotalCapacity(b.allocator, @intCast(u32, all_targets.len));

    // kernels_build_step_per_target
    for (all_targets) |target| {
        const name = try std.fmt.allocPrint(
            b.allocator,
            "kernel_{s}",
            .{@tagName(target)},
        );
        const description = try std.fmt.allocPrint(
            b.allocator,
            "Build the kernel for {s}",
            .{@tagName(target)},
        );

        const step = b.step(name, description);
        all_kernels_build_step.dependOn(step);

        test_step_per_target.get(target).?.dependOn(step);

        kernels_build_step_per_target.putAssumeCapacityNoClobber(target, step);
    }

    const all_images_build_step = b.step(
        "images",
        "Build all the kernels",
    );

    var images_build_step_per_target: std.AutoHashMapUnmanaged(CascadeTarget, *Step) = .{};
    errdefer images_build_step_per_target.deinit(b.allocator);
    try images_build_step_per_target.ensureTotalCapacity(b.allocator, @intCast(u32, all_targets.len));

    // images_build_step_per_target
    for (all_targets) |target| {
        const name = try std.fmt.allocPrint(
            b.allocator,
            "image_{s}",
            .{@tagName(target)},
        );
        const description = try std.fmt.allocPrint(
            b.allocator,
            "Build the image for {s}",
            .{@tagName(target)},
        );

        const step = b.step(name, description);
        all_images_build_step.dependOn(step);

        // images are not built as part of tests

        images_build_step_per_target.putAssumeCapacityNoClobber(target, step);
    }

    const all_libraries_test_build_step = b.step(
        "build_library_tests",
        "Build all the library tests",
    );

    var libraries_test_build_step_per_target: std.AutoHashMapUnmanaged(CascadeTarget, *Step) = .{};
    errdefer libraries_test_build_step_per_target.deinit(b.allocator);
    try libraries_test_build_step_per_target.ensureTotalCapacity(b.allocator, @intCast(u32, all_targets.len));

    // libraries_test_build_step_per_target
    for (all_targets) |target| {
        {
            const name = try std.fmt.allocPrint(
                b.allocator,
                "build_library_tests_{s}",
                .{@tagName(target)},
            );
            const description = try std.fmt.allocPrint(
                b.allocator,
                "Build all the library tests for {s}",
                .{@tagName(target)},
            );

            const step = b.step(name, description);
            all_libraries_test_build_step.dependOn(step);

            test_step_per_target.get(target).?.dependOn(step);

            libraries_test_build_step_per_target.putAssumeCapacityNoClobber(target, step);
        }
    }

    return .{
        .all_test_step = all_test_step,
        .test_step_per_target = test_step_per_target,

        .all_kernels_build_step = all_kernels_build_step,
        .kernels_build_step_per_target = kernels_build_step_per_target,

        .all_images_build_step = all_images_build_step,
        .images_build_step_per_target = images_build_step_per_target,

        .all_libraries_test_build_step = all_libraries_test_build_step,
        .libraries_test_build_step_per_target = libraries_test_build_step_per_target,
    };
}
