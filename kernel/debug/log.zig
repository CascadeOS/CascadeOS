// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");
const kernel_options = @import("kernel_options");

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
) void {
    const early_output = kernel.arch.init.getEarlyOutput() orelse return;
    defer early_output.deinit();

    if (kernel.arch.earlyGetProcessor()) |processor| {
        processor.id.print(early_output.writer) catch unreachable;

        if (processor.current_thread) |thread| {
            early_output.writer.writeAll(" | ") catch unreachable;
            thread.print(early_output.writer) catch unreachable;
        } else {
            early_output.writer.writeAll(" | kernel:0") catch unreachable;
        }
    } else {
        early_output.writer.writeAll("?? | kernel:0") catch unreachable;
    }

    early_output.writer.writeAll(" | ") catch unreachable;

    early_output.writer.writeAll(
        comptime @tagName(scope) ++ " | " ++ message_level.asText() ++ " | ",
    ) catch unreachable;

    const user_fmt = comptime if (format.len != 0 and format[format.len - 1] == '\n') format else format ++ "\n";
    early_output.writer.print(user_fmt, args) catch unreachable;
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

/// Determine if a specific scope and log level pair is enabled for logging.
pub inline fn loggingEnabledFor(comptime scope: @Type(.EnumLiteral), comptime message_level: Level) bool {
    comptime return isScopeInForcedDebugScopes(scope) or @intFromEnum(message_level) <= @intFromEnum(level);
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

const level: Level = blk: {
    if (kernel_options.force_debug_log) break :blk .debug;

    if (true) break :blk .info;

    break :blk switch (kernel.info.mode) {
        .Debug => .info,
        .ReleaseSafe => .warn,
        .ReleaseFast, .ReleaseSmall => .err,
    };
};
