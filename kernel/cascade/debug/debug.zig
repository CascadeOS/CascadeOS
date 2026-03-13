// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");

pub const log = @import("log.zig");

pub fn hasAnExecutorPanicked() bool {
    return globals.panicking_executor.load(.acquire) != null;
}

pub fn interruptSourcePanic(
    interrupt_frame: arch.interrupts.InterruptFrame,
    comptime format: []const u8,
    args: anytype,
) noreturn {
    @branchHint(.cold);

    const current_task: cascade.Task.Current = .get();

    current_task.incrementInterruptDisable(); // ensure the executor is not going to change underneath us
    const executor = current_task.knownExecutor();

    panicDispatch(
        executor.renderInterruptSourcePanicMessage(format, args),
        .{ .interrupt = interrupt_frame },
    );
}

const PanicType = union(enum) {
    normal: struct {
        return_address: usize,
        error_return_trace: ?*const std.builtin.StackTrace,
    },
    interrupt: arch.interrupts.InterruptFrame,
};

fn panicDispatch(
    msg: []const u8,
    panic_type: PanicType,
) noreturn {
    @branchHint(.cold);

    arch.interrupts.disable();

    switch (globals.panic_mode) {
        .no_op => {},
        .single_executor_init_panic => singleExecutorInitPanic(msg, panic_type),
        .init_panic => initPanic(.panicked(), msg, panic_type),
    }

    arch.interrupts.disableAndHalt();
}

fn singleExecutorInitPanic(
    msg: []const u8,
    panic_type: PanicType,
) void {
    const static = struct {
        var nested_panic_count: usize = 0;
    };

    cascade.init.Output.lock.poison();
    const t: std.Io.Terminal = .{ .writer = cascade.init.Output.writer, .mode = .escape_codes };

    const nested_panic_count = static.nested_panic_count;
    static.nested_panic_count += 1;

    switch (nested_panic_count) {
        // on first panic attempt to print the full panic message
        0 => printPanic(t, msg, panic_type) catch {},
        // on second panic print a shorter message
        1 => {
            t.setColor(.red) catch {};
            t.writer.writeAll("\nPANIC IN PANIC\n") catch {};
            t.setColor(.reset) catch {};
        },
        // don't trigger any more panics
        else => return,
    }

    t.writer.flush() catch {};
}

fn initPanic(
    current_task: cascade.Task.Current,
    msg: []const u8,
    panic_type: PanicType,
) void {
    const static = struct {
        var nested_panic_count: usize = 0;
    };

    const executor = current_task.knownExecutor();

    if (globals.panicking_executor.cmpxchgStrong(
        null,
        executor,
        .acq_rel,
        .acquire,
    )) |panicking_executor| {
        if (panicking_executor != executor) return; // another executor is panicking
    }

    cascade.init.Output.lock.poison();
    const t: std.Io.Terminal = .{ .writer = cascade.init.Output.writer, .mode = .escape_codes };

    arch.interrupts.sendPanicIPI();

    const nested_panic_count = static.nested_panic_count;
    static.nested_panic_count += 1;

    switch (nested_panic_count) {
        // on first panic attempt to print the full panic message
        0 => printPanic(t, msg, panic_type) catch {},
        // on second panic print a shorter message
        1 => {
            t.setColor(.red) catch {};
            t.writer.writeAll("\nPANIC IN PANIC\n") catch {};
            t.setColor(.reset) catch {};
        },
        // don't trigger any more panics
        else => return,
    }

    t.writer.flush() catch {};
}

fn printPanic(
    t: std.Io.Terminal,
    msg: []const u8,
    panic_type: PanicType,
) !void {
    try t.writer.writeByte('\n');
    try t.setColor(.red);
    try t.writer.writeAll("PANIC");
    try t.setColor(.reset);

    if (msg.len != 0) {
        try t.writer.writeAll(" - ");

        try t.writer.writeAll(msg);

        if (msg[msg.len - 1] != '\n') {
            try t.writer.writeByte('\n');
        }
    } else {
        try t.writer.writeByte('\n');
    }

    switch (panic_type) {
        .normal => |normal| {
            if (normal.error_return_trace) |trace| if (trace.index != 0) {
                try t.writer.writeAll("error return context:\n");
                try std.debug.writeStackTrace(trace, t);
                try t.writer.writeAll("\nstack trace:\n");
            };
            try std.debug.writeCurrentStackTrace(.{ .first_address = normal.return_address }, t);
        },
        .interrupt => |interrupt| {
            var context: std.debug.cpu_context.Native = undefined;
            interrupt.fillContext(&context);
            try std.debug.writeCurrentStackTrace(.{ .context = &context }, t);
        },
    }
}

/// The panic mode the kernel is in.
///
/// The kernel will move through each mode in order as initialization is performed.
///
/// No modes will be skipped and must be in strict increasing order.
pub const PanicMode = enum(u8) {
    /// Panic will disable interrupts and halt the current executor.
    ///
    /// The current task is not guaranteed to be valid.
    no_op,

    /// Panic will print using init output with no locking.
    ///
    /// Does not support multiple executors.
    single_executor_init_panic,

    /// Panic will print using init output, poisons the init output lock.
    ///
    /// Supports multiple executors.
    init_panic,
};

pub fn setPanicMode(mode: PanicMode) void {
    if (@intFromEnum(globals.panic_mode) + 1 != @intFromEnum(mode)) {
        std.debug.panic(
            "invalid panic mode transition '{t}' -> '{t}'",
            .{ globals.panic_mode, mode },
        );
    }

    globals.panic_mode = mode;
}

pub const panic_interface = std.debug.FullPanic(zigPanic);

/// Entry point from the Zig language upon a panic.
fn zigPanic(
    msg: []const u8,
    return_address_opt: ?usize,
) noreturn {
    @branchHint(.cold);
    panicDispatch(
        msg,
        .{ .normal = .{
            .return_address = return_address_opt orelse @returnAddress(),
            .error_return_trace = @errorReturnTrace(),
        } },
    );
}

pub const std_debug_exports = struct {
    pub const SelfInfo = @import("SelfInfo.zig");
    pub const printLineFromFile = SelfInfo.printLineFromFile;
    pub const getDebugInfoAllocator = SelfInfo.getDebugInfoAllocator;
};

const globals = struct {
    /// The executor that is currently panicking.
    ///
    /// Checked by executors to confirm receiving a panic IPI.
    var panicking_executor: std.atomic.Value(?*const cascade.Executor) = .init(null);

    var panic_mode: PanicMode = .no_op;
};
