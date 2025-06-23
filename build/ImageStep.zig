// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub const Collection = std.AutoHashMapUnmanaged(CascadeTarget, *ImageStep);

const ImageStep = @This();

step: Step,

install_image: *std.Build.Step.InstallFile,
generated_image_file: std.Build.GeneratedFile,
image_file: std.Build.LazyPath,

/// Registers image build steps.
///
/// For each target, creates a `ImageStep` and registers its step with the `StepCollection`.
pub fn registerImageSteps(
    b: *std.Build,
    kernels: Kernel.Collection,
    tools: Tool.Collection,
    step_collection: StepCollection,
    options: Options,
    targets: []const CascadeTarget,
) !Collection {
    const image_builder_tool = tools.get("image_builder").?;
    const image_builder_compile_step = image_builder_tool.release_safe_exe;

    const limine_dep = b.dependency("limine", .{});

    var image_steps: Collection = .{};
    try image_steps.ensureTotalCapacity(b.allocator, @intCast(targets.len));

    for (targets) |target| {
        const image_file_name = try std.fmt.allocPrint(
            b.allocator,
            "cascade_{s}.hdd",
            .{@tagName(target)},
        );

        const kernel = kernels.get(target).?;

        const image_description_step = try ImageDescriptionStep.create(
            b,
            kernel,
            target,
            limine_dep,
            options.no_kaslr,
        );

        const image_build_step = b.addRunArtifact(image_builder_compile_step);
        image_build_step.addFileArg(image_description_step.image_description_file);
        const raw_image = image_build_step.addOutputFileArg(image_file_name);

        const image = if (target == .x64) image: {
            const limine_install_tool = tools.get("limine_install").?;

            const install_limine = b.addRunArtifact(limine_install_tool.release_safe_exe);

            install_limine.addArg("-i");
            install_limine.addFileArg(raw_image);

            install_limine.addArg("-o");
            break :image install_limine.addOutputFileArg(image_file_name);
        } else raw_image;

        const install_image = b.addInstallFile(
            image,
            b.pathJoin(&.{ @tagName(target), image_file_name }),
        );

        const step_name = try std.fmt.allocPrint(
            b.allocator,
            "build {s} image",
            .{@tagName(target)},
        );

        const image_step = try b.allocator.create(ImageStep);
        image_step.* = .{
            .install_image = install_image,
            .step = Step.init(.{
                .id = .custom,
                .name = step_name,
                .owner = b,
                .makeFn = makeImage,
            }),
            .generated_image_file = .{ .step = &image_step.step },
            .image_file = .{ .generated = .{ .file = &image_step.generated_image_file } },
        };
        image_step.step.dependOn(&install_image.step);

        step_collection.registerImage(target, &install_image.step);
        image_steps.putAssumeCapacityNoClobber(target, image_step);
    }

    return image_steps;
}

fn makeImage(step: *Step, options: Step.MakeOptions) !void {
    _ = options;

    const image_step: *ImageStep = @fieldParentPtr("step", step);
    image_step.generated_image_file.path = step.owner.getInstallPath(
        image_step.install_image.dir,
        image_step.install_image.dest_rel_path,
    );
}

const ImageDescriptionStep = struct {
    b: *std.Build,
    step: std.Build.Step,

    target: CascadeTarget,
    limine_conf: []const u8,

    generated_image_description_file: std.Build.GeneratedFile,
    image_description_file: std.Build.LazyPath,

    kernel: Kernel,
    limine_dep: *std.Build.Dependency,

    fn create(
        b: *std.Build,
        kernel: Kernel,
        target: CascadeTarget,
        limine_dep: *std.Build.Dependency,
        disable_kaslr: bool,
    ) !*ImageDescriptionStep {
        const step_name = try std.fmt.allocPrint(
            b.allocator,
            "build image description for {s} image",
            .{@tagName(target)},
        );

        // TODO: handling of limine.conf should be better that this, we don't even add it as a dependency...
        const limine_conf = switch (target) {
            .arm => if (disable_kaslr)
                b.pathJoin(&.{ "build", "limine_no_kaslr_ramfb.conf" })
            else
                b.pathJoin(&.{ "build", "limine_ramfb.conf" }),
            else => if (disable_kaslr)
                b.pathJoin(&.{ "build", "limine_no_kaslr.conf" })
            else
                b.pathJoin(&.{ "build", "limine.conf" }),
        };

        const image_description_step = try b.allocator.create(ImageDescriptionStep);
        image_description_step.* = .{
            .b = b,
            .kernel = kernel,
            .limine_dep = limine_dep,
            .limine_conf = limine_conf,
            .step = Step.init(.{
                .id = .custom,
                .name = step_name,
                .owner = b,
                .makeFn = make,
            }),
            .target = target,
            .generated_image_description_file = .{ .step = &image_description_step.step },
            .image_description_file = .{
                .generated = .{
                    .file = &image_description_step.generated_image_description_file,
                },
            },
        };

        try image_description_step.step.addWatchInput(b.path(limine_conf));
        image_description_step.step.dependOn(kernel.install_kernel_binaries);

        return image_description_step;
    }

    fn make(step: *Step, options: Step.MakeOptions) !void {
        const image_description_step: *ImageDescriptionStep = @fieldParentPtr("step", step);

        var timer = try std.time.Timer.start();

        const child_node = options.progress_node.start("generate image_description.json", 1);

        defer {
            child_node.end();
            step.result_duration_ns = timer.read();
        }

        const image_description = try image_description_step.buildImageDescription();

        const basename = "image_description.json";

        // Hash contents to file name.
        var hash = image_description_step.b.graph.cache.hash;
        // Random bytes to make unique. Refresh this with new random bytes when
        // implementation is modified in a non-backwards-compatible way.
        hash.add(@as(u32, 0xde92a821));
        hash.addBytes(image_description.items);
        const sub_path =
            "cascade" ++ std.fs.path.sep_str ++
            "idesc" ++ std.fs.path.sep_str ++
            hash.final() ++ std.fs.path.sep_str ++
            basename;

        image_description_step.generated_image_description_file.path = try image_description_step.b.cache_root.join(
            image_description_step.b.allocator,
            &.{sub_path},
        );

        // Optimize for the hot path. Stat the file, and if it already exists,
        // cache hit.
        if (image_description_step.b.cache_root.handle.access(sub_path, .{})) |_| {
            // This is the hot path, success.
            step.result_cached = true;
            return;
        } else |outer_err| switch (outer_err) {
            error.FileNotFound => {
                const sub_dirname = std.fs.path.dirname(sub_path).?;
                image_description_step.b.cache_root.handle.makePath(sub_dirname) catch |e| {
                    return step.fail("unable to make path '{}{s}': {s}", .{
                        image_description_step.b.cache_root, sub_dirname, @errorName(e),
                    });
                };

                const rand_int = std.crypto.random.int(u64);
                const tmp_sub_path = "tmp" ++ std.fs.path.sep_str ++
                    std.Build.hex64(rand_int) ++ std.fs.path.sep_str ++
                    basename;
                const tmp_sub_path_dirname = std.fs.path.dirname(tmp_sub_path).?;

                image_description_step.b.cache_root.handle.makePath(tmp_sub_path_dirname) catch |err| {
                    return step.fail("unable to make temporary directory '{}{s}': {s}", .{
                        image_description_step.b.cache_root, tmp_sub_path_dirname, @errorName(err),
                    });
                };

                image_description_step.b.cache_root.handle.writeFile(
                    .{ .sub_path = tmp_sub_path, .data = image_description.items },
                ) catch |err| {
                    return step.fail("unable to write options to '{}{s}': {s}", .{
                        image_description_step.b.cache_root, tmp_sub_path, @errorName(err),
                    });
                };

                image_description_step.b.cache_root.handle.rename(tmp_sub_path, sub_path) catch |err| switch (err) {
                    error.PathAlreadyExists => {
                        // Other process beat us to it. Clean up the temp file.
                        image_description_step.b.cache_root.handle.deleteFile(tmp_sub_path) catch |e| {
                            try step.addError("warning: unable to delete temp file '{}{s}': {s}", .{
                                image_description_step.b.cache_root, tmp_sub_path, @errorName(e),
                            });
                        };
                        step.result_cached = true;
                        return;
                    },
                    else => {
                        return step.fail("unable to rename options from '{}{s}' to '{}{s}': {s}", .{
                            image_description_step.b.cache_root, tmp_sub_path,
                            image_description_step.b.cache_root, sub_path,
                            @errorName(err),
                        });
                    },
                };
            },
            else => |e| return step.fail("unable to access options file '{}{s}': {s}", .{
                image_description_step.b.cache_root, sub_path, @errorName(e),
            }),
        }
    }

    const ImageDescription = @import("../tool/image_builder/ImageDescription.zig");

    fn buildImageDescription(image_description_step: *ImageDescriptionStep) !std.ArrayList(u8) {
        const image_size = 256 * 1024 * 1024; // 256 MiB
        const efi_partition_size = 64 * 1024 * 1024; // 64 MiB
        _ = efi_partition_size;

        var builder = ImageDescription.Builder.create(
            image_description_step.b.allocator,
            image_size,
        );
        defer builder.deinit();

        const efi_partition = try builder.addPartition("EFI", 0, .fat32, .efi);

        try efi_partition.addFile(.{
            .destination_path = "/limine.conf",
            .source_path = image_description_step.limine_conf,
        });

        switch (image_description_step.target) {
            .arm => {
                try efi_partition.addFile(.{
                    .destination_path = "/EFI/BOOT/BOOTAA64.EFI",
                    .source_path = image_description_step.limine_dep.path("BOOTAA64.EFI").getPath2(
                        image_description_step.b,
                        &image_description_step.step,
                    ),
                });
            },
            .riscv => {
                try efi_partition.addFile(.{
                    .destination_path = "/EFI/BOOT/BOOTRISCV64.EFI",
                    .source_path = image_description_step.limine_dep.path("BOOTRISCV64.EFI").getPath2(
                        image_description_step.b,
                        &image_description_step.step,
                    ),
                });
            },
            .x64 => {
                try efi_partition.addFile(.{
                    .destination_path = "/limine-bios.sys",
                    .source_path = image_description_step.limine_dep.path("limine-bios.sys").getPath2(
                        image_description_step.b,
                        &image_description_step.step,
                    ),
                });
                try efi_partition.addFile(.{
                    .destination_path = "/EFI/BOOT/BOOTX64.EFI",
                    .source_path = image_description_step.limine_dep.path("BOOTX64.EFI").getPath2(
                        image_description_step.b,
                        &image_description_step.step,
                    ),
                });
            },
        }

        try efi_partition.addFile(.{
            .destination_path = "/kernel",
            .source_path = image_description_step.kernel.final_kernel_binary_path.getPath(
                image_description_step.b,
            ),
        });

        var image_description_buffer = std.ArrayList(u8).init(image_description_step.b.allocator);
        errdefer image_description_buffer.deinit();

        try builder.serialize(image_description_buffer.writer());

        return image_description_buffer;
    }
};

const std = @import("std");
const Step = std.Build.Step;

const CascadeTarget = @import("CascadeTarget.zig").CascadeTarget;
const Kernel = @import("Kernel.zig");
const Tool = @import("Tool.zig");
const StepCollection = @import("StepCollection.zig");
const Options = @import("Options.zig");
