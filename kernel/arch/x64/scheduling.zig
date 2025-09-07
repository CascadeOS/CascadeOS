// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const core = @import("core");

/// Prepares the executor for jumping from `old_task` to `new_task`.
pub fn prepareForJumpToTaskFromTask(
    executor: *cascade.Executor,
    old_task: *cascade.Task,
    new_task: *cascade.Task,
) void {
    switch (old_task.environment) {
        .kernel => switch (new_task.environment) {
            .kernel => {},
            .user => |process| {
                process.address_space.page_table.load();
                executor.arch_specific.tss.setPrivilegeStack(
                    .ring0,
                    new_task.stack.top_stack_pointer,
                );
            },
        },
        .user => |old_process| switch (new_task.environment) {
            .kernel => cascade.mem.globals.core_page_table.load(),
            .user => |new_process| if (old_process != new_process) {
                new_process.address_space.page_table.load();
                executor.arch_specific.tss.setPrivilegeStack(
                    .ring0,
                    new_task.stack.top_stack_pointer,
                );
            },
        },
    }
}

/// Jumps to the given task without saving the old task's state.
///
/// If the old task is ever rescheduled undefined behaviour may occur.
///
/// **Note**: It is the caller's responsibility to call `prepareForJumpToTaskFromTask` before calling this function.
pub fn jumpToTask(
    task: *cascade.Task,
) noreturn {
    const impls = struct {
        const jumpToTask: *const fn (
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
    };

    impls.jumpToTask(task.stack.stack_pointer);
    @panic("task returned");
}

/// Jumps from `old_task` to `new_task`.
///
/// Saves the old task's state to allow it to be resumed later.
///
/// **Note**: It is the caller's responsibility to call `prepareForJumpToTaskFromTask` before calling this function.
pub fn jumpToTaskFromTask(
    old_task: *cascade.Task,
    new_task: *cascade.Task,
) void {
    const impls = struct {
        const jumpToTaskFromTask: *const fn (
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

    impls.jumpToTaskFromTask(
        new_task.stack.stack_pointer,
        &old_task.stack.stack_pointer,
    );
}

/// Prepares the given task for being scheduled.
///
/// Ensures that when the task is scheduled it will unlock the scheduler lock then call the `target_function` with
/// the given arguments.
pub fn prepareNewTaskForScheduling(
    task: *cascade.Task,
    target_function: arch.scheduling.NewTaskFunction,
    arg1: usize,
    arg2: usize,
) error{StackOverflow}!void {
    const impls = struct {
        const startNewTaskStage1: *const fn () callconv(.c) void = blk: {
            const impl = struct {
                fn impl() callconv(.naked) void {
                    asm volatile (
                        \\pop %rdi // context
                        \\pop %rsi // target_function
                        \\pop %rdx // arg1
                        \\pop %rcx // arg2
                        \\ret // the return address of `cascade.scheduler.newTaskEntry` should be on the stack
                    );
                }
            }.impl;

            break :blk @ptrCast(&impl);
        };
    };

    try task.stack.push(@intFromPtr(&cascade.scheduler.newTaskEntry));

    try task.stack.push(arg2);
    try task.stack.push(arg1);
    try task.stack.push(@intFromPtr(target_function));
    try task.stack.push(@intFromPtr(&task.context));

    try task.stack.push(@intFromPtr(impls.startNewTaskStage1));

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
