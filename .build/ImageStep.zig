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

pub fn registerImageSteps(
    b: *std.Build,
    step_collection: StepCollection,
    all_targets: []const CascadeTarget,
) !Collection {
    var images: Collection = .{};
    try images.ensureTotalCapacity(b.allocator, @intCast(u32, all_targets.len));

    const limine_step = try LimineStep.create(b);

    for (all_targets) |target| {
        const image_build = try ImageStep.create(b, step_collection, target, limine_step);
        step_collection.registerImage(target, &image_build.step);
        images.putAssumeCapacityNoClobber(target, image_build);
    }

    return images;
}

fn create(
    owner: *std.Build,
    step_collection: StepCollection,
    target: CascadeTarget,
    limine_step: *LimineStep,
) !*ImageStep {
    const step_name = try std.fmt.allocPrint(
        owner.allocator,
        "build {s} image",
        .{@tagName(target)},
    );

    const self = try owner.allocator.create(ImageStep);
    self.* = .{
        .step = Step.init(.{
            .id = .custom,
            .name = step_name,
            .owner = owner,
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
    self.step.dependOn(step_collection.kernels_build_step_per_target.get(target).?);
    self.step.dependOn(step_collection.libraries_test_build_step_per_target.get(target).?);

    return self;
}

fn make(step: *Step, prog_node: *std.Progress.Node) !void {
    var node = prog_node.start(step.name, 0);
    defer node.end();

    const b = step.owner;
    const self = @fieldParentPtr(ImageStep, "step", step);

    var manifest = b.cache.obtain();
    defer manifest.deinit();

    // Limine cache directory
    {
        const limine_directory = self.limine_step.limine_directory.getPath();
        var dir = try std.fs.cwd().openIterableDir(limine_directory, .{});
        defer dir.close();
        try hashDirectoryRecursive(b.allocator, dir, limine_directory, &manifest);
    }

    // Root
    {
        const full_path = helpers.pathJoinFromRoot(b, &.{
            "zig-out",
            @tagName(self.target),
            "root",
        });
        var dir = try std.fs.cwd().openIterableDir(full_path, .{});
        defer dir.close();
        try hashDirectoryRecursive(b.allocator, dir, full_path, &manifest);
    }

    // Build file
    {
        const full_path = b.pathFromRoot("build.zig");
        _ = try manifest.addFile(full_path, null);
    }

    // Build directory
    {
        const full_path = b.pathFromRoot(".build");
        var dir = try std.fs.cwd().openIterableDir(full_path, .{});
        defer dir.close();
        try hashDirectoryRecursive(b.allocator, dir, full_path, &manifest);
    }

    const image_file_path = helpers.pathJoinFromRoot(b, &.{
        "zig-out",
        @tagName(self.target),
        try std.fmt.allocPrint(
            b.allocator,
            "cascade_{s}.hdd",
            .{@tagName(self.target)},
        ),
    });

    if (try step.cacheHit(&manifest)) {
        self.image_file.path = image_file_path;
        self.step.result_cached = true;
        return;
    }

    try self.generateImage(image_file_path);
    self.image_file.path = image_file_path;

    try step.writeManifest(&manifest);
}

fn generateImage(self: *ImageStep, image_file_path: []const u8) !void {
    const build_image_path = self.target.buildImagePath(self.step.owner);

    const args: []const []const u8 = &.{
        build_image_path,
        image_file_path,
        @tagName(self.target),
        self.limine_step.limine_directory.getPath(),
        self.limine_step.limine_deploy_source.getPath(self.step.owner),
    };

    var child = std.ChildProcess.init(args, self.step.owner.allocator);
    child.cwd = helpers.pathJoinFromRoot(self.step.owner, &.{".build"});

    try child.spawn();
    const term = try child.wait();

    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                return error.UncleanExit;
            }
        },
        else => return error.UncleanExit,
    }
}

fn hashDirectoryRecursive(
    allocator: std.mem.Allocator,
    target_dir: std.fs.IterableDir,
    directory_full_path: []const u8,
    manifest: *std.Build.Cache.Manifest,
) !void {
    var iter = target_dir.iterate();
    while (try iter.next()) |entry| {
        const new_full_path = try std.fs.path.join(allocator, &.{ directory_full_path, entry.name });
        defer allocator.free(new_full_path);
        switch (entry.kind) {
            .directory => {
                var new_dir = try target_dir.dir.openIterableDir(entry.name, .{});
                defer new_dir.close();
                try hashDirectoryRecursive(
                    allocator,
                    new_dir,
                    new_full_path,
                    manifest,
                );
            },
            .file => {
                _ = try manifest.addFile(new_full_path, null);
            },
            else => {},
        }
    }
}
