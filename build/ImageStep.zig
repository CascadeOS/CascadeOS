// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const Step = std.Build.Step;

const helpers = @import("helpers.zig");

const CascadeTarget = @import("CascadeTarget.zig").CascadeTarget;
const Kernel = @import("Kernel.zig");
const Tool = @import("Tool.zig");

const ImageStep = @This();
const StepCollection = @import("StepCollection.zig");

pub const Collection = std.AutoHashMapUnmanaged(CascadeTarget, *ImageStep);

b: *std.Build,

step: Step,

target: CascadeTarget,
limine_dep: *std.Build.Dependency,
limine_exe: *std.Build.Step.Compile,

image_builder_tool: Tool,

image_file: std.Build.GeneratedFile,
image_lazy_path: std.Build.LazyPath,

kernel: Kernel,

/// Registers image build steps.
///
/// For each target, creates a `ImageStep` and registers its step with the `StepCollection`.
pub fn registerImageSteps(
    b: *std.Build,
    kernels: Kernel.Collection,
    tools: Tool.Collection,
    step_collection: StepCollection,
    targets: []const CascadeTarget,
) !Collection {
    const limine_dep = b.dependency("limine", .{});

    const limine_exe = b.addExecutable(.{
        .name = "limine",
        .link_libc = true,
        .target = b.host,
        .optimize = .ReleaseSafe,
    });
    limine_exe.addIncludePath(limine_dep.path(""));
    limine_exe.addCSourceFile(.{
        .file = limine_dep.path("limine.c"),
        .flags = &.{
            "-std=c99",
            "-fno-sanitize=undefined",
        },
    });

    var image_steps: Collection = .{};
    try image_steps.ensureTotalCapacity(b.allocator, @intCast(targets.len));

    const image_builder_tool = tools.get("image_builder").?;

    for (targets) |target| {
        const kernel = kernels.get(target).?;
        const image_build_step = try ImageStep.create(
            b,
            kernel,
            image_builder_tool,
            step_collection,
            target,
            limine_dep,
            limine_exe,
        );
        step_collection.registerImage(target, &image_build_step.step);
        image_steps.putAssumeCapacityNoClobber(target, image_build_step);
    }

    return image_steps;
}

fn create(
    b: *std.Build,
    kernel: Kernel,
    image_builder_tool: Tool,
    step_collection: StepCollection,
    target: CascadeTarget,
    limine_dep: *std.Build.Dependency,
    limine_exe: *std.Build.Step.Compile,
) !*ImageStep {
    const step_name = try std.fmt.allocPrint(
        b.allocator,
        "build {s} image",
        .{@tagName(target)},
    );

    const self = try b.allocator.create(ImageStep);
    self.* = .{
        .b = b,
        .kernel = kernel,
        .step = Step.init(.{
            .id = .custom,
            .name = step_name,
            .owner = b,
            .makeFn = make,
        }),
        .target = target,
        .limine_dep = limine_dep,
        .limine_exe = limine_exe,
        .image_file = undefined,
        .image_lazy_path = undefined,
        .image_builder_tool = image_builder_tool,
    };
    self.image_file = .{ .step = &self.step };
    self.image_lazy_path = .{ .generated = &self.image_file };

    limine_exe.getEmittedBin().addStepDependencies(&self.step);
    image_builder_tool.release_safe_compile_step.getEmittedBin().addStepDependencies(&self.step);

    self.step.dependOn(step_collection.kernel_build_steps_per_target.get(target).?);

    return self;
}

fn make(step: *Step, progress_node: *std.Progress.Node) !void {
    var node = progress_node.start(step.name, 0);
    defer node.end();

    progress_node.activate();

    const self: *ImageStep = @fieldParentPtr("step", step);

    // TODO: use cache system

    var timer = try std.time.Timer.start();

    const image_file_path = helpers.pathJoinFromRoot(self.b, &.{
        "zig-out",
        @tagName(self.target),
        try std.fmt.allocPrint(
            self.b.allocator,
            "cascade_{s}.hdd",
            .{@tagName(self.target)},
        ),
    });

    try self.generateImage(image_file_path, progress_node);
    self.image_file.path = image_file_path;

    step.result_duration_ns = timer.read();
}

const ImageDescription = @import("../tools/image_builder/ImageDescription.zig");

/// Generates an image for the target.
fn generateImage(self: *ImageStep, image_path: []const u8, progress_node: *std.Progress.Node) !void {
    const image_size = 256 * 1024 * 1024; // 256 MiB
    const efi_partition_size = 64 * 1024 * 1024; // 64 MiB
    _ = efi_partition_size;

    var builder = ImageDescription.Builder.create(
        self.b.allocator,
        image_path,
        image_size,
    );
    defer builder.deinit();

    const efi_partition = try builder.addPartition("EFI", 0, .fat32, .efi);

    try efi_partition.addFile(.{
        .destination_path = "/limine.cfg",
        .source_path = helpers.pathJoinFromRoot(self.b, &.{
            "build",
            "limine.cfg",
        }),
    });

    switch (self.target) {
        .x64 => {
            try efi_partition.addFile(.{
                .destination_path = "/limine-bios.sys",
                .source_path = self.limine_dep.path("limine-bios.sys").getPath2(self.b, &self.step),
            });
            try efi_partition.addFile(.{
                .destination_path = "/EFI/BOOT/BOOTX64.EFI",
                .source_path = self.limine_dep.path("BOOTX64.EFI").getPath2(self.b, &self.step),
            });
        },
    }

    try efi_partition.addFile(.{
        .destination_path = "/kernel",
        .source_path = self.kernel.final_kernel_binary_path.getPath(self.b),
    });

    {
        var image_description_buffer = std.ArrayList(u8).init(self.b.allocator);
        defer image_description_buffer.deinit();

        try builder.serialize(image_description_buffer.writer());

        const run_image_builder = self.b.addRunArtifact(self.image_builder_tool.release_safe_compile_step);
        run_image_builder.addArg("-");
        run_image_builder.has_side_effects = true;

        // TODO: This is ugly, but this is the only way to get the below `setStdIn` to work
        run_image_builder.stdio = .{ .check = std.ArrayList(Step.Run.StdIo.Check).init(self.b.allocator) };
        run_image_builder.setStdIn(.{ .bytes = image_description_buffer.items });

        try run_image_builder.step.make(progress_node);
    }

    // TODO: Make this a dependency rather than invoking directly

    const run_limine = self.b.addRunArtifact(self.limine_exe);

    run_limine.addArg("bios-install");
    run_limine.addArg(image_path);

    // TODO: This is ugly, but this is the only way to suppress stdout/stderr
    run_limine.stdio = .{ .check = std.ArrayList(Step.Run.StdIo.Check).init(self.b.allocator) };
    run_limine.has_side_effects = true;

    try run_limine.step.make(progress_node);
}

/// Recursively hashes all files in a directory and adds them to the cache_manifest.
fn hashDirectoryRecursive(
    allocator: std.mem.Allocator,
    path: []const u8,
    cache_manifest: *std.Build.Cache.Manifest,
) !void {
    var dir = try std.fs.cwd().openIterableDir(path, .{});
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const child_path = try std.fs.path.join(allocator, &.{ path, entry.name });
        defer allocator.free(child_path);
        switch (entry.kind) {
            .directory => {
                try hashDirectoryRecursive(
                    allocator,
                    child_path,
                    cache_manifest,
                );
            },
            .file => {
                _ = try cache_manifest.addFile(child_path, null);
            },
            else => {},
        }
    }
}
