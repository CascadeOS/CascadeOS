// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");
const x86_64 = @import("x86_64.zig");

/// Switches to the provided stack and returns.
///
/// It is the caller's responsibility to ensure the stack is valid, with a return address.
pub fn changeStackAndReturn(stack_pointer: core.VirtualAddress) noreturn {
    asm volatile (
        \\  mov %[stack], %%rsp
        \\  ret
        :
        : [stack] "rm" (stack_pointer.value),
        : "memory", "stack"
    );
    unreachable;
}

pub fn prepareStackForNewThread(
    thread: *kernel.scheduler.Thread,
    context: u64,
    target_function: *const fn (thread: *kernel.scheduler.Thread, context: u64) noreturn,
) error{StackOverflow}!void {
    const old_stack_pointer = thread.kernel_stack.stack_pointer;
    errdefer thread.kernel_stack.stack_pointer = old_stack_pointer;

    try thread.kernel_stack.pushReturnAddress(core.VirtualAddress.fromPtr(@ptrCast(&startNewThread)));

    try thread.kernel_stack.push(core.VirtualAddress.fromPtr(@ptrCast(target_function)));
    try thread.kernel_stack.push(context);
    try thread.kernel_stack.push(core.VirtualAddress.fromPtr(thread));

    try thread.kernel_stack.pushReturnAddress(core.VirtualAddress.fromPtr(@ptrCast(&_startNewThread)));

    // general purpose registers
    for (0..6) |_| thread.kernel_stack.push(@as(u64, 0)) catch unreachable;
}

pub fn switchToThreadFromIdle(processor: *kernel.Processor, thread: *kernel.scheduler.Thread) noreturn {
    const process = thread.process;

    if (!process.isKernel()) {
        // If the process is not the kernel we need to switch the page table and privilege stack.

        x86_64.paging.switchToPageTable(process.page_table);

        processor.arch.tss.setPrivilegeStack(
            .ring0,
            thread.kernel_stack.stack_pointer,
        );
    }

    _switchToThreadFromIdleImpl(thread.kernel_stack.stack_pointer);
    unreachable;
}

pub fn switchToThreadFromThread(processor: *kernel.Processor, old_thread: *kernel.scheduler.Thread, new_thread: *kernel.scheduler.Thread) void {
    const new_process = new_thread.process;

    // If the process is changing we need to switch the page table.
    if (old_thread.process != new_process) {
        x86_64.paging.switchToPageTable(new_process.page_table);
    }

    processor.arch.tss.setPrivilegeStack(
        .ring0,
        new_thread.kernel_stack.stack_pointer,
    );

    _switchToThreadFromThreadImpl(
        new_thread.kernel_stack.stack_pointer,
        &old_thread.kernel_stack.stack_pointer,
    );
}

/// It is the caller's responsibility to ensure the stack is valid, with a return address.
pub fn switchToIdle(processor: *kernel.Processor, stack_pointer: core.VirtualAddress, opt_old_thread: ?*kernel.scheduler.Thread) noreturn {
    const old_thread = opt_old_thread orelse {
        // we were already idle
        changeStackAndReturn(stack_pointer);
        unreachable;
    };

    if (!old_thread.process.isKernel()) {
        // the process was not the kernel so we need to switch to the kernel page table
        x86_64.paging.switchToPageTable(kernel.kernel_process.page_table);
    }

    processor.arch.tss.setPrivilegeStack(
        .ring0,
        processor.idle_stack.stack_pointer,
    );

    _switchToIdleImpl(
        stack_pointer,
        &old_thread.kernel_stack.stack_pointer,
    );
}

fn startNewThread(
    thread: *kernel.scheduler.Thread,
    context: u64,
    target_function_addr: *const anyopaque,
) callconv(.C) noreturn {
    kernel.scheduler.lock.unsafeUnlock();

    const target_function: *const fn (thread: *kernel.scheduler.Thread, context: u64) noreturn = @ptrCast(target_function_addr);

    target_function(thread, context);
    unreachable;
}

// Implemented in 'x86_64/asm/startNewThread.S'
extern fn _startNewThread() callconv(.C) noreturn;

// Implemented in 'x86_64/asm/switchToThreadFromIdleImpl.S'
extern fn _switchToThreadFromIdleImpl(new_kernel_stack_pointer: core.VirtualAddress) callconv(.C) noreturn;

// Implemented in 'x86_64/asm/switchToThreadFromThreadImpl.S'
extern fn _switchToThreadFromThreadImpl(new_kernel_stack_pointer: core.VirtualAddress, previous_kernel_stack_pointer: *core.VirtualAddress) callconv(.C) void;

// Implemented in 'x86_64/asm/switchToIdleImpl.S'
extern fn _switchToIdleImpl(new_kernel_stack_pointer: core.VirtualAddress, previous_kernel_stack_pointer: *core.VirtualAddress) callconv(.C) noreturn;
