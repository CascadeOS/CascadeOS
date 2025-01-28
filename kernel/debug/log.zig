// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>

pub fn scoped(comptime scope: @Type(.enum_literal)) type {
    return struct {
        pub fn err(comptime format: []const u8, args: anytype) callconv(core.inline_in_non_debug) void {
            if (comptime !levelEnabled(.err)) return;
            logFn(scope, .err, format, args);
        }

        pub fn warn(comptime format: []const u8, args: anytype) callconv(core.inline_in_non_debug) void {
            if (comptime !levelEnabled(.warn)) return;
            logFn(scope, .warn, format, args);
        }

        pub fn info(comptime format: []const u8, args: anytype) callconv(core.inline_in_non_debug) void {
            if (comptime !levelEnabled(.info)) return;
            logFn(scope, .info, format, args);
        }

        pub fn debug(comptime format: []const u8, args: anytype) callconv(core.inline_in_non_debug) void {
            if (comptime !levelEnabled(.debug)) return;
            logFn(scope, .debug, format, args);
        }

        pub inline fn levelEnabled(comptime message_level: std.log.Level) bool {
            comptime return loggingEnabledFor(scope, message_level);
        }
    };
}

fn logFn(
    comptime scope: @Type(.enum_literal),
    comptime message_level: std.log.Level,
    comptime format: []const u8,
    args: anytype,
) void {
    const level_and_scope = comptime message_level.asText() ++ " | " ++ @tagName(scope) ++ " | ";

    const user_fmt = comptime if (format.len != 0 and format[format.len - 1] == '\n')
        format
    else
        format ++ "\n";

    switch (globals.log_mode) {
        .single_executor_init_log => {
            @branchHint(.unlikely);

            const writer = globals.init_log_buffered_writer.writer();

            writer.writeAll(level_and_scope) catch {};
            writer.print(user_fmt, args) catch {};

            globals.init_log_buffered_writer.flush() catch {};
        },
        .init_log => {
            @branchHint(.unlikely);

            const current_task = kernel.Task.getCurrent();

            kernel.init.Output.globals.lock.lock(current_task);
            defer kernel.init.Output.globals.lock.unlock(current_task);

            const writer = globals.init_log_buffered_writer.writer();

            writer.writeAll(level_and_scope) catch {};
            writer.print(user_fmt, args) catch {};

            globals.init_log_buffered_writer.flush() catch {};
        },
    }
}

/// The mode the logging system is in.
///
/// The kernel will move through each mode in order as initialization is performed.
///
/// No modes will be skipped and must be in strict increasing order.
pub const LogMode = enum(u8) {
    /// Log will print using init output, does not lock the init output lcok.
    ///
    /// Does not support multiple executors.
    single_executor_init_log,

    /// Log will print using init output, locks the init output lock.
    ///
    /// Supports multiple executors.
    init_log,
};

pub fn setLogMode(mode: LogMode) void {
    if (@intFromEnum(globals.log_mode) + 1 != @intFromEnum(mode)) {
        core.panicFmt(
            "invalid log mode transition '{s}' -> '{s}'",
            .{ @tagName(globals.log_mode), @tagName(mode) },
            null,
        );
    }

    globals.log_mode = mode;
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

/// Determine if a specific scope and log level pair is enabled for logging.
inline fn loggingEnabledFor(comptime scope: @Type(.enum_literal), comptime message_level: std.log.Level) bool {
    comptime return isScopeInForcedDebugScopes(scope) or @intFromEnum(message_level) <= @intFromEnum(log_level);
}

/// Checks if a scope is in the list of scopes forced to log at debug level.
inline fn isScopeInForcedDebugScopes(comptime scope: @Type(.enum_literal)) bool {
    comptime {
        if (kernel.config.forced_debug_log_scopes.len == 0) return false;

        const tag = @tagName(scope);

        for (kernel.config.forced_debug_log_scopes) |debug_scope| {
            if (std.mem.endsWith(u8, debug_scope, "+")) {
                // if this debug_scope ends with a +, then it is a prefix match
                if (std.mem.startsWith(u8, tag, debug_scope[0 .. debug_scope.len - 1])) return true;
            }

            if (std.mem.eql(u8, tag, debug_scope)) return true;
        }

        return false;
    }
}

const globals = struct {
    var log_mode: LogMode = .single_executor_init_log;

    /// Buffered writer used only during init.
    var init_log_buffered_writer = std.io.bufferedWriter(kernel.init.Output.writer);
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const builtin = @import("builtin");
