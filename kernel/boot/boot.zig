// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

/// Exports bootloader entry points and any other required exported symbols.
///
/// Required to be called at comptime from the kernels root file 'kernel/kernel.zig'.
pub fn exportEntryPoints() void {
    const unknownBootloaderEntryPoint = struct {
        /// The entry point that is exported as `_start` and acts as fallback entry point for unknown bootloaders.
        ///
        /// No bootloader is ever expected to call `_start` and instead should use bootloader specific entry points;
        /// meaning this function is not expected to ever be called.
        pub fn unknownBootloaderEntryPoint() callconv(.Naked) noreturn {
            @call(.always_inline, kernel.arch.interrupts.disableInterruptsAndHalt, .{});
            unreachable;
        }
    }.unknownBootloaderEntryPoint;

    comptime {
        @export(&unknownBootloaderEntryPoint, .{ .name = "_start" });
    }
}

const std = @import("std");
const kernel = @import("../kernel.zig");
