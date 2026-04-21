// SPDX-License-Identifier: BSD-3-Clause
// SPDX-FileCopyrightText: CascadeOS Contributors

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const core = @import("core");
const kernel_options = @import("kernel_options");
const kernel_log_scopes = kernel_options.kernel_log_scopes;

pub fn scoped(comptime scope: @EnumLiteral()) type {
    return struct {
        const scope_name: []const u8 = @tagName(scope);

        pub inline fn err(
            comptime format: []const u8,
            args: anytype,
        ) void {
            if (comptime !levelEnabled(.err)) return;
            logFn(.err, scope_name, comptime userFmt(format), args);
        }

        pub inline fn warn(
            comptime format: []const u8,
            args: anytype,
        ) void {
            if (comptime !levelEnabled(.warn)) return;
            logFn(.warn, scope_name, comptime userFmt(format), args);
        }

        pub inline fn info(
            comptime format: []const u8,
            args: anytype,
        ) void {
            if (comptime !levelEnabled(.info)) return;
            logFn(.info, scope_name, comptime userFmt(format), args);
        }

        pub inline fn debug(
            comptime format: []const u8,
            args: anytype,
        ) void {
            if (comptime !levelEnabled(.debug)) return;
            logFn(.debug, scope_name, comptime userFmt(format), args);
        }

        pub inline fn verbose(
            comptime format: []const u8,
            args: anytype,
        ) void {
            if (comptime !levelEnabled(.verbose)) return;
            logFn(.verbose, scope_name, comptime userFmt(format), args);
        }

        pub inline fn levelEnabled(comptime message_level: Level) bool {
            comptime return loggingEnabledFor(scope, message_level);
        }

        inline fn userFmt(comptime format: []const u8) []const u8 {
            comptime return if (format.len != 0 and format[format.len - 1] == '\n')
                format
            else
                format ++ "\n";
        }

        comptime {
            if (scope_name.len > cascade.config.debug.max_log_scope_len) @compileError("log scope '" ++ scope_name ++ "' to too long");
        }
    };
}

pub const Level = enum {
    err,
    warn,
    info,
    debug,
    verbose,

    pub fn toStd(self: Level) std.log.Level {
        return switch (self) {
            .err => .err,
            .warn => .warn,
            .info => .info,
            .debug, .verbose => .debug,
        };
    }
};

fn logFn(
    level: Level,
    scope: []const u8,
    comptime format: []const u8,
    args: anytype,
) void {
    const t = cascade.init.Output.terminal;

    switch (globals.log_mode) {
        .single_executor_init_log => if (core.is_debug) std.debug.assert(!arch.interrupts.areEnabled()),
        .init_log => cascade.init.Output.lock.lock(),
    }
    defer switch (globals.log_mode) {
        .single_executor_init_log => {},
        .init_log => cascade.init.Output.lock.unlock(),
    };

    logFnInner(t, level, scope, format, args) catch {
        @branchHint(.cold);
        _ = t.writer.consumeAll();
    };
}

fn logFnInner(
    t: std.Io.Terminal,
    level: Level,
    scope: []const u8,
    comptime format: []const u8,
    args: anytype,
) !void {
    try switch (level) {
        .err => t.setColor(.red),
        .warn => t.setColor(.yellow),
        .info => {},
        .debug => t.setColor(.dim),
        .verbose => t.setColor(.dim),
    };

    try t.writer.writeAll(scope);
    try t.writer.splatByteAll(' ', cascade.config.debug.max_log_scope_len - scope.len);
    try t.writer.writeByte('|');

    const level_str = @tagName(level);
    try t.writer.writeAll(level_str);
    try t.writer.splatByteAll(' ', @tagName(Level.verbose).len - level_str.len);

    try t.setColor(.reset);
    try t.writer.writeByte('|');

    try cascade.Task.Current.get().task.format(t.writer);
    try t.writer.writeAll("| ");
    try t.writer.print(format, args);
    try t.writer.flush();
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
        std.debug.panic(
            "invalid log mode transition '{t}' -> '{t}'",
            .{ globals.log_mode, mode },
        );
    }

    globals.log_mode = mode;
}

pub const log_level: Level = blk: {
    if (@hasDecl(kernel_options, "force_log_level")) {
        break :blk switch (kernel_options.force_log_level) {
            .debug => .debug,
            .verbose => .verbose,
        };
    }

    break :blk switch (@import("builtin").mode) {
        .Debug => .info,
        .ReleaseSafe, .ReleaseFast, .ReleaseSmall => .warn,
    };
};

/// Handles translating the std.log API to the kernel log API.
pub fn stdLogImpl(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
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
inline fn loggingEnabledFor(comptime scope: @EnumLiteral(), comptime message_level: Level) bool {
    comptime {
        if (@intFromEnum(message_level) <= @intFromEnum(log_level)) return true;
        if (scopeMatcherMatches(scope)) return true;
        return false;
    }
}

/// Checks if a scope matches one of the scope matchers.
inline fn scopeMatcherMatches(comptime scope: @EnumLiteral()) bool {
    comptime {
        const tag = @tagName(scope);

        for (kernel_log_scope_matchers) |scope_matcher| {
            switch (scope_matcher.type) {
                .exact => if (std.mem.eql(u8, tag, scope_matcher.match_string))
                    return true,
                .starts_with => if (std.mem.startsWith(u8, tag, scope_matcher.match_string))
                    return true,
                .ends_with => if (std.mem.endsWith(u8, tag, scope_matcher.match_string))
                    return true,
                .contains => if (std.mem.indexOf(u8, tag, scope_matcher.match_string)) |_|
                    return true,
            }
        }

        return false;
    }
}

const globals = struct {
    var log_mode: LogMode = .single_executor_init_log;
};

const kernel_log_scope_matchers: [kernel_log_scopes.len]ScopeMatcher = blk: {
    var scope_matchers: [kernel_log_scopes.len]ScopeMatcher = undefined;

    for (kernel_log_scopes, 0..) |scope_string, i| {
        std.debug.assert(scope_string.len != 0);

        const matcher_type: ScopeMatcher.Type = matcher_type: {
            if (scope_string[0] == '+') {
                if (scope_string.len == 1) break :matcher_type .exact;

                if (scope_string[scope_string.len - 1] == '+') {
                    if (scope_string.len == 2) break :matcher_type .exact;

                    break :matcher_type .contains;
                }

                break :matcher_type .ends_with;
            }

            if (scope_string[scope_string.len - 1] == '+')
                break :matcher_type .starts_with;

            break :matcher_type .exact;
        };

        scope_matchers[i] = .{
            .match_string = switch (matcher_type) {
                .exact => scope_string,
                .starts_with => scope_string[0 .. scope_string.len - 1],
                .ends_with => scope_string[1..],
                .contains => scope_string[1 .. scope_string.len - 1],
            },
            .type = matcher_type,
        };
    }

    break :blk scope_matchers;
};

const ScopeMatcher = struct {
    match_string: []const u8,
    type: Type,

    const Type = enum {
        exact,
        starts_with,
        ends_with,
        contains,
    };
};
