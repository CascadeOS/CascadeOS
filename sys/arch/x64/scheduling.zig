// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

/// Calls `target_function` on `new_stack` and if non-null saves the state of `old_task`.
pub fn callZeroArgs(
    opt_old_task: ?*kernel.Task,
    new_stack: kernel.Stack,
    target_function: *const fn () callconv(.C) noreturn,
) arch.scheduling.CallError!void {
    const impls = struct {
        const callZeroArgs: *const fn (
            new_kernel_stack_pointer: core.VirtualAddress, // rdi
            previous_kernel_stack_pointer: *core.VirtualAddress, // rsi
        ) callconv(.C) void = blk: {
            const impl = struct {
                fn impl() callconv(.naked) noreturn {
                    asm volatile (
                        \\// all other registers are saved by the caller due to the calling convention
                        \\push %rbx
                        \\push %rbp
                        \\push %r12
                        \\push %r13
                        \\push %r14
                        \\push %r15
                        \\
                        \\// save current stack to `previous_kernel_stack_pointer`
                        \\mov %rsp, %rax
                        \\mov %rax, (%rsi)
                        \\
                        \\// switch to `new_kernel_stack_pointer`
                        \\mov %rdi, %rsp
                        \\
                        \\// the address of `targetFunction` should be on the stack as the return address
                        \\ret
                    );
                }
            }.impl;

            break :blk @ptrCast(&impl);
        };

        const callZeroArgsNoPrevious: *const fn (
            new_kernel_stack_pointer: core.VirtualAddress, // rdi
        ) callconv(.C) void = blk: {
            const impl = struct {
                fn impl() callconv(.naked) noreturn {
                    asm volatile (
                        \\// switch to `new_kernel_stack_pointer`
                        \\mov %rdi, %rsp
                        \\
                        \\// the address of `targetFunction` should be on the stack as the return address
                        \\ret
                    );
                }
            }.impl;

            break :blk @ptrCast(&impl);
        };
    };

    var stack = new_stack;

    try stack.pushReturnAddress(core.VirtualAddress.fromPtr(@ptrCast(target_function)));

    if (opt_old_task) |old_task| {
        impls.callZeroArgs(
            stack.stack_pointer,
            &old_task.stack.stack_pointer,
        );
    } else {
        impls.callZeroArgsNoPrevious(stack.stack_pointer);
    }
}

/// Prepares the executor for jumping to the idle state.
pub fn prepareForJumpToIdleFromTask(executor: *kernel.Executor, old_task: *kernel.Task) void {
    _ = old_task;

    // TODO: switch page table

    executor.arch.tss.setPrivilegeStack(
        .ring0,
        executor.scheduler_stack.stack_pointer,
    );
}

/// Prepares the executor for jumping to the given task from the idle state.
pub fn prepareForJumpToTaskFromIdle(executor: *kernel.Executor, new_task: *kernel.Task) void {
    // TODO: switch page tables

    executor.arch.tss.setPrivilegeStack(
        .ring0,
        new_task.stack.stack_pointer,
    );
}

/// Jumps to the given task from the idle state.
///
/// Saves the old task's state to allow it to be resumed later.
///
/// **Note**: It is the caller's responsibility to call `prepareForJumpToTaskFromIdle` before calling this function.
pub inline fn jumpToTaskFromIdle(
    task: *kernel.Task,
) noreturn {
    const impls = struct {
        const jumpToTaskFromIdle: *const fn (
            new_kernel_stack_pointer: core.VirtualAddress, // rdi
        ) callconv(.C) noreturn = blk: {
            const impl = struct {
                fn impl() callconv(.naked) noreturn {
                    asm volatile (
                        \\mov %rdi, %rsp
                        \\pop %r15
                        \\pop %r14
                        \\pop %r13
                        \\pop %r12
                        \\pop %rbp
                        \\pop %rbx
                        \\ret
                    );
                }
            }.impl;

            break :blk @ptrCast(&impl);
        };
    };

    impls.jumpToTaskFromIdle(task.stack.stack_pointer);
    unreachable;
}

/// Prepares the executor for jumping from `old_task` to `new_task`.
pub fn prepareForJumpToTaskFromTask(
    executor: *kernel.Executor,
    old_task: *kernel.Task,
    new_task: *kernel.Task,
) void {
    _ = old_task;
    // TODO: switch page tables

    executor.arch.tss.setPrivilegeStack(
        .ring0,
        new_task.stack.stack_pointer,
    );
}

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const arch = @import("arch");
const log = kernel.log.scoped(.scheduling_x64);
