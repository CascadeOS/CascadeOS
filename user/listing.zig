// SPDX-License-Identifier: CC0-1.0
// SPDX-FileCopyrightText: CascadeOS Contributors

pub const applications: []const ApplicationDescription = &.{
    .{
        .name = "hello_world",
        .dependencies = &.{"cascade"},
    },
};

const ApplicationDescription = @import("../build/ApplicationDescription.zig");
