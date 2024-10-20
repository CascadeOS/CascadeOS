// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

pub fn customConfiguration(
    b: *std.Build,
    _: ToolDescription,
    exe: *std.Build.Step.Compile,
) void {
    if (b.graph.host.result.os.tag == .linux) {
        // Use musl to remove include of "/usr/include"
        exe.root_module.resolved_target.?.query.abi = .musl;
        exe.root_module.resolved_target.?.result.abi = .musl;
    }

    exe.linkLibC();
}

const std = @import("std");
const builtin = @import("builtin");

const helpers = @import("../../build/helpers.zig");
const ToolDescription = @import("../../build/ToolDescription.zig");
