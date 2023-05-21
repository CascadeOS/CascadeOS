// SPDX-License-Identifier: MIT

const std = @import("std");
const Step = std.Build.Step;

pub fn build(b: *std.Build) !void {
    const step_collection = try StepCollection.create(b);
    b.default_step = step_collection.main_test_step;

    const options = try Options.get(b);

    for (supported_targets) |target| {
        const target_name = try target.name(b.allocator);

        const kernel = try Kernel.create(b, target, options);

        // Setup the build step
        {
            const build_step_name = try std.fmt.allocPrint(
                b.allocator,
                "kernel_{s}",
                .{target_name},
            );
            const build_step_description = try std.fmt.allocPrint(
                b.allocator,
                "Build the kernel for {s}",
                .{target_name},
            );
            const build_step = b.step(build_step_name, build_step_description);
            build_step.dependOn(&kernel.install_step.step);

            step_collection.test_steps.get(target).?.dependOn(build_step);
        }

        const image_build = try ImageStep.create(b, target, kernel);

        // Setup the image step
        {
            const image_step_name = try std.fmt.allocPrint(
                b.allocator,
                "image_{s}",
                .{target_name},
            );
            const image_step_description = try std.fmt.allocPrint(
                b.allocator,
                "Build the image for {s}",
                .{target_name},
            );
            const image_step = b.step(image_step_name, image_step_description);
            image_step.dependOn(&image_build.step);
        }

        const run_in_qemu = try QemuStep.create(b, target, image_build.image_file_source, options);

        // Setup the qemu step
        {
            const run_in_qemu_step_name = try std.fmt.allocPrint(
                b.allocator,
                "run_{s}",
                .{target_name},
            );
            const run_in_qemu_step_description = try std.fmt.allocPrint(
                b.allocator,
                "Run the image for {s} in qemu",
                .{target_name},
            );
            const run_step = b.step(run_in_qemu_step_name, run_in_qemu_step_description);
            run_step.dependOn(&run_in_qemu.step);
        }
    }
}

const supported_targets: []const CircuitTarget = &.{
    .{ .arch = .aarch64, .board = .virt },
    .{ .arch = .x86_64 },
};

pub const CircuitTarget = struct {
    arch: Arch,
    board: ?Board = null,

    pub const Arch = enum {
        aarch64,
        x86_64,
    };

    pub const Board = enum {
        virt,
    };

    pub fn name(self: CircuitTarget, allocator: std.mem.Allocator) ![]const u8 {
        return if (self.board) |board|
            try std.fmt.allocPrint(allocator, "{s}_{s}", .{ @tagName(self.arch), @tagName(board) })
        else
            try std.fmt.allocPrint(allocator, "{s}", .{@tagName(self.arch)});
    }

    pub fn isNative(self: CircuitTarget) bool {
        return switch (@import("builtin").target.cpu.arch) {
            .aarch64 => self.arch == .aarch64,
            .x86_64 => self.arch == .x86_64,
            else => false,
        };
    }

    pub fn needsUefi(self: CircuitTarget) bool {
        return switch (self.arch) {
            .aarch64 => true,
            .x86_64 => false,
        };
    }

    pub fn getCrossTarget(self: CircuitTarget) std.zig.CrossTarget {
        switch (self.arch) {
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
            .aarch64 => switch (self.board.?) {
                .virt => {
                    var target = std.zig.CrossTarget{
                        .cpu_arch = .aarch64,
                        .os_tag = .freestanding,
                        .abi = .none,
                        .cpu_model = .{ .explicit = &std.Target.aarch64.cpu.cortex_a57 },
                    };

                    // TODO: I don't know enough about aarch64 to know how to disable SIMD instructions

                    return target;
                },
            },
        }
    }

    pub fn linkerScriptPath(self: CircuitTarget, b: *std.Build) []const u8 {
        return switch (self.arch) {
            .aarch64 => switch (self.board.?) {
                .virt => pathJoinFromRoot(b, &.{ ".build", "linker_aarch64_virt.ld" }),
            },
            .x86_64 => pathJoinFromRoot(b, &.{ ".build", "linker_x86_64.ld" }),
        };
    }

    pub fn buildImagePath(self: CircuitTarget, b: *std.Build) []const u8 {
        _ = self;
        return pathJoinFromRoot(b, &.{ ".build", "build_limine_image.sh" });
    }

    pub fn qemuExecutable(self: CircuitTarget) []const u8 {
        return switch (self.arch) {
            .aarch64 => "qemu-system-aarch64",
            .x86_64 => "qemu-system-x86_64",
        };
    }

    pub fn setQemuCpu(self: CircuitTarget, run_qemu: *std.Build.Step.Run) void {
        switch (self.arch) {
            .aarch64 => switch (self.board.?) {
                .virt => run_qemu.addArgs(&[_][]const u8{ "-cpu", "cortex-a57" }),
            },
            .x86_64 => run_qemu.addArgs(&.{ "-cpu", "max,migratable=no" }), // `migratable=no` is required to get invariant tsc
        }
    }

    pub fn setQemuMachine(self: CircuitTarget, run_qemu: *std.Build.Step.Run) void {
        switch (self.arch) {
            .aarch64 => switch (self.board.?) {
                .virt => run_qemu.addArgs(&[_][]const u8{ "-M", "virt" }),
            },
            .x86_64 => run_qemu.addArgs(&[_][]const u8{ "-machine", "q35" }),
        }
    }

    pub fn uefiFirmwarePath(self: CircuitTarget) ![]const u8 {
        switch (self.arch) {
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

    pub fn targetSpecificSetup(self: CircuitTarget, kernel_exe: *std.Build.Step.Compile) void {
        switch (self.arch) {
            .aarch64 => {
                kernel_exe.omit_frame_pointer = false;
                kernel_exe.disable_stack_probing = true;
                kernel_exe.pie = true;
                // TODO: Check if this works
                kernel_exe.want_lto = false;
            },
            .x86_64 => {
                kernel_exe.omit_frame_pointer = false;
                kernel_exe.disable_stack_probing = true;
                kernel_exe.code_model = .kernel;
                kernel_exe.red_zone = false;
                kernel_exe.pie = true;
                // TODO: Check if this works
                kernel_exe.want_lto = false;
            },
        }
    }
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

    kernel_option_modules: std.AutoHashMapUnmanaged(CircuitTarget, *std.Build.Module),

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
            .force_debug_log = force_debug_log,
            .scopes_to_force_debug = scopes_to_force_debug,
            .kernel_option_modules = try buildKernelOptionModules(b, force_debug_log, scopes_to_force_debug),
        };
    }

    fn buildKernelOptionModules(
        b: *std.Build,
        force_debug_log: bool,
        scopes_to_force_debug: []const u8,
    ) !std.AutoHashMapUnmanaged(CircuitTarget, *std.Build.Module) {
        var kernel_option_modules: std.AutoHashMapUnmanaged(CircuitTarget, *std.Build.Module) = .{};
        errdefer kernel_option_modules.deinit(b.allocator);

        try kernel_option_modules.ensureTotalCapacity(b.allocator, supported_targets.len);

        for (supported_targets) |target| {
            const kernel_options = b.addOptions();
            kernel_options.addOption(bool, "force_debug_log", force_debug_log);
            addStringLiteralSliceOption(kernel_options, "scopes_to_force_debug", scopes_to_force_debug);

            addArchOption(kernel_options, target.arch);
            addBoardOption(kernel_options, target.board);

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

    // std.Target.Cpu.Arch

    fn addEnumType(options: *std.Build.OptionsStep, name: []const u8, comptime EnumT: type) void {
        const out = options.contents.writer();

        out.print("pub const {} = enum {{\n", .{std.zig.fmtId(name)}) catch unreachable;

        inline for (std.meta.tags(EnumT)) |tag| {
            out.print("    {s},\n", .{std.zig.fmtId(@tagName(tag))}) catch unreachable;
        }

        out.writeAll("};\n") catch unreachable;
    }

    fn addArchOption(options: *std.Build.OptionsStep, arch: CircuitTarget.Arch) void {
        addEnumType(options, "Arch", CircuitTarget.Arch);

        const out = options.contents.writer();

        out.print("pub const arch: Arch = .{s};\n", .{std.zig.fmtId(@tagName(arch))}) catch unreachable;
    }

    fn addBoardOption(options: *std.Build.OptionsStep, optional_board: ?CircuitTarget.Board) void {
        addEnumType(options, "Board", CircuitTarget.Board);

        const out = options.contents.writer();

        if (optional_board) |board| {
            out.print("pub const board: ?Board = .{s};\n", .{std.zig.fmtId(@tagName(board))}) catch unreachable;
        } else {
            out.writeAll("pub const board: ?Board = null;\n") catch unreachable;
        }
    }
};

const Kernel = struct {
    b: *std.Build,

    target: CircuitTarget,
    options: Options,

    install_step: *Step.InstallArtifact,

    pub fn create(b: *std.Build, target: CircuitTarget, options: Options) !Kernel {
        const kernel_exe = b.addExecutable(.{
            .name = "kernel",
            .root_source_file = .{
                .path = pathJoinFromRoot(b, &.{ "kernel", "kernel.zig" }),
            },
            .target = target.getCrossTarget(),
            .optimize = options.optimize,
        });

        const target_name = try target.name(b.allocator);

        kernel_exe.override_dest_dir = .{
            .custom = b.pathJoin(&.{
                target_name,
                "root",
                "boot",
            }),
        };

        kernel_exe.setLinkerScriptPath(.{ .path = target.linkerScriptPath(b) });

        kernel_exe.addModule("kernel_options", options.kernel_option_modules.get(target).?);

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
    test_steps: std.AutoHashMapUnmanaged(CircuitTarget, *Step),

    pub fn create(b: *std.Build) !StepCollection {
        const main_test_step = b.step(
            "test",
            "Run all the tests (also builds all code even if they don't have tests)",
        );

        var test_steps = std.AutoHashMapUnmanaged(CircuitTarget, *Step){};
        errdefer test_steps.deinit(b.allocator);

        try test_steps.ensureTotalCapacity(b.allocator, supported_targets.len);
        for (supported_targets) |target| {
            const target_name = try target.name(b.allocator);

            const build_step_name = try std.fmt.allocPrint(
                b.allocator,
                "test_{s}",
                .{target_name},
            );
            const build_step_description = try std.fmt.allocPrint(
                b.allocator,
                "Run all the tests (also builds all code even if they don't have tests) for {s}",
                .{target_name},
            );
            const build_step = b.step(build_step_name, build_step_description);
            test_steps.putAssumeCapacityNoClobber(target, build_step);

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

    target: CircuitTarget,

    image_file: std.Build.GeneratedFile,
    image_file_source: std.Build.FileSource,

    pub fn create(owner: *std.Build, target: CircuitTarget, kernel: Kernel) !*ImageStep {
        const target_name = try target.name(owner.allocator);

        const step_name = try std.fmt.allocPrint(
            owner.allocator,
            "build {s} image",
            .{target_name},
        );

        const self = try owner.allocator.create(ImageStep);
        self.* = .{
            .step = std.Build.Step.init(.{
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

    fn make(step: *std.Build.Step, prog_node: *std.Progress.Node) !void {
        _ = prog_node;

        const b = step.owner;
        const self = @fieldParentPtr(ImageStep, "step", step);

        var manifest = b.cache.obtain();
        defer manifest.deinit();

        const target_name = try self.target.name(b.allocator);

        // Root
        {
            const full_path = pathJoinFromRoot(b, &.{
                "zig-out",
                target_name,
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
                .{target_name},
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
        const build_image_path = self.target.buildImagePath(self.step.owner);
        const target_name = try self.target.name(self.step.owner.allocator);

        const args: []const []const u8 = &.{
            build_image_path,
            image_file_path,
            target_name,
            @tagName(self.target.arch),
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

    target: CircuitTarget,
    options: Options,

    pub fn create(b: *std.Build, target: CircuitTarget, image: std.Build.FileSource, options: Options) !*QemuStep {
        const target_name = try target.name(b.allocator);

        const step_name = try std.fmt.allocPrint(
            b.allocator,
            "run qemu with {s} image",
            .{target_name},
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
            .target = target,
            .options = options,
        };

        image.addStepDependencies(&self.step);

        return self;
    }

    fn make(step: *std.Build.Step, prog_node: *std.Progress.Node) !void {
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
        const should_use_kvm = !self.options.no_kvm and fileExists("/dev/kvm") and self.target.isNative();
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
