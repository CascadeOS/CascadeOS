// SPDX-License-Identifier: MIT

const std = @import("std");
const Step = std.Build.Step;

const helpers = @import("helpers.zig");

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
                const features = std.Target.aarch64.Feature;
                var target = std.zig.CrossTarget{
                    .cpu_arch = .aarch64,
                    .os_tag = .freestanding,
                    .abi = .none,
                    .cpu_model = .{ .explicit = &std.Target.aarch64.cpu.generic },
                };

                // TODO: disabling these causes zig to seg fault https://github.com/CascadeOS/CascadeOS/issues/6
                if (false) {
                    // Remove neon and fp features
                    target.cpu_features_sub.addFeature(@enumToInt(features.neon));
                    target.cpu_features_sub.addFeature(@enumToInt(features.fp_armv8));
                }

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

    pub fn buildImagePath(self: CascadeTarget, b: *std.Build) []const u8 {
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
                if (helpers.fileExists("/usr/share/edk2/aarch64/QEMU_EFI.fd")) return "/usr/share/edk2/aarch64/QEMU_EFI.fd";
            },
            .x86_64 => {
                if (helpers.fileExists("/usr/share/ovmf/x64/OVMF.fd")) return "/usr/share/ovmf/x64/OVMF.fd";
                if (helpers.fileExists("/usr/share/ovmf/OVMF.fd")) return "/usr/share/ovmf/OVMF.fd";
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
