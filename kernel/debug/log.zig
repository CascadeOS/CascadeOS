// SPDX-License-Identifier: MIT

const arch = kernel.arch;
const core = @import("core");
const info = kernel.info;
const kernel = @import("kernel");
const kernel_options = @import("kernel_options");
const std = @import("std");

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

        pub inline fn levelEnabled(comptime message_level: Level) bool {
            comptime return loggingEnabledFor(scope, message_level);
        }
    };
}

fn logFnDispatch(
    comptime scope: @Type(.EnumLiteral),
    comptime message_level: Level,
    comptime format: []const u8,
    args: anytype,
) void {
    // TODO per branch cold
    if (initialized) {
        standardLogFn(scope, message_level, format, args);
    } else {
        earlyLogFn(scope, message_level, format, args);
    }
}

/// Main logging function used after kernel init is finished
fn standardLogFn(
    comptime scope: @Type(.EnumLiteral),
    comptime message_level: Level,
    comptime format: []const u8,
    args: anytype,
) void {
    _ = args;
    _ = format;
    _ = message_level;
    _ = scope;

    core.panic("UNIMPLEMENTED `standardLogFn`");
}

/// Logging function for early boot only.
fn earlyLogFn(
    comptime scope: @Type(.EnumLiteral),
    comptime message_level: Level,
    comptime format: []const u8,
    args: anytype,
) linksection(info.init_code) void {
    const writer = arch.init.getEarlyOutputWriter() orelse return;

    const scopeAndLevelText = comptime formatScopeAndLevel(message_level, scope);
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

const maximum_log_scope_length = 18;

/// Helper function to format the scope and level text at the beginning of a log message.
inline fn formatScopeAndLevel(
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
    comptime return isScopeInForcedDebugScopes(scope) or @intFromEnum(message_level) <= @intFromEnum(level);
}

/// Checks if a scope is in the list of scopes forced to log at debug level.
inline fn isScopeInForcedDebugScopes(comptime scope: @Type(.EnumLiteral)) bool {
    if (kernel_options.forced_debug_log_scopes.len == 0) return false;
    return comptime debug_scopes.has(@tagName(scope));
}

const debug_scopes = std.ComptimeStringMap(
    void,
    blk: {
        var scopes: [kernel_options.forced_debug_log_scopes.len]struct { []const u8 } = undefined;

        for (kernel_options.forced_debug_log_scopes, 0..) |debug_scope, i| {
            scopes[i] = .{debug_scope};
        }

        break :blk scopes;
    },
);

const level: Level = blk: {
    if (kernel_options.force_debug_log) break :blk .debug;

    if (true) break :blk .info;

    break :blk switch (info.mode) {
        .Debug => .info,
        .ReleaseSafe => .warn,
        .ReleaseFast, .ReleaseSmall => .err,
    };
};
