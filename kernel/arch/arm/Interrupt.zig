// SPDX-License-Identifier: BSD-3-Clause
// SPDX-FileCopyrightText: CascadeOS Contributors

const cascade = @import("cascade");
const core = @import("core");
const std = @import("std");

const arm = @import("arm.zig");

pub const Interrupt = enum {
    pub const Frame = extern struct {};

    pub const External = enum(u0) {
        _,
    };
};
