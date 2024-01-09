// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

//! A basic write only UART.

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");
const aarch64 = @import("aarch64.zig");

const Uart = @This();

address: *volatile u8,

pub fn init(address: usize) Uart {
    return .{
        .address = @ptrFromInt(address),
    };
}

pub const Writer = std.io.Writer(Uart, error{}, writerImpl);
pub inline fn writer(self: Uart) Writer {
    return .{ .context = self };
}

/// The impl function driving the `std.io.Writer`
fn writerImpl(self: Uart, bytes: []const u8) error{}!usize {
    for (bytes) |char| {
        self.address.* = char;
    }
    return bytes.len;
}
