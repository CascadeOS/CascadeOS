// SPDX-License-Identifier: MIT

const std = @import("std");
const Step = std.Build.Step;
const Arch = std.Target.Cpu.Arch;

pub fn build(b: *std.Build) !void {
    const step_collection = try StepCollection.create(b);
    b.default_step = step_collection.main_test_step;

    const options = try Options.get(b);

    for (supported_archs) |arch| {
        const kernel = try Kernel.create(b, arch, options);

        // Setup the build step
        {
            const build_step_name = try std.fmt.allocPrint(
                b.allocator,
                "kernel_{s}",
                .{@tagName(arch)},
            );
            const build_step_description = try std.fmt.allocPrint(
                b.allocator,
                "Build the kernel for {s}",
                .{@tagName(arch)},
            );
            const build_step = b.step(build_step_name, build_step_description);
            build_step.dependOn(&kernel.install_step.step);

            step_collection.test_steps.get(arch).?.dependOn(build_step);
        }

        const image_build = try ImageStep.create(b, arch, kernel);

        // Setup the image step
        {
            const image_step_name = try std.fmt.allocPrint(
                b.allocator,
                "image_{s}",
                .{@tagName(arch)},
            );
            const image_step_description = try std.fmt.allocPrint(
                b.allocator,
                "Build the image for {s}",
                .{@tagName(arch)},
            );
            const image_step = b.step(image_step_name, image_step_description);
            image_step.dependOn(&image_build.step);
        }

        const run_in_qemu = try QemuStep.create(b, arch, image_build.image_file_source, options);

        // Setup the qemu step
        {
            const run_in_qemu_step_name = try std.fmt.allocPrint(
                b.allocator,
                "run_{s}",
                .{@tagName(arch)},
            );
            const run_in_qemu_step_description = try std.fmt.allocPrint(
                b.allocator,
                "Run the image for {s} in qemu",
                .{@tagName(arch)},
            );
            const run_step = b.step(run_in_qemu_step_name, run_in_qemu_step_description);
            run_step.dependOn(&run_in_qemu.step);
        }
    }
}

const supported_archs: []const Arch = &.{
    Arch.x86_64,
};

const Options = struct {
    optimize: std.builtin.OptimizeMode,

    // qemu options

    /// enable qemu monitor
    qemu_monitor: bool,

    /// enable qemu remote debug
    qemu_debug: bool,

    /// disable qemu graphical display
    /// TODO: defaults to false currently, this is planned to be true by default
    no_display: bool,

    /// disable usage of KVM
    /// defaults to false, if qemu interrupt details is requested then this is *forced* to true
    no_kvm: bool,

    /// show detailed qemu interrupt details
    interrupt_details: bool,

    /// number of cores
    smp: usize,

    /// run qemu in UEFI mode
    uefi: bool,

    /// how much memory to request from qemu
    /// defaults to 256mb in UEFI mode and 128mb otherwise
    memory: usize,

    kernel_options_module: *std.Build.Module,

    pub fn get(b: *std.Build) !Options {
        const qemu_monitor = b.option(
            bool,
            "qemu_monitor",
            "Enable qemu monitor",
        ) orelse false;

        const qemu_debug = b.option(
            bool,
            "debug",
            "Enable qemu remote debug (also disables kaslr)",
        ) orelse false;

        const no_display = b.option(
            bool,
            "no_display",
            "Disable qemu graphical display (defaults to true)",
        ) orelse true;

        const interrupt_details = b.option(
            bool,
            "interrupt",
            "Show detailed qemu interrupt details (disables kvm)",
        ) orelse false;

        const uefi = b.option(
            bool,
            "uefi",
            "Run qemu in UEFI mode",
        ) orelse false;

        const smp = b.option(
            usize,
            "smp",
            "Number of cores (default 1)",
        ) orelse 1;

        if (smp == 0) {
            std.debug.print("number of cores must be greater than zero", .{});
            return error.InvalidNumberOfCoreRequested;
        }

        const no_kvm = blk: {
            if (b.option(bool, "no_kvm", "Disable usage of KVM")) |value| {
                if (value) break :blk true else {
                    if (interrupt_details) std.debug.panic("cannot enable KVM and show qemu interrupt details", .{});
                }
            }
            break :blk interrupt_details;
        };

        const memory: usize = b.option(
            usize,
            "memory",
            "How much memory (in MB) to request from qemu (defaults to 256 for UEFI and 128 otherwise)",
        ) orelse if (uefi) 256 else 128;

        // Build the kernel options module
        const kernel_options = b.addOptions();
        return .{
            .optimize = b.standardOptimizeOption(.{}),
            .qemu_monitor = qemu_monitor,
            .qemu_debug = qemu_debug,
            .no_display = no_display,
            .no_kvm = no_kvm,
            .interrupt_details = interrupt_details,
            .smp = smp,
            .uefi = uefi,
            .memory = memory,
            .kernel_options_module = kernel_options.createModule(),
        };
    }
};

const Kernel = struct {
    b: *std.Build,
    arch: Arch,
    options: Options,

    install_step: *Step.InstallArtifact,

    pub fn create(b: *std.Build, arch: Arch, options: Options) !Kernel {
        const kernel_exe = b.addExecutable(.{
            .name = "kernel",
            .root_source_file = .{
                .path = pathJoinFromRoot(b, &.{ "kernel", "kernel.zig" }),
            },
            .target = getTarget(arch),
            .optimize = options.optimize,
        });

        kernel_exe.override_dest_dir = .{
            .custom = b.pathJoin(&.{
                @tagName(arch),
                "root",
                "boot",
            }),
        };

        kernel_exe.setLinkerScriptPath(.{
            .path = pathJoinFromRoot(b, &.{
                "kernel",
                "arch",
                @tagName(arch),
                "linker.ld",
            }),
        });

        kernel_exe.addModule("kernel_options", options.kernel_options_module);

        try performTargetSpecificSetup(b, kernel_exe, arch, options);

        return Kernel{
            .b = b,
            .arch = arch,
            .options = options,
            .install_step = b.addInstallArtifact(kernel_exe),
        };
    }

    fn getTarget(arch: Arch) std.zig.CrossTarget {
        switch (arch) {
            .x86_64 => {
                const features = std.Target.x86.Feature;
                var target = std.zig.CrossTarget{
                    .cpu_arch = .x86_64,
                    .os_tag = .freestanding,
                    .abi = .none,
                    .cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64 },
                };

                // Remove all SSE/AVX features
                target.cpu_features_sub.addFeature(@enumToInt(features.x87));
                target.cpu_features_sub.addFeature(@enumToInt(features.mmx));
                target.cpu_features_sub.addFeature(@enumToInt(features.sse));
                target.cpu_features_sub.addFeature(@enumToInt(features.f16c));
                target.cpu_features_sub.addFeature(@enumToInt(features.fma));
                target.cpu_features_sub.addFeature(@enumToInt(features.sse2));
                target.cpu_features_sub.addFeature(@enumToInt(features.sse3));
                target.cpu_features_sub.addFeature(@enumToInt(features.sse4_1));
                target.cpu_features_sub.addFeature(@enumToInt(features.sse4_2));
                target.cpu_features_sub.addFeature(@enumToInt(features.ssse3));
                target.cpu_features_sub.addFeature(@enumToInt(features.vzeroupper));
                target.cpu_features_sub.addFeature(@enumToInt(features.avx));
                target.cpu_features_sub.addFeature(@enumToInt(features.avx2));
                target.cpu_features_sub.addFeature(@enumToInt(features.avx512bw));
                target.cpu_features_sub.addFeature(@enumToInt(features.avx512cd));
                target.cpu_features_sub.addFeature(@enumToInt(features.avx512dq));
                target.cpu_features_sub.addFeature(@enumToInt(features.avx512f));
                target.cpu_features_sub.addFeature(@enumToInt(features.avx512vl));

                // Add soft float
                target.cpu_features_add.addFeature(@enumToInt(features.soft_float));

                return target;
            },
            else => @panic("unsupported architecture"),
        }
    }

    fn performTargetSpecificSetup(b: *std.Build, kernel_exe: *Step.Compile, arch: Arch, options: Options) !void {
        _ = b;
        _ = options;
        switch (arch) {
            .x86_64 => {
                kernel_exe.omit_frame_pointer = false;
                kernel_exe.disable_stack_probing = true;
                kernel_exe.code_model = .kernel;
                kernel_exe.red_zone = false;
                kernel_exe.pie = true;
                // TODO: Check if this works
                kernel_exe.want_lto = false;
            },
            else => @panic("unsupported architecture"),
        }
    }
};

const StepCollection = struct {
    main_test_step: *Step,
    test_steps: std.AutoHashMapUnmanaged(Arch, *Step),

    pub fn create(b: *std.Build) !StepCollection {
        const main_test_step = b.step(
            "test",
            "Run all the tests (also builds all code even if they don't have tests)",
        );

        var test_steps = std.AutoHashMapUnmanaged(Arch, *Step){};
        errdefer test_steps.deinit(b.allocator);

        try test_steps.ensureTotalCapacity(b.allocator, supported_archs.len);
        for (supported_archs) |arch| {
            const build_step_name = try std.fmt.allocPrint(
                b.allocator,
                "test_{s}",
                .{@tagName(arch)},
            );
            const build_step_description = try std.fmt.allocPrint(
                b.allocator,
                "Run all the tests (also builds all code even if they don't have tests) for {s}",
                .{@tagName(arch)},
            );
            const build_step = b.step(build_step_name, build_step_description);
            test_steps.putAssumeCapacityNoClobber(arch, build_step);

            main_test_step.dependOn(build_step);
        }

        return StepCollection{
            .main_test_step = main_test_step,
            .test_steps = test_steps,
        };
    }
};

const ImageStep = struct {
    step: Step,

    arch: Arch,

    image_file: std.Build.GeneratedFile,
    image_file_source: std.Build.FileSource,

    pub fn create(owner: *std.Build, arch: Arch, kernel: Kernel) !*ImageStep {
        const step_name = try std.fmt.allocPrint(
            owner.allocator,
            "build {s} image",
            .{@tagName(arch)},
        );

        const self = try owner.allocator.create(ImageStep);
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = step_name,
                .owner = owner,
                .makeFn = make,
            }),
            .arch = arch,
            .image_file = undefined,
            .image_file_source = undefined,
        };
        self.image_file = .{ .step = &self.step };
        self.image_file_source = .{ .generated = &self.image_file };

        self.step.dependOn(&kernel.install_step.step);

        return self;
    }

    fn make(step: *std.Build.Step, prog_node: *std.Progress.Node) !void {
        _ = prog_node;

        const b = step.owner;
        const self = @fieldParentPtr(ImageStep, "step", step);

        var manifest = b.cache.obtain();
        defer manifest.deinit();

        // Root
        {
            const full_path = pathJoinFromRoot(b, &.{
                "zig-out",
                @tagName(self.arch),
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

        const image_file_path = try b.cache_root.join(b.allocator, &.{
            try std.fmt.allocPrint(
                b.allocator,
                "circuit_{s}.hdd",
                .{@tagName(self.arch)},
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

    fn generateImage(self: *ImageStep, image_file_path: []const u8) !void {
        switch (self.arch) {
            .x86_64 => {
                const args: []const []const u8 = &.{
                    pathJoinFromRoot(self.step.owner, &.{ ".build", "build_image_x86_64.sh" }),
                    image_file_path,
                };

                var child = std.ChildProcess.init(args, self.step.owner.allocator);
                child.cwd = pathJoinFromRoot(self.step.owner, &.{".build"});

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
            },
            else => @panic("unsupported architecture"),
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
            .Directory => {
                var new_dir = try target_dir.dir.openIterableDir(entry.name, .{});
                defer new_dir.close();
                try hashDirectoryRecursive(
                    allocator,
                    new_dir,
                    new_full_path,
                    manifest,
                );
            },
            .File => {
                _ = try manifest.addFile(new_full_path, null);
            },
            else => {},
        }
    }
}

const QemuStep = struct {
    step: std.Build.Step,
    image: std.Build.FileSource,

    arch: Arch,
    options: Options,

    pub fn create(b: *std.Build, arch: Arch, image: std.Build.FileSource, options: Options) !*QemuStep {
        const step_name = try std.fmt.allocPrint(
            b.allocator,
            "run qemu with {s} image",
            .{@tagName(arch)},
        );

        const self = try b.allocator.create(QemuStep);
        errdefer b.allocator.destroy(self);

        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = step_name,
                .owner = b,
                .makeFn = make,
            }),
            .image = image,
            .arch = arch,
            .options = options,
        };

        image.addStepDependencies(&self.step);

        return self;
    }

    fn make(step: *std.Build.Step, prog_node: *std.Progress.Node) !void {
        const b = step.owner;
        const self = @fieldParentPtr(QemuStep, "step", step);

        const qemu_executable: []const u8 = switch (self.arch) {
            .x86_64 => "qemu-system-x86_64",
            else => return step.fail("unsupported architecture {s}", .{@tagName(self.arch)}),
        };

        const run_qemu = b.addSystemCommand(&.{qemu_executable});

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
        switch (self.arch) {
            .x86_64 => {
                // we aren't going to support migration so disable it here to get invariant tsc :)
                run_qemu.addArgs(&.{ "-cpu", "max,migratable=no" });
            },
            else => return step.fail("unsupported architecture {s}", .{@tagName(self.arch)}),
        }

        // set machine
        switch (self.arch) {
            .x86_64 => {
                if (self.options.no_kvm or !fileExists("/dev/kvm")) {
                    run_qemu.addArgs(&[_][]const u8{ "-machine", "q35,accel=tcg" });
                } else {
                    run_qemu.addArgs(&[_][]const u8{ "-machine", "q35,accel=kvm" });
                    run_qemu.addArg("-enable-kvm");
                }
            },
            else => return step.fail("unsupported architecture {s}", .{@tagName(self.arch)}),
        }

        // UEFI
        if (self.options.uefi) {
            switch (self.arch) {
                .x86_64 => {
                    if (fileExists("/usr/share/ovmf/x64/OVMF.fd")) {
                        run_qemu.addArgs(&[_][]const u8{ "-bios", "/usr/share/ovmf/x64/OVMF.fd" });
                    } else if (fileExists("/usr/share/ovmf/OVMF.fd")) {
                        run_qemu.addArgs(&[_][]const u8{ "-bios", "/usr/share/ovmf/OVMF.fd" });
                    } else {
                        return step.fail("Unable to locate OVMF.fd to enable UEFI booting", .{});
                    }
                },
                else => return step.fail("unsupported architecture {s}", .{@tagName(self.arch)}),
            }
        }

        try run_qemu.step.make(prog_node);
    }
};

pub inline fn pathJoinFromRoot(b: *std.Build, paths: []const []const u8) []const u8 {
    return b.pathFromRoot(b.pathJoin(paths));
}

pub fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}
