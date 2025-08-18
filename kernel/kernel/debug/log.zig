// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub fn scoped(comptime scope: @Type(.enum_literal)) type {
    return struct {
        pub fn err(
            context: *kernel.Task.Context,
            comptime format: []const u8,
            args: anytype,
        ) callconv(core.inline_in_non_debug) void {
            if (comptime !levelEnabled(.err)) return;
            logFn(context, prefix_err, userFmt(format), args);
        }

        pub fn warn(
            context: *kernel.Task.Context,
            comptime format: []const u8,
            args: anytype,
        ) callconv(core.inline_in_non_debug) void {
            if (comptime !levelEnabled(.warn)) return;
            logFn(context, prefix_warn, userFmt(format), args);
        }

        pub fn info(
            context: *kernel.Task.Context,
            comptime format: []const u8,
            args: anytype,
        ) callconv(core.inline_in_non_debug) void {
            if (comptime !levelEnabled(.info)) return;
            logFn(context, prefix_info, userFmt(format), args);
        }

        pub fn debug(
            context: *kernel.Task.Context,
            comptime format: []const u8,
            args: anytype,
        ) callconv(core.inline_in_non_debug) void {
            if (comptime !levelEnabled(.debug)) return;
            logFn(context, prefix_debug, userFmt(format), args);
        }

        pub fn verbose(
            context: *kernel.Task.Context,
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
    context: *kernel.Task.Context,
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
        if (isScopeInForceScopeList(scope, kernel_log_scopes)) return true;
        return false;
    }
}

/// Checks if a scope is in the list of forced scopes.
inline fn isScopeInForceScopeList(comptime scope: @Type(.enum_literal), comptime force_scope_list: []const []const u8) bool {
    comptime {
        if (force_scope_list.len == 0) return false;

        const tag = @tagName(scope);

        for (force_scope_list) |forced_scope| {
            if (std.mem.endsWith(u8, forced_scope, "+")) {
                // if this forced_scope ends with a +, then it is a prefix match
                if (std.mem.startsWith(u8, tag, forced_scope[0 .. forced_scope.len - 1])) return true;
            }

            if (std.mem.eql(u8, tag, forced_scope)) return true;
        }

        return false;
    }
}

const globals = struct {
    var log_mode: LogMode = .single_executor_init_log;
};

const kernel_log_scopes = kernel_options.kernel_log_scopes;

const arch = @import("arch");
const kernel = @import("kernel");
const init = @import("init");

const core = @import("core");
const kernel_options = @import("kernel_options");
const std = @import("std");
