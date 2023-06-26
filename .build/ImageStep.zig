// SPDX-License-Identifier: MIT

const std = @import("std");
const Step = std.Build.Step;

const helpers = @import("helpers.zig");

const CascadeTarget = @import("CascadeTarget.zig").CascadeTarget;
const Kernel = @import("Kernel.zig");
const LimineStep = @import("LimineStep.zig");

const ImageStep = @This();
const StepCollection = @import("StepCollection.zig");

pub const Collection = std.AutoHashMapUnmanaged(CascadeTarget, *ImageStep);

step: Step,

target: CascadeTarget,
limine_step: *LimineStep,

image_file: std.Build.GeneratedFile,
image_file_source: std.Build.FileSource,

/// Registers image build steps.
///
/// For each target, creates a `ImageStep` and registers its step with the `StepCollection`.
pub fn registerImageSteps(
    b: *std.Build,
    step_collection: StepCollection,
    targets: []const CascadeTarget,
) !Collection {
    var image_steps: Collection = .{};
    try image_steps.ensureTotalCapacity(b.allocator, @intCast(targets.len));

    const limine_step = try LimineStep.create(b);

    for (targets) |target| {
        const image_build_step = try ImageStep.create(b, step_collection, target, limine_step);
        step_collection.registerImage(target, &image_build_step.step);
        image_steps.putAssumeCapacityNoClobber(target, image_build_step);
    }

    return image_steps;
}

fn create(
    b: *std.Build,
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
    };
    self.image_file = .{ .step = &self.step };
    self.image_file_source = .{ .generated = &self.image_file };

    self.step.dependOn(&limine_step.step);
    self.step.dependOn(step_collection.kernel_build_steps_per_target.get(target).?);
    self.step.dependOn(step_collection.cascade_library_build_steps_per_target.get(target).?);

    return self;
}

fn make(step: *Step, progress_node: *std.Progress.Node) !void {
    var node = progress_node.start(step.name, 0);
    defer node.end();

    progress_node.activate();

    const b = step.owner;
    const self = @fieldParentPtr(ImageStep, "step", step);

    var cache_manifest = b.cache.obtain();
    defer cache_manifest.deinit();

    // Build file
    _ = try cache_manifest.addFile(b.pathFromRoot("build.zig"), null);

    // Limine cache directory
    try hashDirectoryRecursive(
        b.allocator,
        self.limine_step.limine_generated_directory.getPath(),
        &cache_manifest,
    );

    // Root
    try hashDirectoryRecursive(
        b.allocator,
        helpers.pathJoinFromRoot(b, &.{
            "zig-out",
            @tagName(self.target),
            "root",
        }),
        &cache_manifest,
    );

    // Build directory
    try hashDirectoryRecursive(
        b.allocator,
        b.pathFromRoot(".build"),
        &cache_manifest,
    );

    const image_file_path = helpers.pathJoinFromRoot(b, &.{
        "zig-out",
        @tagName(self.target),
        try std.fmt.allocPrint(
            b.allocator,
            "cascade_{s}.hdd",
            .{@tagName(self.target)},
        ),
    });

    if (try step.cacheHit(&cache_manifest)) {
        self.image_file.path = image_file_path;
        self.step.result_cached = true;
        return;
    }

    try self.generateImage(image_file_path);
    self.image_file.path = image_file_path;

    try step.writeManifest(&cache_manifest);
}

/// Generates an image for the target.
fn generateImage(self: *ImageStep, image_path: []const u8) !void {
    try helpers.runExternalBinary(
        self.step.owner.allocator,
        &.{
            self.target.imageScriptPath(self.step.owner),
            image_path,
            @tagName(self.target),
            self.limine_step.limine_generated_directory.getPath(),
            self.limine_step.limine_executable_source.getPath(self.step.owner),
        },
        helpers.pathJoinFromRoot(self.step.owner, &.{".build"}),
    );
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
