// SPDX-License-Identifier: MIT

const std = @import("std");
const Step = std.Build.Step;

const CascadeTarget = @import(".build/CascadeTarget.zig").CascadeTarget;
const Library = @import(".build/Library.zig");
const Options = @import(".build/Options.zig");
const StepCollection = @import(".build/StepCollection.zig");

pub const LibraryDescription = @import(".build/LibraryDescription.zig");

const helpers = @import(".build/helpers.zig");

const cascade_version = std.builtin.Version{ .major = 0, .minor = 0, .patch = 1 };

pub fn build(b: *std.Build) !void {
    const step_collection = try StepCollection.create(b);
    b.default_step = step_collection.main_test_step;

    const options = try Options.get(b, cascade_version, all_targets);

    const libraries = try Library.getLibraries(b, step_collection, options.optimize);
    const kernels = try createKernels(b, libraries, step_collection, options);
    const images = try createImageSteps(b, kernels);
    try createQemuSteps(b, images, options);
}

const all_targets: []const CascadeTarget = std.meta.tags(CascadeTarget);

const Kernels = std.AutoHashMapUnmanaged(CascadeTarget, Kernel);

fn createKernels(b: *std.Build, libraries: Library.Collection, step_collection: StepCollection, options: Options) !Kernels {
    var kernels: Kernels = .{};
    try kernels.ensureTotalCapacity(b.allocator, all_targets.len);

    for (all_targets) |target| {
        const kernel = try Kernel.create(b, target, libraries, options);

        const build_step_name = try std.fmt.allocPrint(
            b.allocator,
            "kernel_{s}",
            .{@tagName(target)},
        );
        const build_step_description = try std.fmt.allocPrint(
            b.allocator,
            "Build the kernel for {s}",
            .{@tagName(target)},
        );

        const build_step = b.step(build_step_name, build_step_description);
        build_step.dependOn(&kernel.install_step.step);

        step_collection.kernels_test_step.dependOn(build_step);

        kernels.putAssumeCapacityNoClobber(target, kernel);
    }

    return kernels;
}

const Kernel = struct {
    b: *std.Build,

    target: CascadeTarget,
    options: Options,

    install_step: *Step.InstallArtifact,

    pub fn create(b: *std.Build, target: CascadeTarget, libraries: Library.Collection, options: Options) !Kernel {
        const kernel_exe = b.addExecutable(.{
            .name = "kernel",
            .root_source_file = .{ .path = helpers.pathJoinFromRoot(b, &.{ "kernel", "root.zig" }) },
            .target = target.getCrossTarget(),
            .optimize = options.optimize,
        });

        kernel_exe.override_dest_dir = .{
            .custom = b.pathJoin(&.{
                @tagName(target),
                "root",
                "boot",
            }),
        };

        kernel_exe.setLinkerScriptPath(.{ .path = target.linkerScriptPath(b) });

        const kernel_module = blk: {
            const kernel_module = b.createModule(.{
                .source_file = .{ .path = helpers.pathJoinFromRoot(b, &.{ "kernel", "kernel.zig" }) },
            });

            // self reference
            try kernel_module.dependencies.put("kernel", kernel_module);

            // kernel options
            try kernel_module.dependencies.put("kernel_options", options.kernel_option_modules.get(target).?);

            // dependencies
            const kernel_dependencies: []const []const u8 = @import("kernel/dependencies.zig").dependencies;
            for (kernel_dependencies) |dependency| {
                const library = libraries.get(dependency).?;
                try kernel_module.dependencies.put(library.name, library.module);
            }

            break :blk kernel_module;
        };

        kernel_exe.addModule("kernel", kernel_module);

        // TODO: Investigate whether LTO works
        kernel_exe.want_lto = false;
        kernel_exe.omit_frame_pointer = false;
        kernel_exe.disable_stack_probing = true;
        kernel_exe.pie = true;

        target.targetSpecificSetup(kernel_exe);

        return Kernel{
            .b = b,
            .target = target,
            .options = options,
            .install_step = b.addInstallArtifact(kernel_exe),
        };
    }
};

const ImageSteps = std.AutoHashMapUnmanaged(CascadeTarget, *ImageStep);

fn createImageSteps(b: *std.Build, kernels: Kernels) !ImageSteps {
    var images: ImageSteps = .{};
    try images.ensureTotalCapacity(b.allocator, all_targets.len);

    for (all_targets) |target| {
        const kernel = kernels.get(target).?;

        const image_build = try ImageStep.create(b, target, kernel);

        const image_step_name = try std.fmt.allocPrint(
            b.allocator,
            "image_{s}",
            .{@tagName(target)},
        );
        const image_step_description = try std.fmt.allocPrint(
            b.allocator,
            "Build the image for {s}",
            .{@tagName(target)},
        );

        const image_step = b.step(image_step_name, image_step_description);
        image_step.dependOn(&image_build.step);

        images.putAssumeCapacityNoClobber(target, image_build);
    }

    return images;
}

const ImageStep = struct {
    step: Step,

    target: CascadeTarget,

    image_file: std.Build.GeneratedFile,
    image_file_source: std.Build.FileSource,

    pub fn create(owner: *std.Build, target: CascadeTarget, kernel: Kernel) !*ImageStep {
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
            .image_file = undefined,
            .image_file_source = undefined,
        };
        self.image_file = .{ .step = &self.step };
        self.image_file_source = .{ .generated = &self.image_file };

        self.step.dependOn(&kernel.install_step.step);

        return self;
    }

    fn make(step: *Step, prog_node: *std.Progress.Node) !void {
        _ = prog_node;

        const b = step.owner;
        const self = @fieldParentPtr(ImageStep, "step", step);

        var manifest = b.cache.obtain();
        defer manifest.deinit();

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
            return;
        }

        try self.generateImage(image_file_path);
        self.image_file.path = image_file_path;

        try step.writeManifest(&manifest);
    }

    // TODO: Remove this lock once we have a step to handle fetching and building limine.
    var image_lock: std.Thread.Mutex = .{};

    fn generateImage(self: *ImageStep, image_file_path: []const u8) !void {
        const build_image_path = self.target.buildImagePath(self.step.owner);

        const args: []const []const u8 = &.{
            build_image_path,
            image_file_path,
            @tagName(self.target),
        };

        var child = std.ChildProcess.init(args, self.step.owner.allocator);
        child.cwd = helpers.pathJoinFromRoot(self.step.owner, &.{".build"});

        image_lock.lock();
        defer image_lock.unlock();

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
};

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

fn createQemuSteps(b: *std.Build, image_steps: ImageSteps, options: Options) !void {
    for (all_targets) |target| {
        const image_step = image_steps.get(target).?;

        const qemu_step = try QemuStep.create(b, target, image_step.image_file_source, options);

        const qemu_step_name = try std.fmt.allocPrint(
            b.allocator,
            "run_{s}",
            .{@tagName(target)},
        );
        const qemu_step_description = try std.fmt.allocPrint(
            b.allocator,
            "Run the image for {s} in qemu",
            .{@tagName(target)},
        );

        const run_step = b.step(qemu_step_name, qemu_step_description);
        run_step.dependOn(&qemu_step.step);
    }
}

const QemuStep = struct {
    step: Step,
    image: std.Build.FileSource,

    target: CascadeTarget,
    options: Options,

    pub fn create(b: *std.Build, target: CascadeTarget, image: std.Build.FileSource, options: Options) !*QemuStep {
        const step_name = try std.fmt.allocPrint(
            b.allocator,
            "run qemu with {s} image",
            .{@tagName(target)},
        );

        const self = try b.allocator.create(QemuStep);
        errdefer b.allocator.destroy(self);

        self.* = .{
            .step = Step.init(.{
                .id = .custom,
                .name = step_name,
                .owner = b,
                .makeFn = make,
            }),
            .image = image,
            .target = target,
            .options = options,
        };

        image.addStepDependencies(&self.step);

        return self;
    }

    fn make(step: *Step, prog_node: *std.Progress.Node) !void {
        const b = step.owner;
        const self = @fieldParentPtr(QemuStep, "step", step);

        const run_qemu = b.addSystemCommand(&.{self.target.qemuExecutable()});

        run_qemu.has_side_effects = true;
        run_qemu.stdio = .inherit;

        // no reboot
        run_qemu.addArg("-no-reboot");

        // RAM
        run_qemu.addArgs(&.{
            "-m",
            try std.fmt.allocPrint(b.allocator, "{d}", .{self.options.memory}),
        });

        // boot disk
        run_qemu.addArgs(&.{
            "-drive",
            try std.fmt.allocPrint(
                b.allocator,
                "file={s},format=raw,if=virtio",
                .{self.image.getPath(b)},
            ),
        });

        // multicore
        run_qemu.addArgs(&.{
            "-smp",
            try std.fmt.allocPrint(
                b.allocator,
                "{d}",
                .{self.options.smp},
            ),
        });

        // interrupt details
        if (self.options.interrupt_details) {
            run_qemu.addArgs(&[_][]const u8{ "-d", "int" });
        }

        // qemu monitor
        if (self.options.qemu_monitor) {
            run_qemu.addArgs(&[_][]const u8{ "-serial", "mon:stdio" });
        } else {
            run_qemu.addArgs(&[_][]const u8{ "-serial", "stdio" });
        }

        // gdb debug
        if (self.options.qemu_debug) {
            run_qemu.addArgs(&[_][]const u8{ "-s", "-S" });
        }

        // no display
        if (self.options.no_display) {
            run_qemu.addArgs(&[_][]const u8{ "-display", "none" });
        }

        // set target cpu
        self.target.setQemuCpu(run_qemu);

        // set target machine
        self.target.setQemuMachine(run_qemu);

        // KVM
        const should_use_kvm = !self.options.no_kvm and helpers.fileExists("/dev/kvm") and self.target.isNative(b);
        if (should_use_kvm) {
            run_qemu.addArg("-enable-kvm");
        }

        // UEFI
        if (self.options.uefi or self.target.needsUefi()) {
            const uefi_firmware_path = self.target.uefiFirmwarePath() catch {
                return step.fail("unable to locate UEFI firmware for target {}", .{self.target});
            };
            run_qemu.addArgs(&[_][]const u8{ "-bios", uefi_firmware_path });
        }

        try run_qemu.step.make(prog_node);
    }
};
