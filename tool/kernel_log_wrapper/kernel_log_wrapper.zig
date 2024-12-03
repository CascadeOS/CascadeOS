// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

pub fn main() !void {
    var gpa_impl = if (builtin.mode == .Debug) std.heap.GeneralPurposeAllocator(.{}){} else {};
    defer {
        if (builtin.mode == .Debug) _ = gpa_impl.deinit();
    }
    const allocator = if (builtin.mode == .Debug) gpa_impl.allocator() else std.heap.c_allocator;

    const command = try getCommand(allocator);
    defer command.deinit(allocator);

    var child = std.process.Child.init(command.argv, allocator);

    const stdout = std.io.getStdOut();
    const config = std.io.tty.detectConfig(stdout);

    if (config == .no_color or config == .windows_api) {
        try child.spawn();
    } else {
        child.stdout_behavior = .Pipe;
        try child.spawn();

        var stdout_wrapper = try StdoutWrapper.init(allocator, child.stdout.?);
        defer stdout_wrapper.deinit();

        while (try stdout_wrapper.next()) |line| {
            try handleLine(stdout, line);
        }
    }

    _ = try child.wait();
}

fn handleLine(stdout: std.fs.File, line: []const u8) !void {
    inline for (rules) |rule| {
        if (std.mem.startsWith(u8, line, rule.pattern)) {
            const formatted_string = comptime rule.buildFormattedString();
            try stdout.writeAll(formatted_string);
            try stdout.writeAll(line[rule.pattern.len..]);
            return;
        }
    }

    try stdout.writeAll(line);
}

const rules = [_]Rule{
    .{
        .pattern = "debug",
        .foreground = .{
            .rgb = .{ .r = 100, .g = 100, .b = 100 }, // grey
        },
    },
    // .{ .pattern = "info" },
    .{
        .pattern = "warning",
        .bold = true,
        .foreground = .{ .simple = .yellow },
    },
    .{
        .pattern = "error",
        .bold = true,
        .foreground = .{ .simple = .white },
        .background = .{ .simple = .red },
    },
    .{
        .pattern = "PANIC",
        .bold = true,
        .foreground = .{ .simple = .white },
        .background = .{ .rgb = .{ .r = 255, .g = 0, .b = 0 } }, // red
    },
};

const Rule = struct {
    pattern: []const u8,

    bold: bool = false,

    foreground: ?Color = null,
    background: ?Color = null,

    pub const Color = union(enum) {
        simple: ansi.Color,
        rgb: ansi.RGB,
    };

    pub fn buildFormattedString(comptime self: Rule) []const u8 {
        // zig fmt: off
        comptime return
        (if (self.bold) ansi.style.bold else "")
        ++
        (if (self.foreground) |foreground|
            (if (foreground == .simple)
                ansi.color.fg(foreground.simple)
            else
                ansi.color.fgRGB(foreground.rgb))
        else
            "")
        ++
        (if (self.background) |background|
            (if (background == .simple)
                ansi.color.bg(background.simple)
            else
                ansi.color.bgRGB(background.rgb))
        else
            "")
        ++
        self.pattern
        ++
        (if (self.background != null) ansi.color.reset_bg else "")
        ++
        (if (self.foreground != null) ansi.color.reset_fg else "")
        ++
        (if (self.bold) ansi.style.no_bold else "");
        // zig fmt: on
    }
};

const usage =
    \\Usage: command [argument ...]
    \\
    \\Runs the specified command with the given arguments.
    \\
    \\Forwards stdin, stderr without modification but adds ANSI escape codes to stdout.
    \\
    \\Information flags:
    \\  -h, --help                 display the help and exit
    \\
;

const Command = struct {
    argv: []const []const u8,

    pub fn deinit(self: Command, allocator: std.mem.Allocator) void {
        for (self.argv) |arg| allocator.free(arg);
        allocator.free(self.argv);
    }
};

fn getCommand(allocator: std.mem.Allocator) !Command {
    var args_iter = try std.process.argsWithAllocator(allocator);
    defer args_iter.deinit();

    if (!args_iter.skip()) argumentError("no self path argument?", .{});

    var child_argv = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (child_argv.items) |arg| allocator.free(arg);
        child_argv.deinit();
    }

    while (args_iter.next()) |arg| {
        if (arg.len == 0) continue;

        const arg_owned = try allocator.dupe(u8, arg);
        errdefer allocator.free(arg_owned);

        try child_argv.append(arg_owned);
    }

    if (child_argv.items.len == 0) argumentError("no command given", .{});

    return .{ .argv = try child_argv.toOwnedSlice() };
}

fn argumentError(comptime msg: []const u8, args: anytype) noreturn {
    const stderr = std.io.getStdErr().writer();

    if (msg.len == 0) @compileError("no message given");

    blk: {
        stderr.writeAll("error: ") catch break :blk;

        stderr.print(msg, args) catch break :blk;

        if (msg[msg.len - 1] != '\n') {
            stderr.writeAll("\n\n") catch break :blk;
        } else {
            stderr.writeByte('\n') catch break :blk;
        }

        stderr.writeAll(usage) catch break :blk;
    }

    std.process.exit(1);
}

const std = @import("std");
const core = @import("core");
const ansi = @import("ansi.zig");
const builtin = @import("builtin");
const StdoutWrapper = @import("StdoutWrapper.zig");

comptime {
    std.testing.refAllDeclsRecursive(@This());
}
