// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

pub const PanicState = enum(u8) {
    no_op = 0,
    simple = 1,
    full = 2,
};

var state: PanicState = .no_op;

/// Switches the panic state to the given state.
/// Panics if the new state is less than the current state.
pub fn switchTo(new_state: PanicState) void {
    if (@enumToInt(state) < @enumToInt(new_state)) {
        state = new_state;
        return;
    }

    core.panicFmt("cannot switch to {s} panic from {s} panic", .{ @tagName(new_state), @tagName(state) });
}

/// Entry point from the Zig language upon a panic.
pub fn panic(
    msg: []const u8,
    stack_trace: ?*const std.builtin.StackTrace,
    ret_addr: ?usize,
) noreturn {
    @setCold(true);
    kernel.arch.interrupts.disableInterrupts();

    switch (state) {
        .no_op => {},
        .simple => simplePanic(msg, stack_trace, ret_addr),
        .full => panicImpl(msg, stack_trace, ret_addr),
    }

    kernel.arch.interrupts.disableInterruptsAndHalt();
}

/// Prints the panic message to the early output writer.
fn simplePanic(
    msg: []const u8,
    stack_trace: ?*const std.builtin.StackTrace,
    ret_addr: ?usize,
) void {
    _ = stack_trace;

    const writer = kernel.arch.setup.getEarlyOutputWriter();

    writer.print("\nPANIC: {s}\n", .{msg}) catch unreachable;

    printCurrentBackTrace(writer, ret_addr orelse @returnAddress());
}

/// Prints the panic message, stack trace, and registers.
fn panicImpl(
    msg: []const u8,
    stack_trace: ?*const std.builtin.StackTrace,
    ret_addr: ?usize,
) void {
    // TODO: Implement `panicImpl` https://github.com/CascadeOS/CascadeOS/issues/16
    simplePanic(msg, stack_trace, ret_addr);
}

fn printCurrentBackTrace(writer: anytype, return_address: usize) void {
    var stack_iter = std.debug.StackIterator.init(return_address, @frameAddress());

    while (stack_iter.next()) |address| {
        printSourceAtAddress(writer, address);
    }
}

const indent = "  ";

fn printSourceAtAddress(writer: anytype, address: usize) void {
    if (address == 0) return;

    if (address < kernel.arch.paging.higher_half.value) {
        writer.writeAll(comptime indent ++ "0x") catch unreachable;
        std.fmt.formatInt(
            address,
            16,
            .lower,
            .{},
            writer,
        ) catch unreachable;
        writer.writeAll(" - address is not in the higher half so must be userspace\n") catch unreachable;
        return;
    }

    // we can't use `VirtAddr` here as it is possible this subtract results in a non-canonical address
    const kernel_source_address = address - kernel.info.kernel_offset_from_base.bytes;

    if (kernel_source_address < kernel.info.kernel_base_address.value) {
        writer.writeAll(comptime indent ++ "0x") catch unreachable;
        std.fmt.formatInt(
            address,
            16,
            .lower,
            .{},
            writer,
        ) catch unreachable;
        writer.writeAll(" - address is not a kernel code address\n") catch unreachable;
        return;
    }

    // TODO: Resolve symbols using DWARF or a symbol map https://github.com/CascadeOS/CascadeOS/issues/44

    writer.writeAll(comptime indent ++ "0x") catch unreachable;
    std.fmt.formatInt(
        kernel_source_address,
        16,
        .lower,
        .{},
        writer,
    ) catch unreachable;
    writer.writeAll(" - ???\n") catch unreachable;
}
