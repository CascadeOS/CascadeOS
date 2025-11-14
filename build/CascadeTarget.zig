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
                .arm => return b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .other }),
                .riscv => return b.resolveTargetQuery(.{ .cpu_arch = .riscv64, .os_tag = .other }),
                .x64 => return b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .other }),
            },
            .non_cascade => switch (self.architecture) {
                .arm => return b.resolveTargetQuery(.{ .cpu_arch = .aarch64 }),
                .riscv => return b.resolveTargetQuery(.{ .cpu_arch = .riscv64 }),
                .x64 => return b.resolveTargetQuery(.{ .cpu_arch = .x86_64 }),
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
    };

    pub const Context = enum {
        cascade,
        non_cascade, // TODO: better name, `host` does not make sense in every case but it does for most of them?
    };
};
