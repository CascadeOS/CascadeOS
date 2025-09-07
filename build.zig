// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const Step = std.Build.Step;

const build_zig_zon = @import("build.zig.zon");

const CascadeTarget = @import("build/CascadeTarget.zig").CascadeTarget;
const ImageStep = @import("build/ImageStep.zig");
const Kernel = @import("build/Kernel.zig");
const Library = @import("build/Library.zig");
const Options = @import("build/Options.zig");
const qemu = @import("build/qemu.zig");
const StepCollection = @import("build/StepCollection.zig");
const Tool = @import("build/Tool.zig");

pub fn build(b: *std.Build) !void {
    try disableUnsupportedSteps(b);

    b.enable_qemu = true;

    const all_architectures: []const CascadeTarget.Architecture = std.meta.tags(CascadeTarget.Architecture);

    const step_collection = try StepCollection.create(b, all_architectures);

    const options = try Options.get(b, cascade_version, all_architectures);

    const libraries = try Library.getLibraries(
        b,
        step_collection,
        options,
        all_architectures,
    );

    const tools = try Tool.getTools(
        b,
        step_collection,
        libraries,
        options.optimize,
    );

    const kernels = try Kernel.getKernels(
        b,
        step_collection,
        libraries,
        tools,
        options,
        all_architectures,
    );

    const image_steps = try ImageStep.registerImageSteps(
        b,
        kernels,
        tools,
        step_collection,
        options,
        all_architectures,
    );

    try qemu.registerQemuSteps(
        b,
        image_steps,
        tools,
        options,
        all_architectures,
    );
}

fn disableUnsupportedSteps(b: *std.Build) !void {
    const installMakeFn = struct {
        fn installMakeFn(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
            _ = step;
            _ = options;
            std.debug.print(
                "the 'install' step is not supported, to list available build targets run: 'zig build -l'\n",
                .{},
            );
            std.process.exit(1);
        }
    }.installMakeFn;

    b.install_tls.description = "This step is not supported by CascadeOS";
    b.install_tls.step.makeFn = &installMakeFn;

    const uninstallMakeFn = struct {
        fn uninstallMakeFn(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
            _ = step;
            _ = options;
            std.debug.print(
                "the 'uninstall' step is not supported, to list available build targets run: 'zig build -l'\n",
                .{},
            );
            std.process.exit(1);
        }
    }.uninstallMakeFn;

    b.uninstall_tls.description = "This step is not supported by CascadeOS";
    b.uninstall_tls.step.makeFn = &uninstallMakeFn;

    const defaultMakeFn = struct {
        fn defaultMakeFn(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
            _ = step;
            _ = options;
            std.debug.print(
                "no build target given, to list available build targets run: 'zig build -l'\n",
                .{},
            );
            std.process.exit(1);
        }
    }.defaultMakeFn;

    b.default_step = try b.allocator.create(std.Build.Step);
    b.default_step.* = std.Build.Step.init(.{
        .id = .custom,
        .makeFn = &defaultMakeFn,
        .name = "default step",
        .owner = b,
    });
}

const cascade_version = std.SemanticVersion.parse(build_zig_zon.version) catch unreachable;

comptime {
    const current_zig = @import("builtin").zig_version;
    const min_zig = std.SemanticVersion.parse(build_zig_zon.minimum_zig_version) catch unreachable;
    if (current_zig.order(min_zig) == .lt) {
        @compileError(std.fmt.comptimePrint(
            "Your Zig version {} does not meet the minimum build requirement of {}",
            .{ current_zig, min_zig },
        ));
    }
}
