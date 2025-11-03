// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const Task = cascade.Task;
const core = @import("core");

const x64 = @import("x64.zig");

/// Called before `old_task` is switched to `new_task`.
///
/// This function does not perform page table switching or managing ability to access user memory.
///
/// Interrupts are expected to be disabled when this function is called meaning the `known_executor` field of
/// `current_task` is not null.
pub fn beforeSwitchTask(
    current_task: *Task,
    old_task: *Task,
    new_task: *Task,
) void {
    _ = old_task;

    const executor = current_task.known_executor.?;

    const arch_specific: *x64.PerExecutor = &executor.arch_specific;

    arch_specific.tss.setPrivilegeStack(
        .ring0,
        new_task.stack.top_stack_pointer,
    );
}

/// Switches to `new_task`.
///
/// If `old_task` is not null its state is saved to allow it to be resumed later.
///
/// **Note**: It is the caller's responsibility to call `beforeSwitchTask` before calling this function.
pub fn switchTask(
    old_task: ?*Task,
    new_task: *Task,
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
    task: *Task,
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
                        \\ret // the return address of `Task.Scheduler.taskEntry` should be on the stack
                    );
                }
            }.impl;

            break :blk @ptrCast(&impl);
        };
    };

    try task.stack.push(@intFromPtr(&Task.Scheduler.taskEntry));

    try task.stack.push(arg2);
    try task.stack.push(arg1);
    try task.stack.push(@intFromPtr(target_function));
    try task.stack.push(@intFromPtr(task));

    try task.stack.push(@intFromPtr(impls.startTaskStage1));

    // general purpose registers
    for (0..6) |_| try task.stack.push(0);
}

/// Calls `target_function` on `new_stack` and saves the state of `old_task`.
pub fn callZeroArg(
    old_task: *Task,
    new_stack: Task.Stack,
    target_function: *const fn () callconv(.c) noreturn,
) arch.scheduling.CallError!void {
    const impls = struct {
        const callZeroArg: *const fn (
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
                        \\ret
                        ::: .{
                            .memory = true,
                            .rsp = true,
                        });
                }
            }.impl;

            break :blk @ptrCast(&impl);
        };
    };

    var stack = new_stack;

    try stack.push(@intFromPtr(target_function));

    impls.callZeroArg(
        stack.stack_pointer,
        &old_task.stack.stack_pointer,
    );
}

/// Calls `target_function` on `new_stack`.
pub fn callZeroArgNoSave(
    new_stack: Task.Stack,
    target_function: *const fn () callconv(.c) noreturn,
) arch.scheduling.CallError!noreturn {
    var stack = new_stack;

    try stack.push(@intFromPtr(target_function));

    asm volatile (
        \\mov %[stack_pointer], %rsp
        \\ret
        :
        : [stack_pointer] "r" (stack.stack_pointer),
        : .{
          .memory = true,
          .rsp = true,
        });

    unreachable;
}

/// Calls `target_function` on `new_stack` and saves the state of `old_task`.
pub fn callOneArg(
    old_task: *Task,
    new_stack: Task.Stack,
    arg0: usize,
    target_function: *const fn (usize) callconv(.c) noreturn,
) arch.scheduling.CallError!void {
    const impls = struct {
        const callOneArg: *const fn (
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
                        \\pop %rdi // arg0
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
    try stack.push(arg0);

    impls.callOneArg(
        stack.stack_pointer,
        &old_task.stack.stack_pointer,
    );
}

/// Calls `target_function` on `new_stack`.
pub fn callOneArgNoSave(
    new_stack: Task.Stack,
    arg0: usize,
    target_function: *const fn (usize) callconv(.c) noreturn,
) arch.scheduling.CallError!noreturn {
    var stack = new_stack;

    try stack.push(@intFromPtr(target_function));
    try stack.push(arg0);

    asm volatile (
        \\mov %[stack_pointer], %rsp
        \\pop %rdi // arg0
        \\ret
        :
        : [stack_pointer] "r" (stack.stack_pointer),
        : .{
          .memory = true,
          .rsp = true,
          .rdi = true,
        });

    unreachable;
}

/// Calls `target_function` on `new_stack` and saves the state of `old_task`.
pub fn callTwoArg(
    old_task: *Task,
    new_stack: Task.Stack,
    arg0: usize,
    arg1: usize,
    target_function: *const fn (usize, usize) callconv(.c) noreturn,
) arch.scheduling.CallError!void {
    const impls = struct {
        const callTwoArg: *const fn (
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
                        \\pop %rdi // arg0
                        \\pop %rsi // arg1
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
    try stack.push(arg1);
    try stack.push(arg0);

    impls.callTwoArg(
        stack.stack_pointer,
        &old_task.stack.stack_pointer,
    );
}

/// Calls `target_function` on `new_stack`.
pub fn callTwoArgNoSave(
    new_stack: Task.Stack,
    arg0: usize,
    arg1: usize,
    target_function: *const fn (usize, usize) callconv(.c) noreturn,
) arch.scheduling.CallError!noreturn {
    var stack = new_stack;

    try stack.push(@intFromPtr(target_function));
    try stack.push(arg1);
    try stack.push(arg0);

    asm volatile (
        \\mov %[stack_pointer], %rsp
        \\pop %rdi // arg0
        \\pop %rsi // arg1
        \\ret
        :
        : [stack_pointer] "r" (stack.stack_pointer),
        : .{
          .memory = true,
          .rsp = true,
          .rdi = true,
          .rsi = true,
        });

    unreachable;
}

/// Calls `target_function` on `new_stack` and saves the state of `old_task`.
pub fn callThreeArg(
    old_task: *Task,
    new_stack: Task.Stack,
    arg0: usize,
    arg1: usize,
    arg2: usize,
    target_function: *const fn (usize, usize, usize) callconv(.c) noreturn,
) arch.scheduling.CallError!void {
    const impls = struct {
        const callThreeArg: *const fn (
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
                        \\pop %rdi // arg0
                        \\pop %rsi // arg1
                        \\pop %rdx // arg2
                        \\ret
                        ::: .{
                            .memory = true,
                            .rsp = true,
                            .rdi = true,
                            .rsi = true,
                            .rdx = true,
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
    try stack.push(arg0);

    impls.callThreeArg(
        stack.stack_pointer,
        &old_task.stack.stack_pointer,
    );
}

/// Calls `target_function` on `new_stack`.
pub fn callThreeArgNoSave(
    new_stack: Task.Stack,
    arg0: usize,
    arg1: usize,
    arg2: usize,
    target_function: *const fn (usize, usize, usize) callconv(.c) noreturn,
) arch.scheduling.CallError!noreturn {
    var stack = new_stack;

    try stack.push(@intFromPtr(target_function));
    try stack.push(arg2);
    try stack.push(arg1);
    try stack.push(arg0);

    asm volatile (
        \\mov %[stack_pointer], %rsp
        \\pop %rdi // arg0
        \\pop %rsi // arg1
        \\pop %rdx // arg2
        \\ret
        :
        : [stack_pointer] "r" (stack.stack_pointer),
        : .{
          .memory = true,
          .rsp = true,
          .rdi = true,
          .rsi = true,
          .rdx = true,
        });

    unreachable;
}

/// Calls `target_function` on `new_stack` and saves the state of `old_task`.
pub fn callFourArg(
    old_task: *Task,
    new_stack: Task.Stack,
    arg0: usize,
    arg1: usize,
    arg2: usize,
    arg3: usize,
    target_function: *const fn (usize, usize, usize, usize) callconv(.c) noreturn,
) arch.scheduling.CallError!void {
    const impls = struct {
        const callFourArg: *const fn (
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
                        \\pop %rdi // arg0
                        \\pop %rsi // arg1
                        \\pop %rdx // arg2
                        \\pop %rcx // arg3
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
    try stack.push(arg3);
    try stack.push(arg2);
    try stack.push(arg1);
    try stack.push(arg0);

    impls.callFourArg(
        stack.stack_pointer,
        &old_task.stack.stack_pointer,
    );
}

/// Calls `target_function` on `new_stack`.
pub fn callFourArgNoSave(
    new_stack: Task.Stack,
    arg0: usize,
    arg1: usize,
    arg2: usize,
    arg3: usize,
    target_function: *const fn (usize, usize, usize, usize) callconv(.c) noreturn,
) arch.scheduling.CallError!noreturn {
    var stack = new_stack;

    try stack.push(@intFromPtr(target_function));
    try stack.push(arg3);
    try stack.push(arg2);
    try stack.push(arg1);
    try stack.push(arg0);

    asm volatile (
        \\mov %[stack_pointer], %rsp
        \\pop %rdi // arg0
        \\pop %rsi // arg1
        \\pop %rdx // arg2
        \\pop %rcx // arg3
        \\ret
        :
        : [stack_pointer] "r" (stack.stack_pointer),
        : .{
          .memory = true,
          .rsp = true,
          .rdi = true,
          .rsi = true,
          .rdx = true,
          .rcx = true,
        });

    unreachable;
}
