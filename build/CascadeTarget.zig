// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const Step = std.Build.Step;

const helpers = @import("helpers.zig");

pub const CascadeTarget = enum {
    x86_64,

    /// Returns a CrossTarget for building targeting the host system.
    pub fn getNonCascadeCrossTarget(self: CascadeTarget, b: *std.Build) std.Build.ResolvedTarget {
        const target_query: std.Target.Query = switch (self) {
            .x86_64 => .{ .cpu_arch = .x86_64 },
        };

        return b.resolveTargetQuery(target_query);
    }

    /// Returns a CrossTarget for building targeting cascade.
    pub fn getCascadeCrossTarget(self: CascadeTarget, b: *std.Build) std.Build.ResolvedTarget {
        const target_query: std.Target.Query = switch (self) {
            .x86_64 => .{ .cpu_arch = .x86_64, .os_tag = .other },
        };

        return b.resolveTargetQuery(target_query);
    }

    /// Returns true if the targets architecture is equal to the host systems.
    pub fn isNative(self: CascadeTarget, b: *std.Build) bool {
        return switch (b.host.result.cpu.arch) {
            .x86_64 => self == .x86_64,
            else => false,
        };
    }
};
