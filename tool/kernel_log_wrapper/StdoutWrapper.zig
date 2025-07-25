// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

// TODO: rewrite this whole thing in light of writergate

const StdoutWrapper = @This();

allocator: std.mem.Allocator,

poller: std.Io.Poller(StdoutEnum),
stdout_window: []const u8 = &.{},
partial_read_buffer: std.ArrayListUnmanaged(u8) = .{},

pub fn init(allocator: std.mem.Allocator, stdout: std.fs.File) !StdoutWrapper {
    return .{
        .allocator = allocator,
        .poller = std.Io.poll(allocator, StdoutEnum, .{ .stdout = stdout }),
    };
}

pub fn deinit(stdout_wrapper: *StdoutWrapper) void {
    stdout_wrapper.poller.deinit();
    stdout_wrapper.partial_read_buffer.deinit(stdout_wrapper.allocator);
}

pub fn next(stdout_wrapper: *StdoutWrapper) !?[]const u8 {
    const stdout = stdout_wrapper.poller.reader(.stdout);

    stdout_wrapper.partial_read_buffer.clearRetainingCapacity();

    while (true) {
        if (stdout_wrapper.stdout_window.len != 0) stdout_window_blk: {
            const stdout_window = stdout_wrapper.stdout_window;

            const newline_index = std.mem.indexOfScalar(
                u8,
                stdout_window,
                '\n',
            ) orelse {
                // no newline found, store this partial line read in the partial read buffer
                try stdout_wrapper.partial_read_buffer.appendSlice(stdout_wrapper.allocator, stdout_window);
                stdout_wrapper.stdout_window = &.{};

                stdout.tossBuffered();
                break :stdout_window_blk;
            };
            const next_line_index = newline_index + 1;

            stdout_wrapper.stdout_window = stdout_window[next_line_index..];

            if (stdout_wrapper.partial_read_buffer.items.len != 0) {
                try stdout_wrapper.partial_read_buffer.appendSlice(stdout_wrapper.allocator, stdout_window[0..next_line_index]);
                return stdout_wrapper.partial_read_buffer.items;
            }

            return stdout_window[0..next_line_index];
        } else if (stdout.bufferedLen() != 0) {
            stdout.tossBuffered();
        }

        if (try stdout_wrapper.poller.poll()) {
            if (stdout.bufferedLen() == 0) continue;
            stdout_wrapper.stdout_window = stdout.buffered();
            continue;
        }

        if (stdout_wrapper.partial_read_buffer.items.len != 0) {
            return stdout_wrapper.partial_read_buffer.items;
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
