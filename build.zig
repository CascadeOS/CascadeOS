// SPDX-License-Identifier: MIT

const std = @import("std");
const Step = std.Build.Step;

const CascadeTarget = @import(".build/CascadeTarget.zig").CascadeTarget;
const ImageStep = @import(".build/ImageStep.zig");
const Kernel = @import(".build/Kernel.zig");
const Library = @import(".build/Library.zig");
const Options = @import(".build/Options.zig");
const QemuStep = @import(".build/QemuStep.zig");
const StepCollection = @import(".build/StepCollection.zig");

const cascade_version = std.builtin.Version{ .major = 0, .minor = 0, .patch = 1 };
const all_targets: []const CascadeTarget = std.meta.tags(CascadeTarget);

pub fn build(b: *std.Build) !void {
    const step_collection = try StepCollection.create(b);
    b.default_step = step_collection.main_test_step;

    const options = try Options.get(b, cascade_version, all_targets);

    const libraries = try Library.getLibraries(b, step_collection, options.optimize);
    const kernels = try Kernel.getKernels(b, libraries, step_collection, options, all_targets);
    const image_steps = try ImageStep.getImageSteps(b, kernels, all_targets);
    _ = try QemuStep.getQemuSteps(b, image_steps, options, all_targets);
}
