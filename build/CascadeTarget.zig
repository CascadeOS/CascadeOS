// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const Step = std.Build.Step;

const helpers = @import("helpers.zig");

pub const CascadeTarget = enum {
    aarch64,
    x86_64,

    /// Returns a CrossTarget for building tests targeting the host system.
    pub fn getNonCascadeTestCrossTarget(self: CascadeTarget, b: *std.Build) std.Build.ResolvedTarget {
        const target_query: std.Target.Query = switch (self) {
            .aarch64 => .{ .cpu_arch = .aarch64 },
            .x86_64 => .{ .cpu_arch = .x86_64 },
        };

        return b.resolveTargetQuery(target_query);
    }

    /// Returns a CrossTarget for building tests targeting cascade.
    pub fn getCascadeTestCrossTarget(self: CascadeTarget, b: *std.Build) std.Build.ResolvedTarget {
        // TODO: os_tag should be other
        const target_query: std.Target.Query = switch (self) {
            .aarch64 => .{ .cpu_arch = .aarch64 },
            .x86_64 => .{ .cpu_arch = .x86_64 },
        };

        return b.resolveTargetQuery(target_query);
    }

    /// Returns true if the targets architecture is equal to the host systems.
    pub fn isNative(self: CascadeTarget, b: *std.Build) bool {
        return switch (b.host.result.cpu.arch) {
            .aarch64 => self == .aarch64,
            .x86_64 => self == .x86_64,
            else => false,
        };
    }

    /// Returns true if the target needs UEFI to boot.
    pub fn needsUefi(self: CascadeTarget) bool {
        return switch (self) {
            .aarch64 => true,
            .x86_64 => false,
        };
    }

    /// Returns a CrossTarget for building the kernel for the given target.
    pub fn getKernelCrossTarget(self: CascadeTarget, b: *std.Build) std.Build.ResolvedTarget {
        switch (self) {
            .aarch64 => {
                const features = std.Target.aarch64.Feature;
                var target_query = std.Target.Query{
                    .cpu_arch = .aarch64,
                    .os_tag = .freestanding,
                    .abi = .none,
                    .cpu_model = .{ .explicit = &std.Target.aarch64.cpu.generic },
                };

                // Remove neon and fp features
                target_query.cpu_features_sub.addFeature(@intFromEnum(features.neon));
                target_query.cpu_features_sub.addFeature(@intFromEnum(features.fp_armv8));

                return b.resolveTargetQuery(target_query);
            },

            .x86_64 => {
                const features = std.Target.x86.Feature;
                var target_query = std.Target.Query{
                    .cpu_arch = .x86_64,
                    .os_tag = .freestanding,
                    .abi = .none,
                    .cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64 }, // TODO: As we only support modern machines maybe make this v2 or v3?
                };

                // Remove all SSE/AVX features
                target_query.cpu_features_sub.addFeature(@intFromEnum(features.x87));
                target_query.cpu_features_sub.addFeature(@intFromEnum(features.mmx));
                target_query.cpu_features_sub.addFeature(@intFromEnum(features.sse));
                target_query.cpu_features_sub.addFeature(@intFromEnum(features.f16c));
                target_query.cpu_features_sub.addFeature(@intFromEnum(features.fma));
                target_query.cpu_features_sub.addFeature(@intFromEnum(features.sse2));
                target_query.cpu_features_sub.addFeature(@intFromEnum(features.sse3));
                target_query.cpu_features_sub.addFeature(@intFromEnum(features.sse4_1));
                target_query.cpu_features_sub.addFeature(@intFromEnum(features.sse4_2));
                target_query.cpu_features_sub.addFeature(@intFromEnum(features.ssse3));
                target_query.cpu_features_sub.addFeature(@intFromEnum(features.vzeroupper));
                target_query.cpu_features_sub.addFeature(@intFromEnum(features.avx));
                target_query.cpu_features_sub.addFeature(@intFromEnum(features.avx2));
                target_query.cpu_features_sub.addFeature(@intFromEnum(features.avx512bw));
                target_query.cpu_features_sub.addFeature(@intFromEnum(features.avx512cd));
                target_query.cpu_features_sub.addFeature(@intFromEnum(features.avx512dq));
                target_query.cpu_features_sub.addFeature(@intFromEnum(features.avx512f));
                target_query.cpu_features_sub.addFeature(@intFromEnum(features.avx512vl));

                // Add soft float
                target_query.cpu_features_add.addFeature(@intFromEnum(features.soft_float));

                return b.resolveTargetQuery(target_query);
            },
        }
    }

    /// Returns the path to the kernel linker script for the given target.
    pub fn linkerScriptPath(self: CascadeTarget, b: *std.Build) []const u8 {
        return helpers.pathJoinFromRoot(b, &.{ "kernel", "arch", @tagName(self), "linker.ld" });
    }

    /// Returns the name of the QEMU system executable for the given target.
    pub fn qemuExecutable(self: CascadeTarget) []const u8 {
        return switch (self) {
            .aarch64 => "qemu-system-aarch64",
            .x86_64 => "qemu-system-x86_64",
        };
    }

    /// Appends the correct QEMU CPU arguments for the target to the `run_qemu` step.
    pub fn setQemuCpu(self: CascadeTarget, run_qemu: *Step.Run) void {
        switch (self) {
            .aarch64 => run_qemu.addArgs(&[_][]const u8{ "-cpu", "max" }),
            .x86_64 => run_qemu.addArgs(&.{ "-cpu", "max,migratable=no,+invtsc" }),
        }
    }

    /// Appends the correct QEMU machine arguments for the target to the `run_qemu` step.
    pub fn setQemuMachine(self: CascadeTarget, run_qemu: *Step.Run) void {
        switch (self) {
            .aarch64 => run_qemu.addArgs(&[_][]const u8{ "-machine", "virt" }),
            .x86_64 => run_qemu.addArgs(&[_][]const u8{ "-machine", "q35" }),
        }
    }

    pub fn uefiFirmwareFileName(self: CascadeTarget) []const u8 {
        return switch (self) {
            .aarch64 => "aarch64/code.fd",
            .x86_64 => "x64/code.fd",
        };
    }

    /// Applies target-specific configuration to the kernel.
    pub fn targetSpecificSetup(self: CascadeTarget, kernel_exe: *Step.Compile) void {
        switch (self) {
            .aarch64 => {},
            .x86_64 => {
                kernel_exe.root_module.code_model = .kernel;
                kernel_exe.root_module.red_zone = false;
            },
        }
    }
};
