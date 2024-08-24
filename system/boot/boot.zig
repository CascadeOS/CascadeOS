// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

/// Exports bootloader entry points.
///
/// Required to be called at comptime from the kernels root file 'system/root.zig'.
pub fn exportEntryPoints() void {
    comptime {
        @export(arch.init.defaultEntryPoint, .{ .name = "_start" });

        _ = &limine_requests;
    }
}

fn limineEntryPoint() callconv(.C) noreturn {
    bootloader_api = .limine;
    @call(.never_inline, init.initStage1, .{}) catch |err| {
        core.panicFmt("unhandled error: {s}", .{@errorName(err)}, @errorReturnTrace());
    };
    core.panic("`init.initStage1` returned", null);
}

const limine_requests = struct {
    export var limine_revison: limine.BaseRevison = .{ .revison = 2 };
    export var entry_point: limine.EntryPoint = .{ .entry = limineEntryPoint };
};

var bootloader_api: BootloaderAPI = .unknown;

const BootloaderAPI = enum {
    unknown,
    limine,
};

const std = @import("std");
const core = @import("core");
const limine = @import("limine");
const init = @import("init");
const arch = @import("arch");
