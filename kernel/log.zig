// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("root");

var initialized: bool = false;

pub fn scoped(comptime scope: @Type(.EnumLiteral)) type {
    return struct {
        pub inline fn err(comptime format: []const u8, args: anytype) void {
            if (comptime !levelEnabled(.err)) return;
            logFnDispatch(scope, .err, format, args);
        }

        pub inline fn warn(comptime format: []const u8, args: anytype) void {
            if (comptime !levelEnabled(.warn)) return;
            logFnDispatch(scope, .warn, format, args);
        }

        pub inline fn info(comptime format: []const u8, args: anytype) void {
            if (comptime !levelEnabled(.info)) return;
            logFnDispatch(scope, .info, format, args);
        }

        pub inline fn debug(comptime format: []const u8, args: anytype) void {
            if (comptime !levelEnabled(.debug)) return;
            logFnDispatch(scope, .debug, format, args);
        }

        pub inline fn levelEnabled(comptime message_level: kernel.log.Level) bool {
            comptime return loggingEnabledFor(scope, message_level);
        }
    };
}

fn logFnDispatch(
    comptime scope: @Type(.EnumLiteral),
    comptime message_level: kernel.log.Level,
    comptime format: []const u8,
    args: anytype,
) void {
    // TODO Use per branch cold: https://github.com/ziglang/zig/issues/5177
    if (initialized) {
        standardLogFn(scope, message_level, format, args);
    } else {
        earlyLogFn(scope, message_level, format, args);
    }
}

/// Main logging function used after system setup is finished
fn standardLogFn(
    comptime scope: @Type(.EnumLiteral),
    comptime message_level: kernel.log.Level,
    comptime format: []const u8,
    args: anytype,
) void {
    _ = args;
    _ = format;
    _ = message_level;
    _ = scope;

    core.panic("UNIMPLEMENTED `standardLogFn`"); // TODO: implement standardLogFn
}

/// Logging function for early boot only.
fn earlyLogFn(
    comptime scope: @Type(.EnumLiteral),
    comptime message_level: kernel.log.Level,
    comptime format: []const u8,
    args: anytype,
) void {
    const writer = kernel.arch.setup.getEarlyOutputWriter();

    const scopeAndLevelText = comptime kernel.log.formatScopeAndLevel(message_level, scope);
    writer.writeAll(scopeAndLevelText) catch unreachable;

    const user_fmt = comptime if (format.len != 0 and format[format.len - 1] == '\n') format else format ++ "\n";
    writer.print(user_fmt, args) catch unreachable;
}

pub const Level = enum {
    /// Error: something has gone wrong. This might be recoverable or might be followed by the program exiting.
    err,
    /// Warning: it is uncertain if something has gone wrong or not, but the circumstances would be worth investigating.
    warn,
    /// Info: general messages about the state of the program.
    info,
    /// Debug: messages only useful for debugging.
    debug,

    /// Returns a string literal of the given level in full text form.
    pub inline fn asText(comptime self: Level) []const u8 {
        comptime return switch (self) {
            .err => "error",
            .warn => "warning",
            .info => "info",
            .debug => "debug",
        };
    }
};

const maximum_log_scope_length = 15;

pub inline fn formatScopeAndLevel(
    comptime message_level: Level,
    comptime scope: @TypeOf(.EnumLiteral),
) []const u8 {
    const tag: []const u8 = tag: {
        const tag = @tagName(scope);
        if (tag.len > maximum_log_scope_length) {
            // if the scope is longer than `maximum_log_scope_length` then display it truncated by '..'
            var tag_buf = [_]u8{'.'} ** maximum_log_scope_length;
            // `-2` in order to leave '..' at the end of the `tag_buf` array
            std.mem.copy(u8, &tag_buf, tag[0..(maximum_log_scope_length - 2)]);
            break :tag &tag_buf;
        }
        break :tag tag;
    };

    const tag_padding = [_]u8{' '} ** (maximum_log_scope_length - tag.len);

    const level_txt = message_level.asText();
    // `7` is the length of the longest `Level` variant
    const level_padding = [_]u8{' '} ** (7 - level_txt.len);

    comptime return tag ++ tag_padding ++ " | " ++ level_txt ++ level_padding ++ " | ";
}

/// Determine if a specific scope and log level pair is enabled for logging.
inline fn loggingEnabledFor(comptime scope: @Type(.EnumLiteral), comptime message_level: Level) bool {
    comptime return isScopeInForcedDebugScopes(scope) or @enumToInt(message_level) <= @enumToInt(level);
}

inline fn isScopeInForcedDebugScopes(comptime scope: @Type(.EnumLiteral)) bool {
    const scope_name = @tagName(scope);
    inline for (kernel.info.scopes_to_force_debug) |debug_scope| {
        if (std.mem.indexOf(u8, scope_name, debug_scope) != null) return true;
    }
    return false;
}

const level: Level = blk: {
    if (kernel.info.force_debug_log) break :blk .debug;

    // TODO: Once the kernel matures use per mode logging levels
    if (true) break :blk .info;

    break :blk switch (kernel.info.mode) {
        .Debug => .info,
        .ReleaseSafe => .warn,
        .ReleaseFast, .ReleaseSmall => .err,
    };
};
