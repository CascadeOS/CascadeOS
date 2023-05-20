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
        try kernel.registerSteps(step_collection);
    }
}

const supported_archs: []const Arch = &.{
    Arch.x86_64,
};

const Options = struct {
    optimize: std.builtin.OptimizeMode,

    pub fn get(b: *std.Build) !Options {
        return .{
            .optimize = b.standardOptimizeOption(.{}),
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

        try performTargetSpecificSetup(b, kernel_exe, arch, options);

        return Kernel{
            .b = b,
            .arch = arch,
            .options = options,
            .install_step = b.addInstallArtifact(kernel_exe),
        };
    }

    pub fn registerSteps(self: Kernel, step_collection: StepCollection) !void {
        const build_step_name = try std.fmt.allocPrint(
            self.b.allocator,
            "kernel_{s}",
            .{@tagName(self.arch)},
        );
        const build_step_description = try std.fmt.allocPrint(
            self.b.allocator,
            "Build the kernel for {s}",
            .{@tagName(self.arch)},
        );
        const build_step = self.b.step(build_step_name, build_step_description);
        build_step.dependOn(&self.install_step.step);

        step_collection.test_steps.get(self.arch).?.dependOn(build_step);
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

pub inline fn pathJoinFromRoot(b: *std.Build, paths: []const []const u8) []const u8 {
    return b.pathFromRoot(b.pathJoin(paths));
}
