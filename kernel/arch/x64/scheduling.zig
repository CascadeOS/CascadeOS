// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const core = @import("core");

const x64 = @import("x64.zig");

pub fn beforeSwitchTask(
    executor: *cascade.Executor,
    old_task: *cascade.Task,
    new_task: *cascade.Task,
) void {
    _ = old_task;

    executor.arch_specific.tss.setPrivilegeStack(
        .ring0,
        new_task.stack.top_stack_pointer,
    );
}

/// Switches to `new_task`.
///
/// If `old_task` is not null its state is saved to allow it to be resumed later.
pub fn switchTask(
    old_task: ?*cascade.Task,
    new_task: *cascade.Task,
) void {
    const impls = struct {
        const switchToTaskWithoutOld: *const fn (
            new_kernel_stack_pointer: core.VirtualAddress, // rdi
        ) callconv(.c) void = blk: {
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
                        ::: .{
                            .memory = true,
                            .rsp = true,
                            .rbp = true,
                            .r15 = true,
                            .r14 = true,
                            .r13 = true,
                            .r12 = true,
                            .rbx = true,
                        });
                }
            }.impl;

            break :blk @ptrCast(&impl);
        };

        const switchToTaskWithOld: *const fn (
            new_kernel_stack_pointer: core.VirtualAddress, // rdi
            previous_kernel_stack_pointer: *core.VirtualAddress, // rsi
        ) callconv(.c) void = blk: {
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
                        ::: .{
                            .memory = true,
                            .rsp = true,
                            .rbp = true,
                            .r15 = true,
                            .r14 = true,
                            .r13 = true,
                            .r12 = true,
                            .rbx = true,
                        });
                }
            }.impl;

            break :blk @ptrCast(&impl);
        };
    };

    const old = old_task orelse {
        impls.switchToTaskWithoutOld(new_task.stack.stack_pointer);
        @panic("task returned");
    };

    impls.switchToTaskWithOld(
        new_task.stack.stack_pointer,
        &old.stack.stack_pointer,
    );
}

/// Prepares the given task for being scheduled.
///
/// Ensures that when the task is scheduled it will unlock the scheduler lock then call the `target_function` with
/// the given arguments.
pub fn prepareTaskForScheduling(
    task: *cascade.Task,
    target_function: arch.scheduling.TaskFunction,
    arg1: usize,
    arg2: usize,
) error{StackOverflow}!void {
    const impls = struct {
        const startTaskStage1: *const fn () callconv(.c) void = blk: {
            const impl = struct {
                fn impl() callconv(.naked) void {
                    asm volatile (
                        \\pop %rdi // current_task
                        \\pop %rsi // target_function
                        \\pop %rdx // arg1
                        \\pop %rcx // arg2
                        \\ret // the return address of `cascade.Task.Scheduler.taskEntry` should be on the stack
                    );
                }
            }.impl;

            break :blk @ptrCast(&impl);
        };
    };

    try task.stack.push(@intFromPtr(&cascade.Task.Scheduler.taskEntry));

    try task.stack.push(arg2);
    try task.stack.push(arg1);
    try task.stack.push(@intFromPtr(target_function));
    try task.stack.push(@intFromPtr(task));

    try task.stack.push(@intFromPtr(impls.startTaskStage1));

    // general purpose registers
    for (0..6) |_| try task.stack.push(0);
}

/// Calls `target_function` on `new_stack` and if non-null saves the state of `old_task`.
pub fn callOneArg(
    opt_old_task: ?*cascade.Task,
    new_stack: cascade.Task.Stack,
    arg1: usize,
    target_function: *const fn (usize) callconv(.c) noreturn,
) arch.scheduling.CallError!void {
    const impls = struct {
        const callOneArgs: *const fn (
            new_kernel_stack_pointer: core.VirtualAddress, // rdi
            previous_kernel_stack_pointer: *core.VirtualAddress, // rsi
        ) callconv(.c) void = blk: {
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
                        ::: .{
                            .memory = true,
                            .rsp = true,
                            .rdi = true,
                        });
                }
            }.impl;

            break :blk @ptrCast(&impl);
        };

        const callOneArgsNoPrevious: *const fn (
            new_kernel_stack_pointer: core.VirtualAddress, // rdi
        ) callconv(.c) void = blk: {
            const impl = struct {
                fn impl() callconv(.naked) void {
                    asm volatile (
                        \\mov %rdi, %rsp
                        \\pop %rdi
                        \\ret
                        ::: .{
                            .memory = true,
                            .rsp = true,
                            .rdi = true,
                        });
                }
            }.impl;

            break :blk @ptrCast(&impl);
        };
    };

    var stack = new_stack;

    try stack.push(@intFromPtr(target_function));
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
    opt_old_task: ?*cascade.Task,
    new_stack: cascade.Task.Stack,
    arg1: usize,
    arg2: usize,
    target_function: *const fn (usize, usize) callconv(.c) noreturn,
) arch.scheduling.CallError!void {
    const impls = struct {
        const callTwoArgs: *const fn (
            new_kernel_stack_pointer: core.VirtualAddress, // rdi
            previous_kernel_stack_pointer: *core.VirtualAddress, // rsi
        ) callconv(.c) void = blk: {
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
                        ::: .{
                            .memory = true,
                            .rsp = true,
                            .rdi = true,
                            .rsi = true,
                        });
                }
            }.impl;

            break :blk @ptrCast(&impl);
        };

        const callTwoArgsNoPrevious: *const fn (
            new_kernel_stack_pointer: core.VirtualAddress, // rdi
        ) callconv(.c) void = blk: {
            const impl = struct {
                fn impl() callconv(.naked) void {
                    asm volatile (
                        \\mov %rdi, %rsp
                        \\pop %rdi
                        \\pop %rsi
                        \\ret
                        ::: .{
                            .memory = true,
                            .rsp = true,
                            .rdi = true,
                            .rsi = true,
                        });
                }
            }.impl;

            break :blk @ptrCast(&impl);
        };
    };

    var stack = new_stack;

    try stack.push(@intFromPtr(target_function));
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

/// Calls `target_function` on `new_stack` and if non-null saves the state of `old_task`.
pub fn callFourArgs(
    opt_old_task: ?*cascade.Task,
    new_stack: cascade.Task.Stack,
    arg1: usize,
    arg2: usize,
    arg3: usize,
    arg4: usize,
    target_function: *const fn (usize, usize, usize, usize) callconv(.c) noreturn,
) arch.scheduling.CallError!void {
    const impls = struct {
        const callFourArgs: *const fn (
            new_kernel_stack_pointer: core.VirtualAddress, // rdi
            previous_kernel_stack_pointer: *core.VirtualAddress, // rsi
        ) callconv(.c) void = blk: {
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
                        \\pop %rdx
                        \\pop %rcx
                        \\ret
                        ::: .{
                            .memory = true,
                            .rsp = true,
                            .rdi = true,
                            .rsi = true,
                            .rdx = true,
                            .rcx = true,
                        });
                }
            }.impl;

            break :blk @ptrCast(&impl);
        };

        const callFourArgsNoPrevious: *const fn (
            new_kernel_stack_pointer: core.VirtualAddress, // rdi
        ) callconv(.c) void = blk: {
            const impl = struct {
                fn impl() callconv(.naked) void {
                    asm volatile (
                        \\mov %rdi, %rsp
                        \\pop %rdi
                        \\pop %rsi
                        \\pop %rdx
                        \\pop %rcx
                        \\ret
                        ::: .{
                            .memory = true,
                            .rsp = true,
                            .rdi = true,
                            .rsi = true,
                            .rdx = true,
                            .rcx = true,
                        });
                }
            }.impl;

            break :blk @ptrCast(&impl);
        };
    };

    var stack = new_stack;

    try stack.push(@intFromPtr(target_function));
    try stack.push(arg4);
    try stack.push(arg3);
    try stack.push(arg2);
    try stack.push(arg1);

    if (opt_old_task) |old_task| {
        impls.callFourArgs(
            stack.stack_pointer,
            &old_task.stack.stack_pointer,
        );
    } else {
        impls.callFourArgsNoPrevious(stack.stack_pointer);
    }
}
