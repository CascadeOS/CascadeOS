// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const core = @import("core");
const init = @import("init");
const kernel_options = @import("kernel_options");
const kernel_log_scopes = kernel_options.kernel_log_scopes;

pub fn scoped(comptime scope: @Type(.enum_literal)) type {
    return struct {
        pub fn err(
            context: *cascade.Context,
            comptime format: []const u8,
            args: anytype,
        ) callconv(core.inline_in_non_debug) void {
            if (comptime !levelEnabled(.err)) return;
            logFn(context, prefix_err, userFmt(format), args);
        }

        pub fn warn(
            context: *cascade.Context,
            comptime format: []const u8,
            args: anytype,
        ) callconv(core.inline_in_non_debug) void {
            if (comptime !levelEnabled(.warn)) return;
            logFn(context, prefix_warn, userFmt(format), args);
        }

        pub fn info(
            context: *cascade.Context,
            comptime format: []const u8,
            args: anytype,
        ) callconv(core.inline_in_non_debug) void {
            if (comptime !levelEnabled(.info)) return;
            logFn(context, prefix_info, userFmt(format), args);
        }

        pub fn debug(
            context: *cascade.Context,
            comptime format: []const u8,
            args: anytype,
        ) callconv(core.inline_in_non_debug) void {
            if (comptime !levelEnabled(.debug)) return;
            logFn(context, prefix_debug, userFmt(format), args);
        }

        pub fn verbose(
            context: *cascade.Context,
            comptime format: []const u8,
            args: anytype,
        ) callconv(core.inline_in_non_debug) void {
            if (comptime !levelEnabled(.verbose)) return;
            logFn(context, prefix_verbose, userFmt(format), args);
        }

        pub inline fn levelEnabled(comptime message_level: Level) bool {
            comptime return loggingEnabledFor(scope, message_level);
        }

        const prefix_err = levelAndScope(.err);
        const prefix_warn = levelAndScope(.warn);
        const prefix_info = levelAndScope(.info);
        const prefix_debug = levelAndScope(.debug);
        const prefix_verbose = levelAndScope(.verbose);

        inline fn levelAndScope(comptime message_level: Level) []const u8 {
            comptime return message_level.asText() ++ " | " ++ @tagName(scope) ++ " | ";
        }

        inline fn userFmt(comptime format: []const u8) []const u8 {
            comptime return if (format.len != 0 and format[format.len - 1] == '\n')
                format
            else
                format ++ "\n";
        }
    };
}

pub const Level = enum {
    err,
    warn,
    info,
    debug,
    verbose,

    pub inline fn asText(comptime self: Level) []const u8 {
        return switch (self) {
            .err => "error",
            .warn => "warning",
            .info => "info",
            .debug => "debug",
            .verbose => "verbose",
        };
    }

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
    context: *cascade.Context,
    prefix: []const u8,
    comptime format: []const u8,
    args: anytype,
) void {
    switch (globals.log_mode) {
        .single_executor_init_log => {
            @branchHint(.unlikely);

            if (core.is_debug) std.debug.assert(!arch.interrupts.areEnabled());

            const writer = init.Output.writer;

            writer.writeAll(prefix) catch {
                @branchHint(.cold);
                _ = writer.consumeAll();
                return;
            };

            writer.print("{f} | ", .{context.task()}) catch {
                @branchHint(.cold);
                _ = writer.consumeAll();
                return;
            };

            writer.print(format, args) catch {
                @branchHint(.cold);
                _ = writer.consumeAll();
                return;
            };

            init.Output.writer.flush() catch {
                @branchHint(.cold);
                _ = writer.consumeAll();
                return;
            };
        },
        .init_log => {
            @branchHint(.unlikely);

            init.Output.globals.lock.lock(context);
            defer init.Output.globals.lock.unlock(context);

            const writer = init.Output.writer;

            writer.writeAll(prefix) catch {
                @branchHint(.cold);
                _ = writer.consumeAll();
                return;
            };

            writer.print("{f} | ", .{context.task()}) catch {
                @branchHint(.cold);
                _ = writer.consumeAll();
                return;
            };

            writer.print(format, args) catch {
                @branchHint(.cold);
                _ = writer.consumeAll();
                return;
            };

            init.Output.writer.flush() catch {
                @branchHint(.cold);
                _ = writer.consumeAll();
                return;
            };
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
inline fn loggingEnabledFor(comptime scope: @Type(.enum_literal), comptime message_level: Level) bool {
    comptime {
        if (@intFromEnum(message_level) <= @intFromEnum(log_level)) return true;
        if (scopeMatcherMatches(scope)) return true;
        return false;
    }
}

/// Checks if a scope matches one of the scope matchers.
inline fn scopeMatcherMatches(comptime scope: @Type(.enum_literal)) bool {
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
