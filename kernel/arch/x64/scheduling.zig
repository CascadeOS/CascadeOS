// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const kernel = @import("kernel");
const Task = kernel.Task;
const Thread = kernel.user.Thread;
const core = @import("core");

const x64 = @import("x64.zig");

/// Prepares the given task for being scheduled.
///
/// Ensures that when the task is scheduled it will unlock the scheduler lock then call the `type_erased_call`.
///
/// This function *must* be called before the task is scheduled and can only be called once.
pub fn prepareTaskForScheduling(
    task: *Task,
    type_erased_call: core.TypeErasedCall,
) void {
    const impl = struct {
        fn taskEntryTrampoline() callconv(.naked) void {
            asm volatile (
                \\pop %rdi       // current_task
                \\pop %rsi       // type_erased_call.typeErased
                \\pop %rdx       // type_erased_call.args[0]
                \\pop %rcx       // type_erased_call.args[1]
                \\pop %r8        // type_erased_call.args[2]
                \\pop %r9        // type_erased_call.args[3]
                \\xor %ebp, %ebp
                \\ret            // the address of `Task.internal.taskEntry` is on the stack
            );
        }
    };

    if (core.is_debug) std.debug.assert(
        task.stack.spaceFor(1 + // args[4]
            1 + // task entry return address
            1 + // taskEntry
            4 + // args[..4]
            1 + // type_erased_call.typeErased
            1 + // task
            1 // taskEntryTrampoline
        ),
    );

    task.stack.push(type_erased_call.args[4]) catch unreachable; // left on the stack by `taskEntryTrampoline` as per SysV ABI for 7th arg

    task.stack.push(0) catch unreachable; // task entry return address

    task.stack.push(@intFromPtr(&Task.internal.taskEntry)) catch unreachable;

    task.stack.push(type_erased_call.args[3]) catch unreachable;
    task.stack.push(type_erased_call.args[2]) catch unreachable;
    task.stack.push(type_erased_call.args[1]) catch unreachable;
    task.stack.push(type_erased_call.args[0]) catch unreachable;
    task.stack.push(@intFromPtr(type_erased_call.typeErased)) catch unreachable;
    task.stack.push(@intFromPtr(task)) catch unreachable;

    task.stack.push(@intFromPtr(&impl.taskEntryTrampoline)) catch unreachable;
}

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
pub inline fn switchTask(
    old_task: *Task,
    new_task: *Task,
) void {
    asm volatile (
        \\lea 1f(%rip), %rax
        \\push %rax
        \\mov %rsp, (%[old_stack_pointer])
        \\mov %[new_stack_pointer], %rsp
        \\pop %rax
        \\jmp *%rax
        \\1:
        :
        : [old_stack_pointer] "{r10}" (&old_task.stack.stack_pointer),
          [new_stack_pointer] "{r11}" (new_task.stack.stack_pointer),
        : .{
          .memory = true,
          .rax = true,
          .rbx = true,
          .rcx = true,
          .rdx = true,
          .rsi = true,
          .rdi = true,
          .rsp = true,
          .rbp = true,
          .r8 = true,
          .r9 = true,
          .r10 = true,
          .r11 = true,
          .r12 = true,
          .r13 = true,
          .r14 = true,
          .r15 = true,
        });
}

/// Switches to `new_task`.
///
/// **Note**: It is the caller's responsibility to call `beforeSwitchTask` before calling this function.
pub inline fn switchTaskNoSave(
    new_task: *Task,
) noreturn {
    // no clobbers are listed as the calling context is abandoned
    asm volatile (
        \\mov %[new_stack_pointer], %rsp
        \\pop %rax
        \\jmp *%rax
        :
        : [new_stack_pointer] "r" (new_task.stack.stack_pointer),
    );
    unreachable;
}

/// Calls `type_erased_call` on `new_stack` and saves the state of `old_task`.
pub inline fn call(
    old_task: *Task,
    new_stack: *Task.Stack,
    type_erased_call: core.TypeErasedCall,
) void {
    asm volatile (
        \\lea 1f(%rip), %rax
        \\push %rax
        \\mov %rsp, (%[old_stack_pointer])
        \\mov %[new_stack_pointer], %rsp
        \\xor %ebp, %ebp
        \\jmp *%[typeErased]
        \\1:
        :
        : [arg0] "{rdi}" (type_erased_call.args[0]),
          [arg1] "{rsi}" (type_erased_call.args[1]),
          [arg2] "{rdx}" (type_erased_call.args[2]),
          [arg3] "{rcx}" (type_erased_call.args[3]),
          [arg4] "{r8}" (type_erased_call.args[4]),
          [old_stack_pointer] "{r10}" (&old_task.stack.stack_pointer),
          [new_stack_pointer] "{r11}" (new_stack.stack_pointer),
          [typeErased] "{r9}" (type_erased_call.typeErased),
        : .{
          .memory = true,
          .rax = true,
          .rbx = true,
          .rcx = true,
          .rdx = true,
          .rsi = true,
          .rdi = true,
          .rsp = true,
          .rbp = true,
          .r8 = true,
          .r9 = true,
          .r10 = true,
          .r11 = true,
          .r12 = true,
          .r13 = true,
          .r14 = true,
          .r15 = true,
        });
}

/// Calls `type_erased_call` on `new_stack`.
pub inline fn callNoSave(
    new_stack: *Task.Stack,
    type_erased_call: core.TypeErasedCall,
) noreturn {
    // no clobbers are listed as the calling context is abandoned
    asm volatile (
        \\mov %[new_stack_pointer], %rsp
        \\xor %ebp, %ebp
        \\jmp *%[typeErased]
        :
        : [arg0] "{rdi}" (type_erased_call.args[0]),
          [arg1] "{rsi}" (type_erased_call.args[1]),
          [arg2] "{rdx}" (type_erased_call.args[2]),
          [arg3] "{rcx}" (type_erased_call.args[3]),
          [arg4] "{r8}" (type_erased_call.args[4]),
          [new_stack_pointer] "{r11}" (new_stack.stack_pointer),
          [typeErased] "{r10}" (type_erased_call.typeErased),
    );
    unreachable;
}
