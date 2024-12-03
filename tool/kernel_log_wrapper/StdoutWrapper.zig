// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const StdoutWrapper = @This();

allocator: std.mem.Allocator,

poller: std.io.Poller(StdoutEnum),
stdout_window: []const u8 = &.{},
partial_read_buffer: std.ArrayListUnmanaged(u8) = .{},

pub fn init(allocator: std.mem.Allocator, stdout: std.fs.File) !StdoutWrapper {
    return .{
        .allocator = allocator,
        .poller = std.io.poll(allocator, StdoutEnum, .{ .stdout = stdout }),
    };
}

pub fn deinit(self: *StdoutWrapper) void {
    self.poller.deinit();
    self.partial_read_buffer.deinit(self.allocator);
}

pub fn next(self: *StdoutWrapper) !?[]const u8 {
    const stdout_fifo = self.poller.fifo(.stdout);

    self.partial_read_buffer.clearRetainingCapacity();

    while (true) {
        if (self.stdout_window.len != 0) stdout_window_blk: {
            const stdout_window = self.stdout_window;

            const newline_index = std.mem.indexOfScalar(
                u8,
                stdout_window,
                '\n',
            ) orelse {
                // no newline found, store this partial line read in the partial read buffer
                try self.partial_read_buffer.appendSlice(self.allocator, stdout_window);
                self.stdout_window = &.{};

                stdout_fifo.discard(stdout_fifo.count);
                break :stdout_window_blk;
            };
            const next_line_index = newline_index + 1;

            self.stdout_window = stdout_window[next_line_index..];

            if (self.partial_read_buffer.items.len != 0) {
                try self.partial_read_buffer.appendSlice(self.allocator, stdout_window[0..next_line_index]);
                return self.partial_read_buffer.items;
            }

            return stdout_window[0..next_line_index];
        } else if (stdout_fifo.count != 0) {
            stdout_fifo.discard(stdout_fifo.count);
        }

        if (try self.poller.poll()) {
            if (stdout_fifo.count == 0) continue;
            self.stdout_window = stdout_fifo.readableSlice(0);
            continue;
        }

        if (self.partial_read_buffer.items.len != 0) {
            return self.partial_read_buffer.items;
        }

        return null;
    }
}

const StdoutEnum = enum { stdout };

const std = @import("std");
const core = @import("core");
const ansi = @import("ansi.zig");
const builtin = @import("builtin");

comptime {
    std.testing.refAllDeclsRecursive(@This());
}
