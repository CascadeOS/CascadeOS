// SPDX-License-Identifier: MIT

const std = @import("std");

pub const reset = comptimeCsi("0m");
pub const bold = comptimeCsi("1m");
pub const no_bold = comptimeCsi("22m");
pub const dim = comptimeCsi("2m");
pub const no_dim = comptimeCsi("22m");
pub const italic = comptimeCsi("3m");
pub const no_italic = comptimeCsi("23m");
pub const underline = comptimeCsi("4m");
pub const no_underline = comptimeCsi("24m");
pub const blinking = comptimeCsi("5m");
pub const no_blinking = comptimeCsi("25m");
pub const reverse = comptimeCsi("7m");
pub const no_reverse = comptimeCsi("27m");
pub const invisible = comptimeCsi("8m");
pub const no_invisible = comptimeCsi("28m");
pub const strikethrough = comptimeCsi("9m");
pub const no_strikethrough = comptimeCsi("29m");

pub const clear = struct {
    pub const all = comptimeCsi("2J");
    pub const line = comptimeCsi("2K");
    pub const line_from_cursor = comptimeCsi("0K");
    pub const line_to_cursor = comptimeCsi("1K");
    pub const screen_from_cursor = comptimeCsi("0J");
    pub const screen_to_cursor = comptimeCsi("1J");
};

pub const cursor = struct {
    pub fn bufGoTo(buf: []u8, x: usize, y: usize) std.fmt.BufPrintError![]const u8 {
        return std.fmt.bufPrint(buf, "{d};{d}H", .{ x, y });
    }

    pub inline fn goTo(comptime x: usize, comptime y: usize) []const u8 {
        return comptime comptimeCsiFmt("{d};{d}H", .{ x, y });
    }
};

pub const color = struct {
    pub const bg = struct {
        pub const reset = comptimeCsi("49m");

        pub const black = makeColor(false, .black);
        pub const red = makeColor(false, .red);
        pub const green = makeColor(false, .green);
        pub const yellow = makeColor(false, .yellow);
        pub const blue = makeColor(false, .blue);
        pub const magenta = makeColor(false, .magenta);
        pub const cyan = makeColor(false, .cyan);
        pub const white = makeColor(false, .white);
        pub const default = makeColor(false, .default);

        pub fn bufRgb(buf: []u8, r: u8, g: u8, b: u8) std.fmt.BufPrintError![]const u8 {
            return std.fmt.bufPrint(buf, "48;2;{d};{d};{d}m", .{ r, g, b });
        }

        pub inline fn rgb(comptime r: u8, comptime g: u8, comptime b: u8) []const u8 {
            return comptime comptimeCsiFmt("48;2;{d};{d};{d}m", .{ r, g, b });
        }
    };

    pub const fg = struct {
        pub const reset = comptimeCsi("39m");

        pub const black = makeColor(true, .black);
        pub const red = makeColor(true, .red);
        pub const green = makeColor(true, .green);
        pub const yellow = makeColor(true, .yellow);
        pub const blue = makeColor(true, .blue);
        pub const magenta = makeColor(true, .magenta);
        pub const cyan = makeColor(true, .cyan);
        pub const white = makeColor(true, .white);
        pub const default = makeColor(true, .default);

        pub fn bufRgb(buf: []u8, r: u8, g: u8, b: u8) std.fmt.BufPrintError![]const u8 {
            return std.fmt.bufPrint(buf, "38;2;{d};{d};{d}m", .{ r, g, b });
        }

        pub inline fn rgb(comptime r: u8, comptime g: u8, comptime b: u8) []const u8 {
            return comptime comptimeCsiFmt("38;2;{d};{d};{d}m", .{ r, g, b });
        }
    };

    const Color = enum(u8) {
        black = 0,
        red = 1,
        green = 2,
        yellow = 3,
        blue = 4,
        magenta = 5,
        cyan = 6,
        white = 7,
        default = 8,
    };

    inline fn makeColor(comptime foreground: bool, comptime c: Color) []const u8 {
        return comptimeCsiFmt(if (foreground) "38;5;{d}m" else "48;5;{d}m", .{@enumToInt(c)});
    }
};

const csi = "\x1b[";

inline fn comptimeCsi(comptime fmt: []const u8) []const u8 {
    return csi ++ fmt;
}

test comptimeCsi {
    try std.testing.expectEqualSlices(u8, "\x1b[12ab", comptimeCsi("12ab"));
}

inline fn comptimeCsiFmt(comptime fmt: []const u8, args: anytype) []const u8 {
    return comptime std.fmt.comptimePrint(csi ++ fmt, args);
}

test comptimeCsiFmt {
    try std.testing.expectEqualSlices(u8, "\x1b[12ab34", comptimeCsiFmt("12{s}34", .{"ab"}));
}

comptime {
    refAllDeclsRecursive(@This(), true);
}

fn refAllDeclsRecursive(comptime T: type, comptime first: bool) void {
    comptime {
        if (!@import("builtin").is_test) return;

        inline for (std.meta.declarations(T)) |decl| {
            // don't analyze if the decl is not pub unless we are the first level of this call chain
            if (!first and !decl.is_pub) continue;

            if (std.mem.eql(u8, decl.name, "std")) continue;

            if (!@hasDecl(T, decl.name)) continue;

            defer _ = @field(T, decl.name);

            if (@TypeOf(@field(T, decl.name)) != type) continue;

            switch (@typeInfo(@field(T, decl.name))) {
                .Struct, .Enum, .Union, .Opaque => refAllDeclsRecursive(@field(T, decl.name), false),
                else => {},
            }
        }
        return;
    }
}
