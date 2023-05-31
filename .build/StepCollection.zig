// SPDX-License-Identifier: MIT

const std = @import("std");
const Step = std.Build.Step;

const StepCollection = @This();

main_test_step: *Step,
kernels_test_step: *Step,
libraries_test_step: *Step,

pub fn create(b: *std.Build) !StepCollection {
    const main_test_step = b.step(
        "test",
        "Run all the tests (also builds all code even if they don't have tests)",
    );

    const libraries_test_step = b.step(
        "test_libraries",
        "Run all the library tests",
    );
    main_test_step.dependOn(libraries_test_step);

    // TODO: Figure out a way to run real kernel tests
    const kernels_test_step = b.step(
        "test_kernels",
        "Run all the kernel tests (currently all this does it build the kernels)",
    );
    main_test_step.dependOn(kernels_test_step);

    return StepCollection{
        .main_test_step = main_test_step,
        .kernels_test_step = kernels_test_step,
        .libraries_test_step = libraries_test_step,
    };
}
