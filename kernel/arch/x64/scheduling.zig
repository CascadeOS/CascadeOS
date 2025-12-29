// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const Task = cascade.Task;
const Thread = cascade.user.Thread;
const core = @import("core");

const x64 = @import("x64.zig");

/// Called before `transition.old_task` is switched to `transition.new_task`.
///
/// Page table switching and managing ability to access user memory has already been performed before this function is called.
///
/// Interrupts are disabled when this function is called meaning the `known_executor` field of `current_task` is not null.
pub fn beforeSwitchTask(
    current_task: Task.Current,
    transition: Task.Transition,
) void {
    const executor = current_task.knownExecutor();

    const arch_specific: *x64.PerExecutor = &executor.arch_specific;

    arch_specific.tss.setPrivilegeStack(
        .ring0,
        transition.new_task.stack.top_stack_pointer,
    );

    switch (transition.type) {
        .user_to_kernel, .user_to_user => {
            const old_thread: *Thread = .fromTask(transition.old_task);

            x64.instructions.enableSSEUsage();
            old_thread.arch_specific.xsave.save();
            x64.instructions.disableSSEUsage();
        },
        .kernel_to_kernel, .kernel_to_user => {},
    }
}

/// Switches to `new_task`.
///
/// If `old_task` is not null its state is saved to allow it to be resumed later.
///
/// **Note**: It is the caller's responsibility to call `beforeSwitchTask` before calling this function.
pub fn switchTask(
    old_task: *Task,
    new_task: *Task,
) void {
    const impls = struct {
        const switchTaskImpl: *const fn (
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

    if (core.is_debug) {
        std.debug.assert(new_task.stack.spaceFor(
            6, // general purpose registers
        ));
    }

    impls.switchTaskImpl(
        new_task.stack.stack_pointer,
        &old_task.stack.stack_pointer,
    );
}

/// Switches to `new_task`.
///
/// **Note**: It is the caller's responsibility to call `beforeSwitchTask` before calling this function.
pub fn switchTaskNoSave(
    new_task: *Task,
) noreturn {
    // no clobbers are listed as the calling context is abandoned
    asm volatile (
        \\mov %[stack_pointer], %rsp
        \\pop %r15
        \\pop %r14
        \\pop %r13
        \\pop %r12
        \\pop %rbp
        \\pop %rbx
        \\ret
        :
        : [stack_pointer] "r" (new_task.stack.stack_pointer),
    );
    unreachable;
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
                        \\ret      // the address of `Task.internal.taskEntry` is on the stack
                    );
                }
            }.impl;

            break :blk @ptrCast(&impl);
        };
    };

    std.debug.assert(
        task.stack.spaceFor(1 + // args[4]
            1 + // task entry return address
            1 + // taskEntry
            4 + // args[..4]
            1 + // type_erased_call.typeErased
            1 + // task
            1 + // taskEntryTrampoline
            6 // general purpose registers
        ),
    );

    task.stack.push(type_erased_call.args[4]) catch unreachable; // left on the stack by `impls.taskEntryTrampoline` as per System V ABI

    task.stack.push(0) catch unreachable; // task entry return address

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
    new_stack: *Task.Stack,
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

    if (core.is_debug) {
        std.debug.assert(new_stack.spaceFor(
            1 + // type_erased_call.typeErased
                5, // args[0..5]
        ));
    }

    try new_stack.push(@intFromPtr(type_erased_call.typeErased));
    try new_stack.push(type_erased_call.args[4]);
    try new_stack.push(type_erased_call.args[3]);
    try new_stack.push(type_erased_call.args[2]);
    try new_stack.push(type_erased_call.args[1]);
    try new_stack.push(type_erased_call.args[0]);

    impls.callImpl(
        new_stack.stack_pointer,
        &old_task.stack.stack_pointer,
    );
}

/// Calls `type_erased_call` on `new_stack`.
pub fn callNoSave(
    new_stack: *Task.Stack,
    type_erased_call: core.TypeErasedCall,
) arch.scheduling.CallError!noreturn {
    // no clobbers are listed as the calling context is abandoned
    asm volatile (
        \\mov %[stack_pointer], %rsp
        \\xor %ebp, %ebp
        \\jmp *%[typeErased]
        \\ud2
        :
        : [arg0] "{rdi}" (type_erased_call.args[0]),
          [arg1] "{rsi}" (type_erased_call.args[1]),
          [arg2] "{rdx}" (type_erased_call.args[2]),
          [arg3] "{rcx}" (type_erased_call.args[3]),
          [arg4] "{r8}" (type_erased_call.args[4]),
          [stack_pointer] "r" (new_stack.stack_pointer),
          [typeErased] "r" (@intFromPtr(type_erased_call.typeErased)),
    );
    unreachable;
}
