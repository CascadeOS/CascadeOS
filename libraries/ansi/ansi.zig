// SPDX-License-Identifier: MIT

const std = @import("std");

/// Resets all text attributes to default.
pub const reset = comptimeCsi("0m");

/// Enables bold text.
pub const bold = comptimeCsi("1m");

/// Disables bold text.
pub const no_bold = comptimeCsi("22m");

/// Enables dim text.
pub const dim = comptimeCsi("2m");

/// Disables dim text.
pub const no_dim = comptimeCsi("22m");

/// Enables text underlining.
pub const underline = comptimeCsi("4m");

/// Disables text underlining.
pub const no_underline = comptimeCsi("24m");

/// Enables text blinking.
pub const blinking = comptimeCsi("5m");

/// Disables text blinking.
pub const no_blinking = comptimeCsi("25m");

/// Adds strikethrough effect to text.
pub const strikethrough = comptimeCsi("9m");

/// Removes strikethrough effect from text.
pub const no_strikethrough = comptimeCsi("29m");

pub const clear = struct {
    /// Clears the entire screen.
    pub const all = comptimeCsi("2J");

    /// Clears the current line.
    pub const line = comptimeCsi("2K");

    /// Clears from the cursor position to the end of the line.
    pub const line_from_cursor = comptimeCsi("0K");

    /// Clears from the beginning of the line to the cursor position.
    pub const line_to_cursor = comptimeCsi("1K");

    /// Clears the screen from the cursor position to the end of the screen.
    pub const screen_from_cursor = comptimeCsi("0J");

    /// Clears the screen from the beginning of the screen to the cursor position.
    pub const screen_to_cursor = comptimeCsi("1J");
};

pub const cursor = struct {
    /// Moves the cursor to the given position.
    /// Returns a slice into the provided buffer `buf`.
    pub fn bufGoTo(buf: []u8, x: usize, y: usize) std.fmt.BufPrintError![]const u8 {
        return std.fmt.bufPrint(buf, "{d};{d}H", .{ x, y });
    }

    /// Moves the cursor to the given position.
    /// Returns a comptime known immutable slice.
    pub inline fn goTo(comptime x: usize, comptime y: usize) []const u8 {
        return comptime comptimeCsiFmt("{d};{d}H", .{ x, y });
    }
};

pub const color = struct {
    pub const bg = struct {
        /// Resets the background color to default.
        pub const reset = comptimeCsi("49m");
        pub const black = makeColor(false, .black);
        pub const red = makeColor(false, .red);
        pub const green = makeColor(false, .green);
        pub const yellow = makeColor(false, .yellow);
        pub const blue = makeColor(false, .blue);
        pub const magenta = makeColor(false, .magenta);
        pub const cyan = makeColor(false, .cyan);
        pub const white = makeColor(false, .white);

        /// Sets the background color to an RGB value.
        /// Returns a slice into the provided buffer `buf`.
        pub fn bufRgb(buf: []u8, r: u8, g: u8, b: u8) std.fmt.BufPrintError![]const u8 {
            return std.fmt.bufPrint(buf, "48;2;{d};{d};{d}m", .{ r, g, b });
        }

        /// Sets the background color to an RGB value.
        /// Returns a comptime known immutable slice.
        pub inline fn rgb(comptime r: u8, comptime g: u8, comptime b: u8) []const u8 {
            return comptime comptimeCsiFmt("48;2;{d};{d};{d}m", .{ r, g, b });
        }
    };

    pub const fg = struct {
        /// Resets the foreground color to default.
        pub const reset = comptimeCsi("39m");

        pub const black = makeColor(true, .black);
        pub const red = makeColor(true, .red);
        pub const green = makeColor(true, .green);
        pub const yellow = makeColor(true, .yellow);
        pub const blue = makeColor(true, .blue);
        pub const magenta = makeColor(true, .magenta);
        pub const cyan = makeColor(true, .cyan);
        pub const white = makeColor(true, .white);

        /// Sets the foreground color to an RGB value.
        /// Returns a slice into the provided buffer `buf`.
        pub fn bufRgb(buf: []u8, r: u8, g: u8, b: u8) std.fmt.BufPrintError![]const u8 {
            return std.fmt.bufPrint(buf, "38;2;{d};{d};{d}m", .{ r, g, b });
        }

        /// Sets the foreground color to an RGB value.
        /// Returns a comptime known immutable slice.
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
    };

    /// Construct a comptime slice to set the given color for foreground or background.
    inline fn makeColor(comptime foreground: bool, comptime c: Color) []const u8 {
        return comptimeCsiFmt(if (foreground) "38;5;{d}m" else "48;5;{d}m", .{@intFromEnum(c)});
    }
};

const csi = "\x1b[";

/// Concatenates the CSI escape code prefix with the given string at compile-time.
inline fn comptimeCsi(comptime fmt: []const u8) []const u8 {
    return csi ++ fmt;
}

test comptimeCsi {
    try std.testing.expectEqualSlices(u8, "\x1b[12ab", comptimeCsi("12ab"));
}

/// Concatenates the CSI escape code prefix with the given format string and format arguments at compile-time.
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
            if (!first) continue;

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
