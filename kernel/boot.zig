// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const limine = @import("limine");

export fn _start() callconv(.C) noreturn {
    @call(.never_inline, @import("init.zig").earlyInit, .{}) catch |err| {
        core.panicFmt("unhandled error: {s}", .{@errorName(err)});
    };
    core.panic("`init.earlyInit` returned");
}

const limine_requests = struct {
    export var limine_revison: limine.BaseRevison = .{ .revison = 1 };
};

comptime {
    _ = &limine_requests;
}
