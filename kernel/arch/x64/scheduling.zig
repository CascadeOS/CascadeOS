// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
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
    current_task: Task.Current,
    old_task: *Task,
    new_task: *Task,
) void {
    _ = old_task;

    const executor = current_task.knownExecutor();

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
/// Ensures that when the task is scheduled it will unlock the scheduler lock then call the `type_erased_call`.
///
/// This function *must* be called before the task is scheduled and can only be called once.
pub fn prepareTaskForScheduling(
    task: *Task,
    type_erased_call: core.TypeErasedCall,
) void {
    const impls = struct {
        const taskEntryTrampoline: *const fn () callconv(.c) void = blk: {
            const impl = struct {
                fn impl() callconv(.naked) void {
                    asm volatile (
                        \\pop %rdi // current_task
                        \\pop %rsi // type_erased_call.typeErased
                        \\pop %rdx // type_erased_call.args[0]
                        \\pop %rcx // type_erased_call.args[1]
                        \\pop %r8  // type_erased_call.args[2]
                        \\pop %r9  // type_erased_call.args[3]
                        \\ret      // the address of `Task.Scheduler.taskEntry` is on the stack
                    );
                }
            }.impl;

            break :blk @ptrCast(&impl);
        };
    };

    std.debug.assert(task.stack.spaceFor(9 + 6));

    task.stack.push(type_erased_call.args[4]) catch unreachable; // left on the stack by `impls.taskEntryTrampoline` as per System V ABI

    task.stack.push(@intFromPtr(&Task.internal.taskEntry)) catch unreachable;

    task.stack.push(type_erased_call.args[3]) catch unreachable;
    task.stack.push(type_erased_call.args[2]) catch unreachable;
    task.stack.push(type_erased_call.args[1]) catch unreachable;
    task.stack.push(type_erased_call.args[0]) catch unreachable;
    task.stack.push(@intFromPtr(type_erased_call.typeErased)) catch unreachable;
    task.stack.push(@intFromPtr(task)) catch unreachable;

    task.stack.push(@intFromPtr(impls.taskEntryTrampoline)) catch unreachable;

    // general purpose registers
    for (0..6) |_| task.stack.push(0) catch unreachable;
}

/// Calls `type_erased_call` on `new_stack` and saves the state of `old_task`.
pub fn call(
    old_task: *Task,
    new_stack: Task.Stack,
    type_erased_call: core.TypeErasedCall,
) arch.scheduling.CallError!void {
    const impls = struct {
        const callImpl: *const fn (
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
                        \\pop %rdi         // arg0
                        \\pop %rsi         // arg1
                        \\pop %rdx         // arg2
                        \\pop %rcx         // arg3
                        \\pop %r8          // arg4
                        \\ret              // the address of `type_erased_call.typeErased` is on the stack
                        ::: .{
                            .memory = true,
                            .rsp = true,
                            .rdi = true,
                            .rsi = true,
                            .rdx = true,
                            .rcx = true,
                            .r8 = true,
                        });
                }
            }.impl;

            break :blk @ptrCast(&impl);
        };
    };

    var stack = new_stack;

    try stack.push(@intFromPtr(type_erased_call.typeErased));
    try stack.push(type_erased_call.args[4]);
    try stack.push(type_erased_call.args[3]);
    try stack.push(type_erased_call.args[2]);
    try stack.push(type_erased_call.args[1]);
    try stack.push(type_erased_call.args[0]);

    impls.callImpl(
        stack.stack_pointer,
        &old_task.stack.stack_pointer,
    );
}

/// Calls `type_erased_call` on `new_stack`.
pub fn callNoSave(
    new_stack: Task.Stack,
    type_erased_call: core.TypeErasedCall,
) arch.scheduling.CallError!noreturn {
    var stack = new_stack;

    try stack.push(@intFromPtr(type_erased_call.typeErased));
    try stack.push(type_erased_call.args[4]);
    try stack.push(type_erased_call.args[3]);
    try stack.push(type_erased_call.args[2]);
    try stack.push(type_erased_call.args[1]);
    try stack.push(type_erased_call.args[0]);

    asm volatile (
        \\mov %[stack_pointer], %rsp
        \\pop %rdi                   // arg0
        \\pop %rsi                   // arg1
        \\pop %rdx                   // arg2
        \\pop %rcx                   // arg3
        \\pop %r8                    // arg4
        \\ret                        // the address of `type_erased_call.typeErased` is on the stack
        :
        : [stack_pointer] "r" (stack.stack_pointer),
        : .{
          .memory = true,
          .rsp = true,
          .rdi = true,
          .rsi = true,
          .rdx = true,
          .rcx = true,
          .r8 = true,
        });

    unreachable;
}
