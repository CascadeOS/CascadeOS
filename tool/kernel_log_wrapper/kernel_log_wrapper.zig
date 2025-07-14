// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub fn main() !void {
    var gpa_impl = if (builtin.mode == .Debug) std.heap.GeneralPurposeAllocator(.{}){} else {};
    defer {
        if (builtin.mode == .Debug) _ = gpa_impl.deinit();
    }
    const allocator = if (builtin.mode == .Debug) gpa_impl.allocator() else std.heap.smp_allocator;

    const command = try getCommand(allocator);
    defer command.deinit(allocator);

    var child = std.process.Child.init(command.argv, allocator);

    const stdout = std.fs.File.stdout();
    const config = std.Io.tty.detectConfig(stdout);

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
        .pattern = "verbose",
        .foreground = .{
            .rgb = .{ .r = 110, .g = 110, .b = 110 }, // dark grey
        },
    },
    .{
        .pattern = "debug",
        .foreground = .{
            .rgb = .{ .r = 200, .g = 200, .b = 200 }, // light grey
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

    pub fn buildFormattedString(comptime rule: Rule) []const u8 {
        // zig fmt: off
        comptime return
        (if (rule.bold) ansi.style.bold else "")
        ++
        (if (rule.foreground) |foreground|
            (if (foreground == .simple)
                ansi.color.fg(foreground.simple)
            else
                ansi.color.fgRGB(foreground.rgb))
        else
            "")
        ++
        (if (rule.background) |background|
            (if (background == .simple)
                ansi.color.bg(background.simple)
            else
                ansi.color.bgRGB(background.rgb))
        else
            "")
        ++
        rule.pattern
        ++
        (if (rule.background != null) ansi.color.reset_bg else "")
        ++
        (if (rule.foreground != null) ansi.color.reset_fg else "")
        ++
        (if (rule.bold) ansi.style.no_bold else "");
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

    pub fn deinit(command: Command, allocator: std.mem.Allocator) void {
        for (command.argv) |arg| allocator.free(arg);
        allocator.free(command.argv);
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
    var buf: [32]u8 = undefined;
    var stderr = std.fs.File.stderr().writer(&buf);
    const writer = &stderr.interface;

    if (msg.len == 0) @compileError("no message given");

    blk: {
        writer.writeAll("error: ") catch break :blk;

        writer.print(msg, args) catch break :blk;

        if (msg[msg.len - 1] != '\n') {
            writer.writeAll("\n\n") catch break :blk;
        } else {
            writer.writeByte('\n') catch break :blk;
        }

        writer.writeAll(usage) catch break :blk;
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
