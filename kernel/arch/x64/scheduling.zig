// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

/// Prepares the executor for jumping to the idle state.
pub fn prepareForJumpToIdleFromTask(executor: *kernel.Executor, old_task: *kernel.Task) void {
    _ = old_task;

    // TODO: switch page table

    executor.arch.tss.setPrivilegeStack(
        .ring0,
        executor.idle_task.stack.top_stack_pointer,
    );
}

/// Prepares the executor for jumping to the given task from the idle state.
pub fn prepareForJumpToTaskFromIdle(executor: *kernel.Executor, new_task: *kernel.Task) void {
    // TODO: switch page tables

    executor.arch.tss.setPrivilegeStack(
        .ring0,
        new_task.stack.top_stack_pointer,
    );
}

/// Jumps to the given task from the idle state.
///
/// Saves the old task's state to allow it to be resumed later.
///
/// **Note**: It is the caller's responsibility to call `prepareForJumpToTaskFromIdle` before calling this function.
pub fn jumpToTaskFromIdle(
    task: *kernel.Task,
) noreturn {
    const impls = struct {
        const jumpToTaskFromIdle: *const fn (
            new_kernel_stack_pointer: core.VirtualAddress, // rdi
        ) callconv(.C) void = blk: {
            const impl = struct {
                fn impl() callconv(.naked) void {
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
    @panic("task returned to idle");
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
        new_task.stack.top_stack_pointer,
    );
}

/// Jumps from `old_task` to `new_task`.
///
/// Saves the old task's state to allow it to be resumed later.
///
/// **Note**: It is the caller's responsibility to call `prepareForJumpToTaskFromTask` before calling this function.
pub fn jumpToTaskFromTask(
    old_task: *kernel.Task,
    new_task: *kernel.Task,
) void {
    const impls = struct {
        const jumpToTaskFromTask: *const fn (
            new_kernel_stack_pointer: core.VirtualAddress, // rdi
            previous_kernel_stack_pointer: *core.VirtualAddress, // rsi
        ) callconv(.C) void = blk: {
            const impl = struct {
                fn impl() callconv(.naked) void {
                    asm volatile (
                        \\push %rbx
                        \\push %rbp
                        \\push %r12
                        \\push %r13
                        \\push %r14
                        \\push %r15
                        \\mov %rsp, %rax
                        \\mov %rax, (%rsi)
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

    impls.jumpToTaskFromTask(
        new_task.stack.stack_pointer,
        &old_task.stack.stack_pointer,
    );
}

/// Prepares the given task for being scheduled.
///
/// Ensures that when the task is scheduled it will runlock the scheduler lock then call the `target_function` with the
/// given `arg`.
pub fn prepareNewTaskForScheduling(
    task: *kernel.Task,
    arg: u64,
    target_function: kernel.arch.scheduling.NewTaskFunction,
) error{StackOverflow}!void {
    const impls = struct {
        const startNewTaskStage1: *const fn () callconv(.C) void = blk: {
            const impl = struct {
                fn impl() callconv(.naked) void {
                    asm volatile (
                        \\pop %rdi // task
                        \\pop %rsi // arg
                        \\pop %rdx // target_function
                        \\ret // the return address of `startNewTaskStage2` should be on the stack
                    );
                }
            }.impl;

            break :blk @ptrCast(&impl);
        };

        fn startNewTaskStage2(
            current_task: *kernel.Task,
            task_arg: u64,
            target_function_addr: *const anyopaque,
        ) callconv(.C) void {
            kernel.scheduler.unlockScheduler(current_task);

            const func: kernel.arch.scheduling.NewTaskFunction = @ptrCast(target_function_addr);
            func(current_task, task_arg);
            @panic("task returned to entry point");
        }
    };

    try task.stack.push(core.VirtualAddress.fromPtr(@ptrCast(&impls.startNewTaskStage2)));

    try task.stack.push(core.VirtualAddress.fromPtr(@ptrCast(target_function)));
    try task.stack.push(arg);
    try task.stack.push(core.VirtualAddress.fromPtr(task));

    try task.stack.push(core.VirtualAddress.fromPtr(impls.startNewTaskStage1));

    // general purpose registers
    for (0..6) |_| try task.stack.push(@as(u64, 0));
}

/// Calls `target_function` on `new_stack` and if non-null saves the state of `old_task`.
pub fn callOneArgs(
    opt_old_task: ?*kernel.Task,
    new_stack: kernel.Task.Stack,
    arg1: anytype,
    target_function: *const fn (@TypeOf(arg1)) callconv(.C) noreturn,
) kernel.arch.scheduling.CallError!void {
    const impls = struct {
        const callOneArgs: *const fn (
            new_kernel_stack_pointer: core.VirtualAddress, // rdi
            previous_kernel_stack_pointer: *core.VirtualAddress, // rsi
        ) callconv(.C) void = blk: {
            const impl = struct {
                fn impl() callconv(.naked) void {
                    asm volatile (
                        \\push %rbx
                        \\push %rbp
                        \\push %r12
                        \\push %r13
                        \\push %r14
                        \\push %r15
                        \\mov %rsp, %rax
                        \\mov %rax, (%rsi)
                        \\mov %rdi, %rsp
                        \\pop %rdi
                        \\ret
                    );
                }
            }.impl;

            break :blk @ptrCast(&impl);
        };

        const callOneArgsNoPrevious: *const fn (
            new_kernel_stack_pointer: core.VirtualAddress, // rdi
        ) callconv(.C) void = blk: {
            const impl = struct {
                fn impl() callconv(.naked) void {
                    asm volatile (
                        \\mov %rdi, %rsp
                        \\pop %rdi
                        \\ret
                    );
                }
            }.impl;

            break :blk @ptrCast(&impl);
        };
    };

    var stack = new_stack;

    try stack.push(core.VirtualAddress.fromPtr(@ptrCast(target_function)));
    try stack.push(arg1);

    if (opt_old_task) |old_task| {
        impls.callOneArgs(
            stack.stack_pointer,
            &old_task.stack.stack_pointer,
        );
    } else {
        impls.callOneArgsNoPrevious(stack.stack_pointer);
    }
}

/// Calls `target_function` on `new_stack` and if non-null saves the state of `old_task`.
pub fn callTwoArgs(
    opt_old_task: ?*kernel.Task,
    new_stack: kernel.Task.Stack,
    arg1: anytype,
    arg2: anytype,
    target_function: *const fn (@TypeOf(arg1), @TypeOf(arg2)) callconv(.C) noreturn,
) kernel.arch.scheduling.CallError!void {
    const impls = struct {
        const callTwoArgs: *const fn (
            new_kernel_stack_pointer: core.VirtualAddress, // rdi
            previous_kernel_stack_pointer: *core.VirtualAddress, // rsi
        ) callconv(.C) void = blk: {
            const impl = struct {
                fn impl() callconv(.naked) void {
                    asm volatile (
                        \\push %rbx
                        \\push %rbp
                        \\push %r12
                        \\push %r13
                        \\push %r14
                        \\push %r15
                        \\mov %rsp, %rax
                        \\mov %rax, (%rsi)
                        \\mov %rdi, %rsp
                        \\pop %rdi
                        \\pop %rsi
                        \\ret
                    );
                }
            }.impl;

            break :blk @ptrCast(&impl);
        };

        const callTwoArgsNoPrevious: *const fn (
            new_kernel_stack_pointer: core.VirtualAddress, // rdi
        ) callconv(.C) void = blk: {
            const impl = struct {
                fn impl() callconv(.naked) void {
                    asm volatile (
                        \\mov %rdi, %rsp
                        \\pop %rdi
                        \\pop %rsi
                        \\ret
                    );
                }
            }.impl;

            break :blk @ptrCast(&impl);
        };
    };

    var stack = new_stack;

    try stack.push(core.VirtualAddress.fromPtr(@ptrCast(target_function)));
    try stack.push(arg2);
    try stack.push(arg1);

    if (opt_old_task) |old_task| {
        impls.callTwoArgs(
            stack.stack_pointer,
            &old_task.stack.stack_pointer,
        );
    } else {
        impls.callTwoArgsNoPrevious(stack.stack_pointer);
    }
}

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const x64 = @import("x64.zig");
const lib_x64 = @import("x64");
