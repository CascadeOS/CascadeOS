// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

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

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const command = try getCommand(allocator);
    defer command.deinit(allocator);

    var child = std.process.Child.init(command.argv, allocator);
    child.stdout_behavior = .Pipe;
    try child.spawn();

    var poller = std.io.poll(allocator, enum { stdout }, .{
        .stdout = child.stdout.?,
    });
    defer poller.deinit();
    const stdout_fifo = poller.fifo(.stdout);

    const stdout = std.io.getStdOut();

    var partial_read_buffer = std.ArrayList(u8).init(allocator);
    defer partial_read_buffer.deinit();

    while (try poller.poll()) {
        if (stdout_fifo.count == 0) continue;

        var stdout_window = stdout_fifo.readableSlice(0);

        while (stdout_window.len != 0) {
            const newline_index = std.mem.indexOfScalar(
                u8,
                stdout_window,
                '\n',
            ) orelse {
                // no newline found, store this partial line read in the partial read buffer
                try partial_read_buffer.appendSlice(stdout_window);
                break;
            };
            const next_line_index = newline_index + 1;

            if (partial_read_buffer.items.len != 0) {
                try partial_read_buffer.appendSlice(stdout_window[0..next_line_index]);
                try handleLine(allocator, stdout, partial_read_buffer.items);
                partial_read_buffer.clearRetainingCapacity();
            } else {
                try handleLine(allocator, stdout, stdout_window[0..next_line_index]);
            }

            stdout_window = stdout_window[next_line_index..];
        }

        stdout_fifo.discard(stdout_fifo.count);
    }

    if (partial_read_buffer.items.len != 0) {
        try handleLine(allocator, stdout, partial_read_buffer.items);
    }

    // the above loop will exit when the child closes its stdout, which usually means the child has exited
    _ = try child.wait();
}

/// Handles a single line of output from the child process.
fn handleLine(allocator: std.mem.Allocator, stdout: std.fs.File, line: []const u8) !void {
    _ = allocator;

    inline for (rules) |rule| {
        if (std.mem.startsWith(u8, line, rule.pattern)) {
            const formatted_string = comptime rule.buildFormattedString();
            // std.debug.print("RAW: '{}'\n", .{std.fmt.fmtSliceEscapeLower(formatted_string)});
            try stdout.writeAll(formatted_string);
            try stdout.writeAll(line[rule.pattern.len..]);
            return;
        }
    }

    try stdout.writeAll(line);
}

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

comptime {
    refAllDeclsRecursive(@This());
}

// Copy of `std.testing.refAllDeclsRecursive`, being in the file give access to private decls.
fn refAllDeclsRecursive(comptime T: type) void {
    if (!@import("builtin").is_test) return;

    inline for (switch (@typeInfo(T)) {
        .@"struct" => |info| info.decls,
        .@"enum" => |info| info.decls,
        .@"union" => |info| info.decls,
        .@"opaque" => |info| info.decls,
        else => @compileError("Expected struct, enum, union, or opaque type, found '" ++ @typeName(T) ++ "'"),
    }) |decl| {
        if (@TypeOf(@field(T, decl.name)) == type) {
            switch (@typeInfo(@field(T, decl.name))) {
                .@"struct", .@"enum", .@"union", .@"opaque" => refAllDeclsRecursive(@field(T, decl.name)),
                else => {},
            }
        }
        _ = &@field(T, decl.name);
    }
}
