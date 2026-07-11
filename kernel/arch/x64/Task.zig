// SPDX-License-Identifier: BSD-3-Clause
// SPDX-FileCopyrightText: CascadeOS Contributors

const std = @import("std");
const builtin = @import("builtin");

const cascade = @import("cascade");
const core = @import("core");

const x64 = @import("x64.zig");

const Task = @This();

/// A self pointer to the task used for GS relative accesses.
self_pointer: *cascade.Task,

/// Used to store the user rsp temporarily on syscall entry.
user_rsp_scratch: u64 = undefined,

pub inline fn from(task: *cascade.Task) *Task {
    return &task.arch_specific.arch_specific;
}

/// Perform architecture specific task initialization.
///
/// This function is called very early during init so cannot use any kernel subsystems.
pub fn initialize(task: *cascade.Task) void {
    const x64_task = from(task);
    x64_task.* = .{ .self_pointer = task };
}

/// Get the current `Task`.
///
/// Supports being called with interrupts and preemption enabled.
pub inline fn getCurrent() *cascade.Task {
    const static = struct {
        const self_pointer_offset_string = std.fmt.comptimePrint(
            "{d}",
            .{@offsetOf(cascade.Task, "arch_specific") + @offsetOf(Task, "self_pointer")},
        );
    };

    return asm ("mov %%gs:" ++ static.self_pointer_offset_string ++ ", %[current_task]"
        : [current_task] "=r" (-> *cascade.Task),
    );
}

/// Set the current task.
///
/// Supports being called with interrupts and preemption enabled.
pub inline fn setCurrent(task: *cascade.Task) void {
    x64.registers.GS_BASE.write(@intFromPtr(task));
}

/// Prepare the task for being scheduled.
///
/// Ensures that when the task is scheduled it will unlock the scheduler lock then call the `type_erased_call`.
pub fn prepareForScheduling(task: *cascade.Task, type_erased_call: *const core.TypeErasedCall) void {
    const impl = struct {
        fn taskEntryTrampoline() callconv(.naked) void {
            asm volatile (
                \\.cfi_sections .debug_frame
                \\.cfi_undefined rip
                \\
                \\pop %rdi       // type_erased_call.typeErased
                \\pop %rsi       // type_erased_call.args[0]
                \\pop %rdx       // type_erased_call.args[1]
                \\pop %rcx       // type_erased_call.args[2]
                \\pop %r8        // type_erased_call.args[3]
                \\pop %r9        // type_erased_call.args[4]
                \\pop %rax       // cascade.Task.internal.taskEntry
                \\jmp *%rax
            );
        }
    };

    if (core.is_debug) std.debug.assert(
        task.stack.spaceFor(1 + // cascade.Task.internal.taskEntry
            5 + // args
            1 + // type_erased_call.typeErased
            1 + // taskEntryTrampoline
            1 // rbp
        ),
    );

    // used as the jump target in `taskEntryTrampoline`
    task.stack.push(@intFromPtr(&cascade.Task.internal.taskEntry)) catch unreachable;

    // task args
    task.stack.push(type_erased_call.args[4].unsigned) catch unreachable;
    task.stack.push(type_erased_call.args[3].unsigned) catch unreachable;
    task.stack.push(type_erased_call.args[2].unsigned) catch unreachable;
    task.stack.push(type_erased_call.args[1].unsigned) catch unreachable;
    task.stack.push(type_erased_call.args[0].unsigned) catch unreachable;

    // task function
    task.stack.push(@intFromPtr(type_erased_call.typeErased)) catch unreachable;

    // use as jump target and rbp in `switchToTask[NoSave]`
    task.stack.push(@intFromPtr(&impl.taskEntryTrampoline)) catch unreachable; // jump target
    task.stack.push(0) catch unreachable; // rbp
}

/// Called before `transition.old_task` is switched to `transition.new_task`.
///
/// ***Caller Requirements***:
///  - Page table switching and managing ability to access user memory must have already been performed before this function is called.
///  - Interrupts must be disabled when this function is called.
pub fn prepareSwitch(transition: cascade.Task.Transition) void {
    const executor = transition.old_task.state.running;

    const x64_executor: *x64.Executor = .from(executor);

    x64_executor.tss.setPrivilegeStack(
        .ring0,
        transition.new_task.stack.top_stack_pointer,
    );

    switch (transition.type) {
        .user_to_kernel, .user_to_user => {
            const x64_thread: *x64.Thread = .from(.from(transition.old_task));

            x64.Executor.current.enableSSEUsage();
            x64_thread.extended_state.save();
            x64.Executor.current.disableSSEUsage();
        },
        .kernel_to_kernel, .kernel_to_user => {},
    }
}

/// Switches to `new_task`.
///
/// The state of `old_task` is saved to allow it to be resumed later.
///
/// ***Caller Requirements***:
///  - `prepareSwitch` must be called before calling this function.
pub inline fn performSwitch(
    old_task: *cascade.Task,
    new_task: *cascade.Task,
) void {
    asm volatile (
        \\.cfi_sections .debug_frame
        \\
        \\lea 1f(%rip), %rax
        \\push %rax
        \\
        \\push %rbp
        \\
        \\mov %rsp, (%[old_stack_pointer])
        \\mov %[new_stack_pointer], %rsp
        \\.cfi_undefined rip
        \\
        \\pop %rbp
        \\.cfi_restore rip
        \\
        \\pop %rax
        \\jmp *%rax
        \\
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
          //.rsp = true, from the perspective of a task the stack pointer is unmodified
          //.rbp = true, rbp is handled explicitly
          .r8 = true,
          .r9 = true,
          .r10 = true,
          .r11 = true,
          .r12 = true,
          .r13 = true,
          .r14 = true,
          .r15 = true,
        });

    comptime {
        std.debug.assert(builtin.omit_frame_pointer == false);
    }
}

/// Switches to `new_task`.
///
/// ***Caller Requirements***:
///  - `prepareSwitch` must be called before calling this function.
pub inline fn performSwitchNoSave(new_task: *cascade.Task) noreturn {
    // no clobbers are listed as the calling context is abandoned
    asm volatile (
        \\.cfi_sections .debug_frame
        \\
        \\mov %[new_stack_pointer], %rsp
        \\.cfi_undefined rip
        \\
        \\pop %rbp
        \\.cfi_restore rip
        \\
        \\pop %rax
        \\jmp *%rax
        :
        : [new_stack_pointer] "r" (new_task.stack.stack_pointer),
    );
    unreachable;
}

/// Calls `type_erased_call` on `new_stack` and saves the state of `old_task`.
///
/// ***Caller Requirements***:
///  - `type_erased_call` must have a return type of `noreturn`.
pub inline fn call(
    old_task: *cascade.Task,
    new_stack: *cascade.Task.Stack,
    type_erased_call: *const core.TypeErasedCall,
) void {
    asm volatile (
        \\.cfi_sections .debug_frame
        \\
        \\lea 1f(%rip), %rax
        \\push %rax
        \\
        \\push %rbp
        \\
        \\mov %rsp, (%[old_stack_pointer])
        \\mov %[new_stack_pointer], %rsp
        \\.cfi_undefined rip
        \\
        \\xor %ebp, %ebp
        \\jmp *%[typeErased]
        \\
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
          //.rsp = true, from the perspective of a task the stack pointer is unmodified
          //.rbp = true, rbp is handled explicitly
          .r8 = true,
          .r9 = true,
          .r10 = true,
          .r11 = true,
          .r12 = true,
          .r13 = true,
          .r14 = true,
          .r15 = true,
        });

    comptime {
        std.debug.assert(builtin.omit_frame_pointer == false);
    }
}

/// Calls `type_erased_call` on `new_stack`.
///
/// ***Caller Requirements***:
///  - `type_erased_call` must have a return type of `noreturn`.
pub inline fn callNoSave(
    new_stack: *cascade.Task.Stack,
    type_erased_call: *const core.TypeErasedCall,
) noreturn {
    // no clobbers are listed as the calling context is abandoned
    asm volatile (
        \\.cfi_sections .debug_frame
        \\
        \\mov %[new_stack_pointer], %rsp
        \\.cfi_undefined rip
        \\
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
