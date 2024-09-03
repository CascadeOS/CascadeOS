// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

/// Entry point from bootloader specific code.
///
/// Only the bootstrap cpu executes this function.
pub fn initStage1() !noreturn {
    // get output up and running as soon as possible
    arch.init.setupEarlyOutput();
    arch.init.writeToEarlyOutput(comptime "starting CascadeOS " ++ kernel.config.cascade_version ++ "\n");

    // now that early output is ready, we can switch to the single executor panic
    kernel.debug.panic_impl = singleExecutorPanic;

    const bootstrap_executor, const bootstrap_executor_id = blk: {
        const id: kernel.Executor.Id = @enumFromInt(kernel.system.executors.len + 1);
        break :blk .{ try kernel.system.executors.addOne(), id };
    };
    bootstrap_executor.* = .{
        .id = bootstrap_executor_id,
    };

    arch.init.prepareBootstrapExecutor(bootstrap_executor);
    arch.init.loadExecutor(bootstrap_executor);

    log.debug("building kernel memory layout", .{});
    try buildMemoryLayout(&kernel.system.memory_layout);

    core.panic("NOT IMPLEMENTED", null);
}

fn buildMemoryLayout(memory_layout: *kernel.system.MemoryLayout) !void {
    const base_address = boot.kernelBaseAddress() orelse return error.KernelBaseAddressNotProvided;

    log.debug("kernel virtual base address: {}", .{base_address.virtual});
    log.debug("kernel physical base address: {}", .{base_address.physical});

    const virtual_offset = core.Size.from(base_address.virtual.value - kernel.config.kernel_base_address.value, .byte);
    const physical_to_virtual_offset = core.Size.from(base_address.virtual.value - base_address.physical.value, .byte);
    log.debug("kernel virtual offset: 0x{x}", .{virtual_offset.value});
    log.debug("kernel physical to virtual offset: 0x{x}", .{physical_to_virtual_offset.value});

    memory_layout.* = .{
        .virtual_base_address = base_address.virtual,
        .virtual_offset = virtual_offset,
        .physical_to_virtual_offset = physical_to_virtual_offset,
    };
}

/// The log implementation during init.
pub fn initLogImpl(level_and_scope: []const u8, comptime fmt: []const u8, args: anytype) void {
    arch.init.writeToEarlyOutput(level_and_scope);
    arch.init.early_output_writer.print(fmt, args) catch unreachable;
}

fn singleExecutorPanic(
    msg: []const u8,
    error_return_trace: ?*const std.builtin.StackTrace,
    return_address: usize,
) void {
    const static = struct {
        var nested_panic_count = std.atomic.Value(usize).init(0);
    };

    switch (static.nested_panic_count.fetchAdd(1, .acq_rel)) {
        0 => { // on first panic attempt to print the full panic message
            kernel.debug.formatting.printPanic(
                arch.init.early_output_writer,
                msg,
                error_return_trace,
                return_address,
            ) catch unreachable;
        },
        1 => { // on second panic print a shorter message using only `writeToEarlyOutput`
            arch.init.writeToEarlyOutput("\nPANIC IN PANIC\n");
        },
        else => {}, // don't trigger any more panics
    }
}

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const boot = @import("boot");
const arch = @import("arch");
const log = kernel.log.scoped(.init);