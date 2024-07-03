// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const x64 = @import("x64.zig");

const log = kernel.log.scoped(.scheduling_x64);

/// Switches to the provided stack and returns.
///
/// It is the caller's responsibility to ensure the stack is valid, with a return address.
pub fn changeStackAndReturn(
    stack_pointer: core.VirtualAddress,
) noreturn {
    asm volatile (
        \\  mov %[stack], %%rsp
        \\  ret
        :
        : [stack] "rm" (stack_pointer.value),
        : "memory", "stack"
    );
    unreachable;
}

/// It is the caller's responsibility to ensure the stack is valid, with a return address.
pub fn switchToIdle(
    cpu: *kernel.Cpu,
    stack_pointer: core.VirtualAddress,
    opt_old_task: ?*kernel.Task,
) noreturn {
    const old_task = opt_old_task orelse {
        // we were already idle
        changeStackAndReturn(stack_pointer);
        unreachable;
    };

    if (!old_task.isKernel()) {
        // the process was not the kernel so we need to switch to the kernel page table
        kernel.vmm.switchToPageTable(kernel.vmm.kernel_page_table);
    }

    cpu.arch.tss.setPrivilegeStack(
        .ring0,
        cpu.idle_stack.stack_pointer,
    );

    _switchToIdleImpl(
        stack_pointer,
        &old_task.kernel_stack.stack_pointer,
    );
}

// Implemented in 'x64/asm/switchToIdleImpl.S'
extern fn _switchToIdleImpl(new_kernel_stack_pointer: core.VirtualAddress, previous_kernel_stack_pointer: *core.VirtualAddress) callconv(.C) noreturn;

pub fn switchToTaskFromIdle(
    cpu: *kernel.Cpu,
    task: *kernel.Task,
) noreturn {
    if (task.process) |process| {
        // If the process is not the kernel we need to switch the page table and privilege stack.

        process.loadPageTable();

        cpu.arch.tss.setPrivilegeStack(
            .ring0,
            task.kernel_stack.stack_pointer,
        );
    }

    _switchToTaskFromIdleImpl(task.kernel_stack.stack_pointer);
    unreachable;
}

// Implemented in 'x64/asm/switchToTaskFromIdleImpl.S'
extern fn _switchToTaskFromIdleImpl(new_kernel_stack_pointer: core.VirtualAddress) callconv(.C) noreturn;

pub fn switchToTaskFromTask(
    cpu: *kernel.Cpu,
    old_task: *kernel.Task,
    new_task: *kernel.Task,
) void {

    // If the process is changing we need to switch the page table.
    if (old_task.process != new_task.process) {
        if (new_task.process) |new_process| {
            new_process.loadPageTable();
        } else {
            kernel.vmm.switchToPageTable(kernel.vmm.kernel_page_table);
        }
    }

    cpu.arch.tss.setPrivilegeStack(
        .ring0,
        new_task.kernel_stack.stack_pointer,
    );

    _switchToTaskFromTaskImpl(
        new_task.kernel_stack.stack_pointer,
        &old_task.kernel_stack.stack_pointer,
    );
}
// Implemented in 'x64/asm/switchToTaskFromTaskImpl.S'
extern fn _switchToTaskFromTaskImpl(new_kernel_stack_pointer: core.VirtualAddress, previous_kernel_stack_pointer: *core.VirtualAddress) callconv(.C) void;

pub fn prepareNewTask(
    task: *kernel.Task,
    context: u64,
    target_function: kernel.arch.scheduling.NewTaskFunction,
) error{StackOverflow}!void {
    const old_stack_pointer = task.kernel_stack.stack_pointer;
    errdefer task.kernel_stack.stack_pointer = old_stack_pointer;

    try task.kernel_stack.pushReturnAddress(core.VirtualAddress.fromPtr(@ptrCast(&startNewTask)));

    try task.kernel_stack.push(core.VirtualAddress.fromPtr(@ptrCast(target_function)));
    try task.kernel_stack.push(context);
    try task.kernel_stack.push(core.VirtualAddress.fromPtr(task));

    try task.kernel_stack.pushReturnAddress(core.VirtualAddress.fromPtr(@ptrCast(&_startNewTask)));

    // general purpose registers
    for (0..6) |_| task.kernel_stack.push(@as(u64, 0)) catch unreachable;
}

// Implemented in 'x64/asm/startNewTask.S'
extern fn _startNewTask() callconv(.C) noreturn;

fn startNewTask(
    task: *kernel.Task,
    context: u64,
    target_function_addr: *const anyopaque,
) callconv(.C) noreturn {
    const interrupt_exclusion = kernel.scheduler.releaseScheduler();

    const target_function: kernel.arch.scheduling.NewTaskFunction = @ptrCast(target_function_addr);

    target_function(interrupt_exclusion, task, context);
    unreachable;
}
