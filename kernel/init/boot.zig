// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

/// Exports bootloader entry points.
///
/// Required to be called at comptime from the kernels root file.
pub fn exportEntryPoints() void {
    comptime {
        // TODO: use the limine entry point request
        @export(&limineEntryPoint, .{ .name = "_start" });
    }
}

fn limineEntryPoint() callconv(.C) noreturn {
    @call(.never_inline, kernel.init.initStage1, .{}) catch |err| {
        core.panicFmt("unhandled error: {s}", .{@errorName(err)}, @errorReturnTrace());
    };
    core.panic("`kernel.init.initStage1` returned", null);
}

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const limine = @import("limine");
