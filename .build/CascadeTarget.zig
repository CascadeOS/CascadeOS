// SPDX-License-Identifier: MIT

const std = @import("std");
const Step = std.Build.Step;

const helpers = @import("helpers.zig");

pub const CascadeTarget = enum {
    aarch64,
    x86_64,

    pub fn getNonCascadeTestCrossTarget(self: CascadeTarget) std.zig.CrossTarget {
        switch (self) {
            .aarch64 => return std.zig.CrossTarget{
                .cpu_arch = .aarch64,
            },
            .x86_64 => return std.zig.CrossTarget{
                .cpu_arch = .x86_64,
            },
        }
    }

    pub fn getCascadeTestCrossTarget(self: CascadeTarget) std.zig.CrossTarget {
        // TODO: os_tag should be other
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
            .aarch64 => {
                const features = std.Target.aarch64.Feature;
                var target = std.zig.CrossTarget{
                    .cpu_arch = .aarch64,
                    .os_tag = .freestanding,
                    .abi = .none,
                    .cpu_model = .{ .explicit = &std.Target.aarch64.cpu.generic },
                };

                // Remove neon and fp features
                target.cpu_features_sub.addFeature(@intFromEnum(features.neon));
                target.cpu_features_sub.addFeature(@intFromEnum(features.fp_armv8));

                return target;
            },

            .x86_64 => {
                const features = std.Target.x86.Feature;
                var target = std.zig.CrossTarget{
                    .cpu_arch = .x86_64,
                    .os_tag = .freestanding,
                    .abi = .none,
                    .cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64 },
                };

                // Remove all SSE/AVX features
                target.cpu_features_sub.addFeature(@intFromEnum(features.x87));
                target.cpu_features_sub.addFeature(@intFromEnum(features.mmx));
                target.cpu_features_sub.addFeature(@intFromEnum(features.sse));
                target.cpu_features_sub.addFeature(@intFromEnum(features.f16c));
                target.cpu_features_sub.addFeature(@intFromEnum(features.fma));
                target.cpu_features_sub.addFeature(@intFromEnum(features.sse2));
                target.cpu_features_sub.addFeature(@intFromEnum(features.sse3));
                target.cpu_features_sub.addFeature(@intFromEnum(features.sse4_1));
                target.cpu_features_sub.addFeature(@intFromEnum(features.sse4_2));
                target.cpu_features_sub.addFeature(@intFromEnum(features.ssse3));
                target.cpu_features_sub.addFeature(@intFromEnum(features.vzeroupper));
                target.cpu_features_sub.addFeature(@intFromEnum(features.avx));
                target.cpu_features_sub.addFeature(@intFromEnum(features.avx2));
                target.cpu_features_sub.addFeature(@intFromEnum(features.avx512bw));
                target.cpu_features_sub.addFeature(@intFromEnum(features.avx512cd));
                target.cpu_features_sub.addFeature(@intFromEnum(features.avx512dq));
                target.cpu_features_sub.addFeature(@intFromEnum(features.avx512f));
                target.cpu_features_sub.addFeature(@intFromEnum(features.avx512vl));

                // Add soft float
                target.cpu_features_add.addFeature(@intFromEnum(features.soft_float));

                return target;
            },
        }
    }

    pub fn linkerScriptPath(self: CascadeTarget, b: *std.Build) []const u8 {
        return switch (self) {
            .aarch64 => helpers.pathJoinFromRoot(b, &.{ ".build", "linker_aarch64.ld" }),
            .x86_64 => helpers.pathJoinFromRoot(b, &.{ ".build", "linker_x86_64.ld" }),
        };
    }

    pub fn buildImageScriptPath(self: CascadeTarget, b: *std.Build) []const u8 {
        _ = self;
        return helpers.pathJoinFromRoot(b, &.{ ".build", "build_limine_image.sh" });
    }

    pub fn qemuExecutable(self: CascadeTarget) []const u8 {
        return switch (self) {
            .aarch64 => "qemu-system-aarch64",
            .x86_64 => "qemu-system-x86_64",
        };
    }

    pub fn setQemuCpu(self: CascadeTarget, run_qemu: *Step.Run) void {
        switch (self) {
            .aarch64 => run_qemu.addArgs(&[_][]const u8{ "-cpu", "max" }),
            .x86_64 => run_qemu.addArgs(&.{ "-cpu", "max,migratable=no" }), // `migratable=no` is required to get invariant tsc
        }
    }

    pub fn setQemuMachine(self: CascadeTarget, run_qemu: *Step.Run) void {
        switch (self) {
            .aarch64 => run_qemu.addArgs(&[_][]const u8{ "-M", "virt" }),
            .x86_64 => run_qemu.addArgs(&[_][]const u8{ "-machine", "q35" }),
        }
    }

    pub fn uefiFirmwareUrl(self: CascadeTarget) []const u8 {
        return switch (self) {
            .aarch64 => "https://retrage.github.io/edk2-nightly/bin/RELEASEAARCH64_QEMU_EFI.fd",
            .x86_64 => "https://retrage.github.io/edk2-nightly/bin/RELEASEX64_OVMF.fd",
        };
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
