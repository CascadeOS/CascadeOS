// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const builtin = @import("builtin");
const kernel_options = @import("kernel_options");

pub fn scoped(comptime scope: @Type(.EnumLiteral)) type {
    return struct {
        pub inline fn err(comptime format: []const u8, args: anytype) void {
            if (comptime !levelEnabled(.err)) return;
            init.initLogFn(scope, .err, format, args);
        }

        pub inline fn warn(comptime format: []const u8, args: anytype) void {
            if (comptime !levelEnabled(.warn)) return;
            init.initLogFn(scope, .warn, format, args);
        }

        pub inline fn info(comptime format: []const u8, args: anytype) void {
            if (comptime !levelEnabled(.info)) return;
            init.initLogFn(scope, .info, format, args);
        }

        pub inline fn debug(comptime format: []const u8, args: anytype) void {
            if (comptime !levelEnabled(.debug)) return;
            init.initLogFn(scope, .debug, format, args);
        }

        pub inline fn levelEnabled(comptime message_level: std.log.Level) bool {
            comptime return loggingEnabledFor(scope, message_level);
        }
    };
}

/// Determine if a specific scope and log level pair is enabled for logging.
inline fn loggingEnabledFor(comptime scope: @Type(.EnumLiteral), comptime message_level: std.log.Level) bool {
    comptime return isScopeInForcedDebugScopes(scope) or @intFromEnum(message_level) <= @intFromEnum(log_level);
}

/// Checks if a scope is in the list of scopes forced to log at debug level.
inline fn isScopeInForcedDebugScopes(comptime scope: @Type(.EnumLiteral)) bool {
    if (kernel_options.forced_debug_log_scopes.len == 0) return false;

    const tag = @tagName(scope);

    inline for (kernel_options.forced_debug_log_scopes) |debug_scope| {
        if (std.mem.endsWith(u8, debug_scope, "+")) {
            // if this debug_scope ends with a +, then it is a prefix match
            if (std.mem.startsWith(u8, tag, debug_scope[0 .. debug_scope.len - 1])) return true;
        }

        if (std.mem.eql(u8, tag, debug_scope)) return true;
    }

    return false;
}

pub const log_level: std.log.Level = blk: {
    if (kernel_options.force_debug_log) break :blk .debug;

    break :blk switch (builtin.mode) {
        .Debug => .info,
        .ReleaseSafe => .warn,
        .ReleaseFast, .ReleaseSmall => .err,
    };
};

/// Handles translating the std.log API to the kernel log API.
pub fn stdLogImpl(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    switch (message_level) {
        .debug => scoped(scope).debug(format, args),
        .info => scoped(scope).info(format, args),
        .warn => scoped(scope).warn(format, args),
        .err => scoped(scope).err(format, args),
    }
}

pub const init = struct {
    /// Logging function during kernel init.
    fn initLogFn(
        comptime scope: @Type(.EnumLiteral),
        comptime message_level: std.log.Level,
        comptime format: []const u8,
        args: anytype,
    ) void {
        const user_fmt = comptime if (format.len != 0 and format[format.len - 1] == '\n')
            format
        else
            format ++ "\n";

        const early_output = kernel.arch.init.getEarlyOutput() orelse return;

        early_output.writeAll(
            comptime @tagName(scope) ++ " | " ++ message_level.asText() ++ " | ",
        ) catch unreachable;

        early_output.print(user_fmt, args) catch unreachable;
    }
};
