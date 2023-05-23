// SPDX-License-Identifier: MIT

const std = @import("std");
const kernel = @import("root");
const aarch64 = @import("aarch64.zig");

const Uart = @This();

// TODO: Implement a proper UART driver

addr: *volatile u8,

pub fn init(addr: usize) Uart {
    return .{
        .addr = @intToPtr(*volatile u8, addr),
    };
}

pub const Writer = std.io.Writer(Uart, error{}, writerImpl);
pub inline fn writer(self: Uart) Writer {
    return .{ .context = self };
}

/// The impl function driving the `std.io.Writer`
fn writerImpl(self: Uart, bytes: []const u8) error{}!usize {
    for (bytes) |char| {
        self.addr.* = char;
    }
    return bytes.len;
}
