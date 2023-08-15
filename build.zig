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
const Tool = @import(".build/Tool.zig");

const cascade_version = std.SemanticVersion{ .major = 0, .minor = 0, .patch = 1 };
const all_targets: []const CascadeTarget = std.meta.tags(CascadeTarget);

pub fn build(b: *std.Build) !void {
    b.enable_qemu = true;

    const step_collection = try StepCollection.create(b, all_targets);

    const options = try Options.get(b, cascade_version, all_targets);

    const libraries = try Library.getLibraries(b, step_collection, options, all_targets);

    const tools = try Tool.getTools(b, step_collection, libraries);

    const kernels = try Kernel.getKernels(b, step_collection, libraries, options, all_targets);

    const image_steps = try ImageStep.registerImageSteps(b, kernels, tools, step_collection, all_targets);

    try QemuStep.registerQemuSteps(b, image_steps, options, all_targets);
}
