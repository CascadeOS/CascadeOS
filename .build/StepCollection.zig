// SPDX-License-Identifier: MIT

const std = @import("std");
const Step = std.Build.Step;

const CascadeTarget = @import("CascadeTarget.zig").CascadeTarget;

const StepCollection = @This();

main_test_step: *Step,

kernels_build_step: *Step,

libraries_test_build_step: *Step,
libraries_test_build_step_per_target: std.AutoHashMapUnmanaged(CascadeTarget, *Step),

pub fn create(b: *std.Build, all_targets: []const CascadeTarget) !StepCollection {
    const main_test_step = b.step(
        "test",
        "Run all the tests (also builds all code even if they don't have tests)",
    );

    const libraries_test_build_step = b.step(
        "build_libraries",
        "Build all the library tests",
    );
    main_test_step.dependOn(libraries_test_build_step);

    var libraries_test_build_step_per_target: std.AutoHashMapUnmanaged(CascadeTarget, *Step) = .{};
    errdefer libraries_test_build_step_per_target.deinit(b.allocator);

    try libraries_test_build_step_per_target.ensureTotalCapacity(b.allocator, @intCast(u32, all_targets.len));

    for (all_targets) |target| {
        const libraries_test_build_step_for_target_name = try std.fmt.allocPrint(
            b.allocator,
            "build_libraries_{s}",
            .{@tagName(target)},
        );
        const libraries_test_build_step_for_target_description = try std.fmt.allocPrint(
            b.allocator,
            "Build all the library tests for {s}",
            .{@tagName(target)},
        );

        const libraries_test_build_step_for_target = b.step(
            libraries_test_build_step_for_target_name,
            libraries_test_build_step_for_target_description,
        );

        libraries_test_build_step_per_target.putAssumeCapacityNoClobber(target, libraries_test_build_step_for_target);
        libraries_test_build_step.dependOn(libraries_test_build_step_for_target);
    }

    const kernels_build_step = b.step(
        "build_kernels",
        "Build all the kernels",
    );
    main_test_step.dependOn(kernels_build_step);

    return StepCollection{
        .main_test_step = main_test_step,
        .kernels_build_step = kernels_build_step,

        .libraries_test_build_step = libraries_test_build_step,
        .libraries_test_build_step_per_target = libraries_test_build_step_per_target,
    };
}
