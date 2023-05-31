// SPDX-License-Identifier: MIT

const std = @import("std");
const Step = std.Build.Step;

const cascade_version = std.builtin.Version{ .major = 0, .minor = 0, .patch = 1 };

pub fn build(b: *std.Build) !void {
    const step_collection = try StepCollection.create(b);
    b.default_step = step_collection.main_test_step;

    const options = try Options.get(b);

    const libraries = try createLibraries(b, step_collection, options.optimize);
    const kernels = try createKernels(b, libraries, step_collection, options);
    const images = try createImageSteps(b, kernels);
    try createQemuSteps(b, images, options);
}

const all_targets: []const CascadeTarget = std.meta.tags(CascadeTarget);

pub const CascadeTarget = enum {
    aarch64,
    x86_64,

    pub fn getTestCrossTarget(self: CascadeTarget) std.zig.CrossTarget {
        switch (self) {
            .aarch64 => return std.zig.CrossTarget{
                .cpu_arch = .aarch64,
            },
            .x86_64 => return std.zig.CrossTarget{
                .cpu_arch = .x86_64,
            },
        }
    }

    pub fn isNative(self: CascadeTarget, b: *std.Build) bool {
        return switch (b.host.target.cpu.arch) {
            .aarch64 => self == .aarch64,
            .x86_64 => self == .x86_64,
            else => false,
        };
    }

    pub fn needsUefi(self: CascadeTarget) bool {
        return switch (self) {
            .aarch64 => true,
            .x86_64 => false,
        };
    }

    pub fn getCrossTarget(self: CascadeTarget) std.zig.CrossTarget {
        switch (self) {
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
            .aarch64 => {
                var target = std.zig.CrossTarget{
                    .cpu_arch = .aarch64,
                    .os_tag = .freestanding,
                    .abi = .none,
                    .cpu_model = .{ .explicit = &std.Target.aarch64.cpu.cortex_a57 }, // TODO: Add a way to specify this
                };

                // TODO: Does SIMD (neon) need to be disabled? Like on x86_64?

                return target;
            },
        }
    }

    pub fn linkerScriptPath(self: CascadeTarget, b: *std.Build) []const u8 {
        return switch (self) {
            .aarch64 => pathJoinFromRoot(b, &.{ ".build", "linker_aarch64.ld" }),
            .x86_64 => pathJoinFromRoot(b, &.{ ".build", "linker_x86_64.ld" }),
        };
    }

    pub fn buildImagePath(self: CascadeTarget, b: *std.Build) []const u8 {
        _ = self;
        return pathJoinFromRoot(b, &.{ ".build", "build_limine_image.sh" });
    }

    pub fn qemuExecutable(self: CascadeTarget) []const u8 {
        return switch (self) {
            .aarch64 => "qemu-system-aarch64",
            .x86_64 => "qemu-system-x86_64",
        };
    }

    pub fn setQemuCpu(self: CascadeTarget, run_qemu: *Step.Run) void {
        switch (self) {
            .aarch64 => run_qemu.addArgs(&[_][]const u8{ "-cpu", "cortex-a57" }), // TODO: Add a way to specify this
            .x86_64 => run_qemu.addArgs(&.{ "-cpu", "max,migratable=no" }), // `migratable=no` is required to get invariant tsc
        }
    }

    pub fn setQemuMachine(self: CascadeTarget, run_qemu: *Step.Run) void {
        switch (self) {
            .aarch64 => run_qemu.addArgs(&[_][]const u8{ "-M", "virt" }),
            .x86_64 => run_qemu.addArgs(&[_][]const u8{ "-machine", "q35" }),
        }
    }

    pub fn uefiFirmwarePath(self: CascadeTarget) ![]const u8 {
        switch (self) {
            .aarch64 => {
                if (fileExists("/usr/share/edk2/aarch64/QEMU_EFI.fd")) return "/usr/share/edk2/aarch64/QEMU_EFI.fd";
            },
            .x86_64 => {
                if (fileExists("/usr/share/ovmf/x64/OVMF.fd")) return "/usr/share/ovmf/x64/OVMF.fd";
                if (fileExists("/usr/share/ovmf/OVMF.fd")) return "/usr/share/ovmf/OVMF.fd";
            },
        }

        return error.UnableToLocateUefiFirmware;
    }

    pub fn targetSpecificSetup(self: CascadeTarget, kernel_exe: *Step.Compile) void {
        switch (self) {
            .aarch64 => {},
            .x86_64 => {
                kernel_exe.code_model = .kernel;
                kernel_exe.red_zone = false;
            },
        }
    }
};

const Options = struct {
    optimize: std.builtin.OptimizeMode,

    version: []const u8,

    // qemu options

    /// enable qemu monitor
    qemu_monitor: bool,

    /// enable qemu remote debug
    qemu_debug: bool,

    /// disable qemu graphical display
    /// TODO: Enable display by default when we have a graphical display
    no_display: bool,

    /// disable usage of KVM
    /// defaults to false, if qemu interrupt details is requested then this is *forced* to true
    no_kvm: bool,

    /// show detailed qemu interrupt details
    interrupt_details: bool,

    /// number of cores
    smp: usize,

    /// force qemu to run in UEFI mode, if the architecture supports it
    /// defaults to false, some architectures always run in UEFI mode
    uefi: bool,

    /// how much memory to request from qemu
    /// defaults to 256mb in UEFI mode and 128mb otherwise
    memory: usize,

    // kernel options

    /// force the provided log scopes to be debug (comma seperated list of wildcard scope matchers)
    scopes_to_force_debug: []const u8,

    /// force the log level of every scope to be debug in the kernel
    force_debug_log: bool,

    kernel_option_modules: std.AutoHashMapUnmanaged(CascadeTarget, *std.Build.Module),

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
            "Force qemu to run in UEFI mode if the architecture supports it",
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

        const force_debug_log = b.option(
            bool,
            "force_debug_log",
            "Force the log level of every scope to be debug in the kernel",
        ) orelse false;

        const scopes_to_force_debug = b.option(
            []const u8,
            "debug_scope",
            "Forces the provided log scopes to be debug (comma seperated list of wildcard scope matchers)",
        ) orelse "";

        const version = try getVersionString(b, cascade_version);

        return .{
            .optimize = b.standardOptimizeOption(.{}),
            .version = version,
            .qemu_monitor = qemu_monitor,
            .qemu_debug = qemu_debug,
            .no_display = no_display,
            .no_kvm = no_kvm,
            .interrupt_details = interrupt_details,
            .smp = smp,
            .uefi = uefi,
            .memory = memory,
            .force_debug_log = force_debug_log,
            .scopes_to_force_debug = scopes_to_force_debug,
            .kernel_option_modules = try buildKernelOptionModules(b, force_debug_log, scopes_to_force_debug, version),
        };
    }

    fn buildKernelOptionModules(
        b: *std.Build,
        force_debug_log: bool,
        scopes_to_force_debug: []const u8,
        version: []const u8,
    ) !std.AutoHashMapUnmanaged(CascadeTarget, *std.Build.Module) {
        var kernel_option_modules: std.AutoHashMapUnmanaged(CascadeTarget, *std.Build.Module) = .{};
        errdefer kernel_option_modules.deinit(b.allocator);

        try kernel_option_modules.ensureTotalCapacity(b.allocator, all_targets.len);

        for (all_targets) |target| {
            const kernel_options = b.addOptions();

            kernel_options.addOption([]const u8, "version", version);

            kernel_options.addOption(bool, "force_debug_log", force_debug_log);
            addStringLiteralSliceOption(kernel_options, "scopes_to_force_debug", scopes_to_force_debug);

            addTargetOptions(kernel_options, target);

            kernel_option_modules.putAssumeCapacityNoClobber(target, kernel_options.createModule());
        }

        return kernel_option_modules;
    }

    fn addStringLiteralSliceOption(options: *std.Build.OptionsStep, name: []const u8, buffer: []const u8) void {
        const out = options.contents.writer();

        out.print("pub const {}: []const []const u8 = &.{{", .{std.zig.fmtId(name)}) catch unreachable;

        var iter = std.mem.split(u8, buffer, ",");
        while (iter.next()) |value| {
            if (value.len != 0) out.print("\"{s}\",", .{value}) catch unreachable;
        }

        out.writeAll("};\n") catch unreachable;
    }

    fn addEnumType(options: *std.Build.OptionsStep, name: []const u8, comptime EnumT: type) void {
        const out = options.contents.writer();

        out.print("pub const {} = enum {{\n", .{std.zig.fmtId(name)}) catch unreachable;

        inline for (std.meta.tags(EnumT)) |tag| {
            out.print("    {s},\n", .{std.zig.fmtId(@tagName(tag))}) catch unreachable;
        }

        out.writeAll("};\n") catch unreachable;
    }

    fn addTargetOptions(options: *std.Build.OptionsStep, target: CascadeTarget) void {
        addEnumType(options, "Arch", CascadeTarget);

        const out = options.contents.writer();

        out.print("pub const arch: Arch = .{s};\n", .{std.zig.fmtId(@tagName(target))}) catch unreachable;
    }

    fn getVersionString(b: *std.Build, version: std.builtin.Version) ![]const u8 {
        const version_string = b.fmt(
            "{d}.{d}.{d}",
            .{ version.major, version.minor, version.patch },
        );

        var code: u8 = undefined;
        const git_describe_untrimmed = b.execAllowFail(&[_][]const u8{
            "git", "-C", b.build_root.path.?, "describe", "--match", "*.*.*", "--tags",
        }, &code, .Ignore) catch {
            return version_string;
        };
        const git_describe = std.mem.trim(u8, git_describe_untrimmed, " \n\r");

        switch (std.mem.count(u8, git_describe, "-")) {
            0 => {
                // Tagged release version (e.g. 0.8.0).
                if (!std.mem.eql(u8, git_describe, version_string)) {
                    std.debug.print(
                        "version '{s}' does not match Git tag '{s}'\n",
                        .{ version_string, git_describe },
                    );
                    std.process.exit(1);
                }
                return version_string;
            },
            2 => {
                // Untagged development build (e.g. 0.8.0-684-gbbe2cca1a).
                var it = std.mem.split(u8, git_describe, "-");
                const tagged_ancestor = it.next() orelse unreachable;
                const commit_height = it.next() orelse unreachable;
                const commit_id = it.next() orelse unreachable;

                const ancestor_ver = try std.builtin.Version.parse(tagged_ancestor);
                if (version.order(ancestor_ver) != .gt) {
                    std.debug.print(
                        "version '{}' must be greater than tagged ancestor '{}'\n",
                        .{ version, ancestor_ver },
                    );
                    std.process.exit(1);
                }

                // Check that the commit hash is prefixed with a 'g' (a Git convention).
                if (commit_id.len < 1 or commit_id[0] != 'g') {
                    std.debug.print("unexpected `git describe` output: {s}\n", .{git_describe});
                    return version_string;
                }

                // The version is reformatted in accordance with the https://semver.org specification.
                return b.fmt("{s}-dev.{s}+{s}", .{ version_string, commit_height, commit_id[1..] });
            },
            else => {
                std.debug.print("unexpected `git describe` output: {s}\n", .{git_describe});
                return version_string;
            },
        }
    }
};

const Kernels = std.AutoHashMapUnmanaged(CascadeTarget, Kernel);

fn createKernels(b: *std.Build, libraries: Libraries, step_collection: StepCollection, options: Options) !Kernels {
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

    pub fn create(b: *std.Build, target: CascadeTarget, libraries: Libraries, options: Options) !Kernel {
        const kernel_exe = b.addExecutable(.{
            .name = "kernel",
            .root_source_file = .{ .path = pathJoinFromRoot(b, &.{ "kernel", "root.zig" }) },
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
                .source_file = .{ .path = pathJoinFromRoot(b, &.{ "kernel", "kernel.zig" }) },
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

const StepCollection = struct {
    main_test_step: *Step,
    kernels_test_step: *Step,
    libraries_test_step: *Step,

    pub fn create(b: *std.Build) !StepCollection {
        const main_test_step = b.step(
            "test",
            "Run all the tests (also builds all code even if they don't have tests)",
        );

        const libraries_test_step = b.step(
            "test_libraries",
            "Run all the library tests",
        );
        main_test_step.dependOn(libraries_test_step);

        // TODO: Figure out a way to run real kernel tests
        const kernels_test_step = b.step(
            "test_kernels",
            "Run all the kernel tests (currently all this does it build the kernels)",
        );
        main_test_step.dependOn(kernels_test_step);

        return StepCollection{
            .main_test_step = main_test_step,
            .kernels_test_step = kernels_test_step,
            .libraries_test_step = libraries_test_step,
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
            const full_path = pathJoinFromRoot(b, &.{
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

        const image_file_path = pathJoinFromRoot(b, &.{
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
        child.cwd = pathJoinFromRoot(self.step.owner, &.{".build"});

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
        const should_use_kvm = !self.options.no_kvm and fileExists("/dev/kvm") and self.target.isNative(b);
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

pub inline fn pathJoinFromRoot(b: *std.Build, paths: []const []const u8) []const u8 {
    return b.pathFromRoot(b.pathJoin(paths));
}

pub fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

const Libraries = std.StringArrayHashMapUnmanaged(*Library);

fn createLibraries(b: *std.Build, step_collection: StepCollection, optimize: std.builtin.OptimizeMode) !Libraries {
    const library_list: []const LibraryDescription = @import("libraries/listing.zig").libraries;

    var libraries: Libraries = .{};
    try libraries.ensureTotalCapacity(b.allocator, library_list.len);

    // The library descriptions still left to resolve
    var libraries_todo = try std.ArrayListUnmanaged(LibraryDescription).initCapacity(b.allocator, library_list.len);

    // Fill the todo list with all the libraries
    libraries_todo.appendSliceAssumeCapacity(library_list);

    while (libraries_todo.items.len != 0) {
        var resolved_any_this_loop = false;

        var i: usize = 0;
        while (i < libraries_todo.items.len) {
            const description: LibraryDescription = libraries_todo.items[i];

            if (try resolveLibrary(b, description, libraries, step_collection, optimize)) |library| {
                libraries.putAssumeCapacityNoClobber(description.name, library);

                resolved_any_this_loop = true;
                _ = libraries_todo.swapRemove(i);
            } else {
                i += 1;
            }
        }

        if (!resolved_any_this_loop) {
            @panic("STUCK IN A LOOP"); // TODO: Report this better
        }
    }

    return libraries;
}

fn resolveLibrary(
    b: *std.Build,
    description: LibraryDescription,
    libraries: Libraries,
    step_collection: StepCollection,
    optimize: std.builtin.OptimizeMode,
) !?*Library {
    const library_dependencies = blk: {
        var library_dependencies = try std.ArrayList(*Library).initCapacity(b.allocator, description.dependencies.len);
        defer library_dependencies.deinit();

        for (description.dependencies) |dep| {
            if (libraries.get(dep)) |dep_library| {
                library_dependencies.appendAssumeCapacity(dep_library);
            } else {
                return null;
            }
        }

        break :blk try library_dependencies.toOwnedSlice();
    };

    const root_file = try std.fmt.allocPrint(b.allocator, "{s}.zig", .{description.name});

    const root_path = pathJoinFromRoot(b, &.{
        "libraries",
        description.name,
        root_file,
    });

    const file_source: std.Build.FileSource = .{ .path = root_path };

    const module = blk: {
        const module = b.createModule(.{
            .source_file = file_source,
        });

        try module.dependencies.put(description.name, module);

        for (library_dependencies) |library| {
            try module.dependencies.put(library.name, library.module);
        }

        break :blk module;
    };

    if (description.supported_architectures) |supported_architectures| {
        for (supported_architectures) |arch| {
            const test_exe = b.addTest(.{
                .name = description.name,
                .root_source_file = file_source,
                .optimize = optimize,
                .target = arch.getTestCrossTarget(),
            });

            for (library_dependencies) |library| {
                test_exe.addModule(library.name, library.module);
            }

            const run_test_exe = b.addRunArtifact(test_exe);
            run_test_exe.skip_foreign_checks = true;

            const run_step_name = try std.fmt.allocPrint(
                b.allocator,
                "test_{s}_{s}",
                .{ description.name, @tagName(arch) },
            );
            const run_step_description = try std.fmt.allocPrint(
                b.allocator,
                "Run the tests for {s}_{s}",
                .{ description.name, @tagName(arch) },
            );

            const run_step = b.step(run_step_name, run_step_description);
            run_step.dependOn(&run_test_exe.step);

            step_collection.libraries_test_step.dependOn(run_step);
        }
    } else {
        // Don't provide a target so that the tests are built for the host
        const test_exe = b.addTest(.{
            .name = description.name,
            .root_source_file = file_source,
            .optimize = optimize,
        });

        for (library_dependencies) |library| {
            test_exe.addModule(library.name, library.module);
        }

        const run_test_exe = b.addRunArtifact(test_exe);

        const run_step_name = try std.fmt.allocPrint(
            b.allocator,
            "test_{s}",
            .{description.name},
        );
        const run_step_description = try std.fmt.allocPrint(
            b.allocator,
            "Run the tests for {s}",
            .{description.name},
        );

        const run_step = b.step(run_step_name, run_step_description);
        run_step.dependOn(&run_test_exe.step);

        step_collection.libraries_test_step.dependOn(run_step);
    }

    var library = try b.allocator.create(Library);

    library.* = .{
        .name = description.name,
        .root_file = file_source,
        .module = module,
        .dependencies = library_dependencies,
    };

    return library;
}

const Library = struct {
    name: []const u8,
    root_file: std.Build.FileSource,
    dependencies: []const *Library,
    module: *std.Build.Module,

    pub fn getRootFilePath(library: *const Library, b: *std.Build) []const u8 {
        return library.root_file.getPath(b);
    }
};

pub const LibraryDescription = struct {
    /// The name of the library:
    ///   - used as the name of the module provided `@import("{name}");`
    ///   - used to build the root file path `libraries/{name}/{name}.zig`
    ///   - used in any build steps created for the library
    name: []const u8,

    dependencies: []const []const u8 = &.{},

    /// The list of architectures supported by the library.
    /// `null` means architecture-independent.
    supported_architectures: ?[]const CascadeTarget = null,
};
