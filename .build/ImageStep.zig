// SPDX-License-Identifier: MIT

const std = @import("std");
const Step = std.Build.Step;

const helpers = @import("helpers.zig");

const CascadeTarget = @import("CascadeTarget.zig").CascadeTarget;
const Kernel = @import("Kernel.zig");
const LimineStep = @import("LimineStep.zig");
const Tool = @import("Tool.zig");

const ImageStep = @This();
const StepCollection = @import("StepCollection.zig");

pub const Collection = std.AutoHashMapUnmanaged(CascadeTarget, *ImageStep);

b: *std.Build,

step: Step,

target: CascadeTarget,
limine_step: *LimineStep,

image_builder_tool: Tool,

image_file: std.Build.GeneratedFile,
image_file_source: std.Build.FileSource,

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
    var image_steps: Collection = .{};
    try image_steps.ensureTotalCapacity(b.allocator, @intCast(targets.len));

    const image_builder_tool = tools.get("image_builder").?;
    const limine_step = try LimineStep.create(b);

    for (targets) |target| {
        const kernel = kernels.get(target).?;
        const image_build_step = try ImageStep.create(b, kernel, image_builder_tool, step_collection, target, limine_step);
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
    limine_step: *LimineStep,
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
        .limine_step = limine_step,
        .image_file = undefined,
        .image_file_source = undefined,
        .image_builder_tool = image_builder_tool,
    };
    self.image_file = .{ .step = &self.step };
    self.image_file_source = .{ .generated = &self.image_file };

    self.step.dependOn(&limine_step.step);
    self.step.dependOn(&image_builder_tool.exe.step);
    self.step.dependOn(step_collection.kernel_build_steps_per_target.get(target).?);

    return self;
}

fn make(step: *Step, progress_node: *std.Progress.Node) !void {
    var node = progress_node.start(step.name, 0);
    defer node.end();

    progress_node.activate();

    const self = @fieldParentPtr(ImageStep, "step", step);

    // TODO: using caching somehow.

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

    // TODO: The EFI partition fills the whole image.
    const efi_partition = try builder.addPartition("EFI", 0, .fat32, .efi);

    try efi_partition.addFile(.{
        .destination_path = "/limine.cfg",
        .source_path = helpers.pathJoinFromRoot(self.b, &.{
            ".build",
            "limine.cfg",
        }),
    });

    const limine_directory = self.limine_step.limine_generated_directory.getPath();

    switch (self.target) {
        .aarch64 => {
            try efi_partition.addFile(.{
                .destination_path = "/EFI/BOOT/BOOTAA64.EFI",
                .source_path = helpers.pathJoinFromRoot(self.b, &.{
                    limine_directory,
                    "BOOTAA64.EFI",
                }),
            });
        },
        .x86_64 => {
            try efi_partition.addFile(.{
                .destination_path = "/limine-bios.sys",
                .source_path = helpers.pathJoinFromRoot(self.b, &.{
                    limine_directory,
                    "limine-bios.sys",
                }),
            });
            try efi_partition.addFile(.{
                .destination_path = "/EFI/BOOT/BOOTX64.EFI",
                .source_path = helpers.pathJoinFromRoot(self.b, &.{
                    limine_directory,
                    "BOOTX64.EFI",
                }),
            });
        },
    }

    try efi_partition.addFile(.{
        .destination_path = "/kernel",
        .source_path = self.kernel.install_step.emitted_bin.?.getPath(self.b),
    });

    const image_description_path = helpers.pathJoinFromRoot(self.b, &.{
        "zig-cache",
        "image_description",
        @tagName(self.target),
        try std.fmt.allocPrint(self.b.allocator, "{}", .{std.time.nanoTimestamp()}),
    });

    var image_description_directory = try std.fs.cwd().makeOpenPath(std.fs.path.dirname(image_description_path).?, .{});
    defer image_description_directory.close();

    const image_description = try image_description_directory.createFile(std.fs.path.basename(image_description_path), .{});
    defer image_description.close();

    var buffered_writer = std.io.bufferedWriter(image_description.writer());
    try builder.serialize(buffered_writer.writer());
    try buffered_writer.flush();

    const run_image_builder = self.b.addRunArtifact(self.image_builder_tool.exe);
    run_image_builder.addArg(image_description_path);
    run_image_builder.has_side_effects = true;

    try run_image_builder.step.make(progress_node);

    const run_limine = self.b.addRunArtifact(self.limine_step.__build_limine_executable);
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
    // TODO: Re-write this non-recursively, using a stack.

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
