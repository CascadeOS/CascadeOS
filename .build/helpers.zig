// SPDX-License-Identifier: MIT

const std = @import("std");

pub inline fn pathJoinFromRoot(b: *std.Build, paths: []const []const u8) []const u8 {
    return b.pathFromRoot(b.pathJoin(paths));
}

pub fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

pub fn runExternalBinary(allocator: std.mem.Allocator, args: []const []const u8, cwd: ?[]const u8) !void {
    var child = std.ChildProcess.init(args, allocator);
    if (cwd) |c| child.cwd = c;

    try child.spawn();
    const term = try child.wait();

    switch (term) {
        .Exited => |code| if (code != 0) return error.UncleanExit,
        else => return error.UncleanExit,
    }
}
