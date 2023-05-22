// SPDX-License-Identifier: MIT

const std = @import("std");
const kernel = @import("root");
const aarch64 = @import("aarch64.zig");

const UART = @This();

// TODO: Implement a proper UART driver

addr: *volatile u8,

pub fn init(addr: usize) UART {
    return .{
        .addr = @intToPtr(*volatile u8, addr),
    };
}

pub const Writer = std.io.Writer(UART, error{}, writerImpl);
pub inline fn writer(self: UART) Writer {
    return .{ .context = self };
}

/// The impl function driving the `std.io.Writer`
fn writerImpl(self: UART, bytes: []const u8) error{}!usize {
    for (bytes) |char| {
        self.addr.* = char;
    }
    return bytes.len;
}
