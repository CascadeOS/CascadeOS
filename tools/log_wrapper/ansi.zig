// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>
// SPDX-FileCopyrightText: Copyright (c) 2022 Diego Barria (https://github.com/xyaman/mibu/blob/main/LICENSE)

pub const style = struct {
    pub const reset = comptimeCsi("0m", .{});

    pub const bold = comptimeCsi("1m", .{});
    pub const no_bold = comptimeCsi("22m", .{});

    pub const dim = comptimeCsi("2m", .{});
    pub const no_dim = comptimeCsi("22m", .{});

    pub const italic = comptimeCsi("3m", .{});
    pub const no_italic = comptimeCsi("23m", .{});

    pub const underline = comptimeCsi("4m", .{});
    pub const no_underline = comptimeCsi("24m", .{});

    pub const blinking = comptimeCsi("5m", .{});
    pub const no_blinking = comptimeCsi("25m", .{});

    pub const reverse = comptimeCsi("7m", .{});
    pub const no_reverse = comptimeCsi("27m", .{});

    pub const invisible = comptimeCsi("8m", .{});
    pub const no_invisible = comptimeCsi("28m", .{});

    pub const strikethrough = comptimeCsi("9m", .{});
    pub const no_strikethrough = comptimeCsi("29m", .{});
};

pub const clear = struct {
    pub const screen_from_cursor = comptimeCsi("0J", .{});

    pub const screen_to_cursor = comptimeCsi("1J", .{});

    pub const all = comptimeCsi("2J", .{});

    pub const line_from_cursor = comptimeCsi("0K", .{});

    pub const line_to_cursor = comptimeCsi("1K", .{});

    pub const line = comptimeCsi("2K", .{});
};

pub const color = struct {
    pub inline fn fg(comptime c: Color) []const u8 {
        return comptimeCsi("38;5;{d}m", .{@intFromEnum(c)});
    }

    pub inline fn bg(comptime c: Color) []const u8 {
        return comptimeCsi("48;5;{d}m", .{@intFromEnum(c)});
    }

    pub inline fn fgRGB(rgb: RGB) []const u8 {
        var buf: [22]u8 = undefined;
        return std.fmt.bufPrint(
            &buf,
            "\x1b[38;2;{d};{d};{d}m",
            .{ rgb.r, rgb.g, rgb.b },
        ) catch unreachable;
    }

    pub inline fn bgRGB(rgb: RGB) []const u8 {
        var buf: [22]u8 = undefined;
        return std.fmt.bufPrint(
            &buf,
            "\x1b[48;2;{d};{d};{d}m",
            .{ rgb.r, rgb.g, rgb.b },
        ) catch unreachable;
    }

    pub const reset_bg = comptimeCsi("49m", .{});
    pub const reset_fg = comptimeCsi("39m", .{});
};

pub const Color = enum(u8) {
    black = 0,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    white,
    default,
};

pub const RGB = struct {
    r: u8,
    g: u8,
    b: u8,

    pub const black = RGB{ .r = 0, .g = 0, .b = 0 };
    pub const white = RGB{ .r = 255, .g = 255, .b = 255 };
};

pub const cursor = struct {
    pub inline fn goTo(x: anytype, y: anytype) []const u8 {
        var buf: [30]u8 = undefined;
        return std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ y, x }) catch unreachable;
    }

    pub inline fn goUp(y: anytype) []const u8 {
        var buf: [30]u8 = undefined;
        return std.fmt.bufPrint(&buf, "\x1b[{d}A", .{y}) catch unreachable;
    }

    pub inline fn goDown(y: anytype) []const u8 {
        var buf: [30]u8 = undefined;
        return std.fmt.bufPrint(&buf, "\x1b[{d}A", .{y}) catch unreachable;
    }

    pub inline fn goLeft(x: anytype) []const u8 {
        var buf: [30]u8 = undefined;
        return std.fmt.bufPrint(&buf, "\x1b[{d}D", .{x}) catch unreachable;
    }

    pub inline fn goRight(x: anytype) []const u8 {
        var buf: [30]u8 = undefined;
        return std.fmt.bufPrint(&buf, "\x1b[{d}C", .{x}) catch unreachable;
    }

    pub inline fn hide() []const u8 {
        return comptimeCsi("?25l", .{});
    }

    pub inline fn show() []const u8 {
        return comptimeCsi("?25h", .{});
    }

    pub inline fn save() []const u8 {
        return comptimeCsi("u", .{});
    }

    pub inline fn restore() []const u8 {
        return comptimeCsi("s", .{});
    }
};

const esc = "\x1B";
const csi = esc ++ "[";

inline fn comptimeCsi(comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.comptimePrint(csi ++ fmt, args);
}

const std = @import("std");
const core = @import("core");

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
