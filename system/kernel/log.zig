// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

pub fn scoped(comptime scope: @Type(.enum_literal)) type {
    return struct {
        pub inline fn err(comptime format: []const u8, args: anytype) void {
            if (comptime !levelEnabled(.err)) return;
            logFn(scope, .err, format, args);
        }

        pub inline fn warn(comptime format: []const u8, args: anytype) void {
            if (comptime !levelEnabled(.warn)) return;
            logFn(scope, .warn, format, args);
        }

        pub inline fn info(comptime format: []const u8, args: anytype) void {
            if (comptime !levelEnabled(.info)) return;
            logFn(scope, .info, format, args);
        }

        pub inline fn debug(comptime format: []const u8, args: anytype) void {
            if (comptime !levelEnabled(.debug)) return;
            logFn(scope, .debug, format, args);
        }

        pub inline fn levelEnabled(comptime message_level: std.log.Level) bool {
            comptime return loggingEnabledFor(scope, message_level);
        }
    };
}

pub const log_level: std.log.Level = blk: {
    if (kernel.config.force_debug_log) break :blk .debug;

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

/// The function type for the init log implementation.
pub const InitLogImpl = fn (level_and_scope: []const u8, comptime fmt: []const u8, args: anytype) void;

/// Which logging implementation to use.
///
/// `init` is the early log output, which is only available during the early boot process.
pub var log_impl: enum { init, full } = .init;

/// The main log dispatch function.
fn logFn(
    comptime scope: @Type(.enum_literal),
    comptime message_level: std.log.Level,
    comptime format: []const u8,
    args: anytype,
) void {
    const user_fmt = comptime if (format.len != 0 and format[format.len - 1] == '\n')
        format
    else
        format ++ "\n";

    const level_and_scope = comptime message_level.asText() ++ " | " ++ @tagName(scope) ++ " | ";

    switch (log_impl) {
        .init => @import("root").initLogImpl(level_and_scope, user_fmt, args),
        .full => core.panic("UNIMPLEMENTED", null), // TODO: full log implementation
    }
}

/// Determine if a specific scope and log level pair is enabled for logging.
inline fn loggingEnabledFor(comptime scope: @Type(.enum_literal), comptime message_level: std.log.Level) bool {
    comptime return isScopeInForcedDebugScopes(scope) or @intFromEnum(message_level) <= @intFromEnum(log_level);
}

/// Checks if a scope is in the list of scopes forced to log at debug level.
inline fn isScopeInForcedDebugScopes(comptime scope: @Type(.enum_literal)) bool {
    if (kernel.config.forced_debug_log_scopes.len == 0) return false;

    const tag = @tagName(scope);

    inline for (kernel.config.forced_debug_log_scopes) |debug_scope| {
        if (std.mem.endsWith(u8, debug_scope, "+")) {
            // if this debug_scope ends with a +, then it is a prefix match
            if (std.mem.startsWith(u8, tag, debug_scope[0 .. debug_scope.len - 1])) return true;
        }

        if (std.mem.eql(u8, tag, debug_scope)) return true;
    }

    return false;
}

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const builtin = @import("builtin");
const arch = @import("arch");
