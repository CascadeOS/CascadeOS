// SPDX-License-Identifier: LicenseRef-NON-AI-CC0-1.0
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub const applications: []const ApplicationDescription = &.{
    .{
        .name = "hello_world",
        .dependencies = &.{"user_cascade"},
    },
};

const ApplicationDescription = @import("../build/ApplicationDescription.zig");
