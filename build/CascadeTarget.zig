// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const Step = std.Build.Step;

pub const CascadeTarget = struct {
    architecture: Architecture,
    context: Context,

    pub fn getNative(b: *std.Build) ?CascadeTarget {
        return switch (b.graph.host.result.cpu.arch) {
            .aarch64 => .{ .architecture = .arm, .context = .non_cascade },
            .riscv64 => .{ .architecture = .riscv, .context = .non_cascade },
            .x86_64 => .{ .architecture = .x64, .context = .non_cascade },
            else => null,
        };
    }

    pub fn getCrossTarget(self: CascadeTarget, b: *std.Build) std.Build.ResolvedTarget {
        switch (self.context) {
            .cascade => switch (self.architecture) {
                .arm => return b.resolveTargetQuery(.{
                    .cpu_arch = .aarch64,
                    .os_tag = .other,
                    .abi = .none,
                    .cpu_model = self.architecture.cascadeTargetCpuModel(),
                }),
                .riscv => return b.resolveTargetQuery(.{
                    .cpu_arch = .riscv64,
                    .os_tag = .other,
                    .abi = .none,
                    .cpu_model = self.architecture.cascadeTargetCpuModel(),
                }),
                .x64 => return b.resolveTargetQuery(.{
                    .cpu_arch = .x86_64,
                    .os_tag = .other,
                    .abi = .none,
                    .cpu_model = self.architecture.cascadeTargetCpuModel(),
                }),
            },
            .non_cascade => {
                if (self.architecture.isNative(b)) return b.resolveTargetQuery(.{});

                switch (self.architecture) {
                    .arm => return b.resolveTargetQuery(.{ .cpu_arch = .aarch64 }),
                    .riscv => return b.resolveTargetQuery(.{ .cpu_arch = .riscv64 }),
                    .x64 => return b.resolveTargetQuery(.{ .cpu_arch = .x86_64 }),
                }
            },
        }
    }

    pub const Architecture = enum {
        arm,
        riscv,
        x64,

        /// Is this architecture the same as the host system?
        pub fn isNative(architecture: Architecture, b: *std.Build) bool {
            return switch (b.graph.host.result.cpu.arch) {
                .aarch64 => architecture == .arm,
                .riscv64 => architecture == .riscv,
                .x86_64 => architecture == .x64,
                else => false,
            };
        }

        pub fn cascadeTargetCpuModel(architecture: CascadeTarget.Architecture) std.Target.Query.CpuModel {
            return switch (architecture) {
                .arm => .{ .explicit = &std.Target.aarch64.cpu.generic },
                .riscv => .{ .explicit = &std.Target.riscv.cpu.baseline_rv64 },
                .x64 => .{ .explicit = &std.Target.x86.cpu.x86_64_v2 },
            };
        }

        /// Returns a target for building the kernel for the given architecture.
        pub fn kernelTarget(architecture: CascadeTarget.Architecture, b: *std.Build) std.Build.ResolvedTarget {
            switch (architecture) {
                .arm => {
                    const features = std.Target.aarch64.Feature;
                    var target_query: std.Target.Query = .{
                        .cpu_arch = .aarch64,
                        .os_tag = .freestanding,
                        .abi = .none,
                        .cpu_model = architecture.cascadeTargetCpuModel(),
                    };

                    // Remove neon and fp features
                    target_query.cpu_features_sub.addFeature(@intFromEnum(features.neon));
                    target_query.cpu_features_sub.addFeature(@intFromEnum(features.fp_armv8));

                    return b.resolveTargetQuery(target_query);
                },

                .riscv => {
                    const features = std.Target.riscv.Feature;
                    var target_query: std.Target.Query = .{
                        .cpu_arch = .riscv64,
                        .os_tag = .freestanding,
                        .abi = .none,
                        .cpu_model = architecture.cascadeTargetCpuModel(),
                    };

                    target_query.cpu_features_add.addFeature(@intFromEnum(features.zicsr));
                    target_query.cpu_features_add.addFeature(@intFromEnum(features.zihintpause));

                    return b.resolveTargetQuery(target_query);
                },

                .x64 => {
                    const features = std.Target.x86.Feature;
                    var target_query: std.Target.Query = .{
                        .cpu_arch = .x86_64,
                        .os_tag = .freestanding,
                        .abi = .none,
                        .cpu_model = architecture.cascadeTargetCpuModel(),
                    };

                    // Remove all SSE/AVX features
                    target_query.cpu_features_sub.addFeature(@intFromEnum(features.x87));
                    target_query.cpu_features_sub.addFeature(@intFromEnum(features.mmx));
                    target_query.cpu_features_sub.addFeature(@intFromEnum(features.sse));
                    target_query.cpu_features_sub.addFeature(@intFromEnum(features.f16c));
                    target_query.cpu_features_sub.addFeature(@intFromEnum(features.fma));
                    target_query.cpu_features_sub.addFeature(@intFromEnum(features.fxsr));
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
                    target_query.cpu_features_sub.addFeature(@intFromEnum(features.evex512));

                    // Add soft float
                    target_query.cpu_features_add.addFeature(@intFromEnum(features.soft_float));

                    return b.resolveTargetQuery(target_query);
                },
            }
        }
    };

    pub const Context = enum {
        cascade,
        non_cascade, // TODO: better name, `host` does not make sense in every case but it does for most of them?
    };
};
