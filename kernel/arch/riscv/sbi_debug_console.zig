// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

//! A very simple debug console that uses the SBI debug console.
//!
//! Only supports writes.

const std = @import("std");

const arch = @import("arch");
const kernel = @import("kernel");
const Task = kernel.Task;
const core = @import("core");
const sbi = @import("sbi");

const riscv = @import("riscv.zig");

pub fn detect() bool {
    return sbi.debug_console.available();
}

pub const output: arch.init.InitOutput.Output = .{
    .name = arch.init.InitOutput.Output.Name.fromSlice("sbi console") catch unreachable,
    .writeFn = struct {
        fn writeFn(_: *anyopaque, str: []const u8) void {
            writeStr(str);
        }
    }.writeFn,
    .splatFn = struct {
        fn splatFn(_: *anyopaque, str: []const u8, splat: usize) void {
            for (0..splat) |_| writeStr(str);
        }
    }.splatFn,
    .remapFn = struct {
        fn remapFn(_: *anyopaque) !void {
            return;
        }
    }.remapFn,
    .state = undefined,
};

fn writeStr(str: []const u8) void {
    // TODO: figure out how to get `sbi.debug_console.write` to work
    //       as `sbi.debug_console.writeByte` is inefficient
    for (str) |b| {
        sbi.debug_console.writeByte(b) catch return;
    }
}
