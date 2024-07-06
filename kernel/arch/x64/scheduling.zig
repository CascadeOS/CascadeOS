// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const x64 = @import("x64.zig");

const log = kernel.log.scoped(.scheduling_x64);

pub fn changeTaskToIdle(cpu: *kernel.Cpu, old_task: *kernel.Task) void {
    _ = old_task;

    kernel.vmm.switchToPageTable(kernel.vmm.kernel_page_table);

    cpu.arch.tss.setPrivilegeStack(
        .ring0,
        cpu.scheduler_stack.stack_pointer,
    );
}

pub fn changeIdleToTask(cpu: *kernel.Cpu, new_task: *kernel.Task) void {
    if (new_task.process) |new_task_process| {
        kernel.vmm.switchToPageTable(new_task_process.page_table);
    }

    cpu.arch.tss.setPrivilegeStack(
        .ring0,
        new_task.kernel_stack.stack_pointer,
    );
}

pub fn changeTaskToTask(cpu: *kernel.Cpu, old_task: *kernel.Task, new_task: *kernel.Task) void {
    if (old_task.process != new_task.process) {
        if (new_task.process) |new_task_process| {
            kernel.vmm.switchToPageTable(new_task_process.page_table);
        } else {
            kernel.vmm.switchToPageTable(kernel.vmm.kernel_page_table);
        }
    }

    cpu.arch.tss.setPrivilegeStack(
        .ring0,
        new_task.kernel_stack.stack_pointer,
    );
}

pub fn callZeroArgs(
    opt_old_task: ?*kernel.Task,
    new_stack: kernel.Stack,
    target_function: *const fn () callconv(.C) noreturn,
) kernel.arch.scheduling.CallError!void {
    var stack = new_stack;

    try stack.pushReturnAddress(core.VirtualAddress.fromPtr(@ptrCast(target_function)));

    if (opt_old_task) |old_task| {
        _callZeroArgsImpl(
            stack.stack_pointer,
            &old_task.kernel_stack.stack_pointer,
        );
    } else {
        _callZeroArgsNoPreviousImpl(stack.stack_pointer);
    }
}

// Implemented in 'x64/asm/callZeroArgsImpl.S'
extern fn _callZeroArgsImpl(new_kernel_stack_pointer: core.VirtualAddress, previous_kernel_stack_pointer: *core.VirtualAddress) callconv(.C) void;
extern fn _callZeroArgsNoPreviousImpl(new_kernel_stack_pointer: core.VirtualAddress) callconv(.C) void;

pub fn callOneArgs(
    opt_old_task: ?*kernel.Task,
    new_stack: kernel.Stack,
    target_function: *const fn (usize) callconv(.C) noreturn,
    arg1: usize,
) kernel.arch.scheduling.CallError!void {
    var stack = new_stack;

    try stack.pushReturnAddress(core.VirtualAddress.fromPtr(@ptrCast(target_function)));
    try stack.push(arg1);

    if (opt_old_task) |old_task| {
        _callOneArgsImpl(
            stack.stack_pointer,
            &old_task.kernel_stack.stack_pointer,
        );
    } else {
        _callOneArgsNoPreviousImpl(stack.stack_pointer);
    }
}

// Implemented in 'x64/asm/callOneArgsImpl.S'
extern fn _callOneArgsImpl(new_kernel_stack_pointer: core.VirtualAddress, previous_kernel_stack_pointer: *core.VirtualAddress) callconv(.C) void;
extern fn _callOneArgsNoPreviousImpl(new_kernel_stack_pointer: core.VirtualAddress) callconv(.C) void;

pub fn callTwoArgs(
    opt_old_task: ?*kernel.Task,
    new_stack: kernel.Stack,
    target_function: *const fn (usize, usize) callconv(.C) noreturn,
    arg1: usize,
    arg2: usize,
) kernel.arch.scheduling.CallError!void {
    var stack = new_stack;

    try stack.pushReturnAddress(core.VirtualAddress.fromPtr(@ptrCast(target_function)));
    try stack.push(arg2);
    try stack.push(arg1);

    if (opt_old_task) |old_task| {
        _callTwoArgsImpl(
            stack.stack_pointer,
            &old_task.kernel_stack.stack_pointer,
        );
    } else {
        _callTwoArgsNoPreviousImpl(stack.stack_pointer);
    }
}

// Implemented in 'x64/asm/callTwoArgsImpl.S'
extern fn _callTwoArgsImpl(new_kernel_stack_pointer: core.VirtualAddress, previous_kernel_stack_pointer: *core.VirtualAddress) callconv(.C) void;
extern fn _callTwoArgsNoPreviousImpl(new_kernel_stack_pointer: core.VirtualAddress) callconv(.C) void;

/// It is the caller's responsibility to ensure the stack is valid, with a return address.
pub inline fn jumpToIdleFromTask(
    cpu: *kernel.Cpu,
    old_task: *kernel.Task,
) void {
    _jumpToIdleFromTask(
        cpu.scheduler_stack.stack_pointer,
        &old_task.kernel_stack.stack_pointer,
    );
}

// Implemented in 'x64/asm/jumpToIdleFromTask.S'
extern fn _jumpToIdleFromTask(new_kernel_stack_pointer: core.VirtualAddress, previous_kernel_stack_pointer: *core.VirtualAddress) callconv(.C) void;

pub inline fn jumpToTaskFromIdle(
    task: *kernel.Task,
) noreturn {
    _jumpToTaskFromIdleImpl(task.kernel_stack.stack_pointer);
    unreachable;
}

// Implemented in 'x64/asm/jumpToTaskFromIdleImpl.S'
extern fn _jumpToTaskFromIdleImpl(new_kernel_stack_pointer: core.VirtualAddress) callconv(.C) noreturn;

pub inline fn jumpToTaskFromTask(
    old_task: *kernel.Task,
    new_task: *kernel.Task,
) void {
    _jumpToTaskFromTaskImpl(
        new_task.kernel_stack.stack_pointer,
        &old_task.kernel_stack.stack_pointer,
    );
}
// Implemented in 'x64/asm/jumpToTaskFromTaskImpl.S'
extern fn _jumpToTaskFromTaskImpl(new_kernel_stack_pointer: core.VirtualAddress, previous_kernel_stack_pointer: *core.VirtualAddress) callconv(.C) void;

pub fn prepareStackForNewTask(
    task: *kernel.Task,
    context: u64,
    target_function: kernel.arch.scheduling.NewTaskFunction,
) error{StackOverflow}!void {
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
