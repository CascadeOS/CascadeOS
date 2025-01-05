// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

pub fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

/// Runs an external binary.
pub fn runExternalBinary(allocator: std.mem.Allocator, args: []const []const u8, cwd: ?[]const u8) !void {
    var child = std.ChildProcess.init(args, allocator);
    if (cwd) |current_working_dir| child.cwd = current_working_dir;

    child.cwd = cwd orelse null;

    try child.spawn();
    const term = try child.wait();

    switch (term) {
        .Exited => |code| if (code != 0) return error.UncleanExit,
        else => return error.UncleanExit,
    }
}
