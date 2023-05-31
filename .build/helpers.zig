// SPDX-License-Identifier: MIT

const std = @import("std");

pub inline fn pathJoinFromRoot(b: *std.Build, paths: []const []const u8) []const u8 {
    return b.pathFromRoot(b.pathJoin(paths));
}

pub fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}
