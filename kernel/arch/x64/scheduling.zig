// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const x64 = @import("x64.zig");

const log = kernel.log.scoped(.scheduling_x64);

/// Calls `target_function` on `new_stack` and if non-null saves the state of `old_task`.
pub fn callZeroArgs(
    opt_old_task: ?*kernel.Task,
    new_stack: kernel.Stack,
    target_function: *const fn () callconv(.C) noreturn,
) kernel.arch.scheduling.CallError!void {
    const external = struct {
        // Implemented in 'x64/asm/callZeroArgsImpl.S'
        extern fn _callZeroArgsImpl(new_kernel_stack_pointer: core.VirtualAddress, previous_kernel_stack_pointer: *core.VirtualAddress) callconv(.C) void;
        extern fn _callZeroArgsNoPreviousImpl(new_kernel_stack_pointer: core.VirtualAddress) callconv(.C) void;
    };

    var stack = new_stack;

    try stack.pushReturnAddress(core.VirtualAddress.fromPtr(@ptrCast(target_function)));

    if (opt_old_task) |old_task| {
        external._callZeroArgsImpl(
            stack.stack_pointer,
            &old_task.stack.stack_pointer,
        );
    } else {
        external._callZeroArgsNoPreviousImpl(stack.stack_pointer);
    }
}

/// Calls `target_function` on `new_stack` and if non-null saves the state of `old_task`.
pub fn callOneArgs(
    opt_old_task: ?*kernel.Task,
    new_stack: kernel.Stack,
    target_function: *const fn (usize) callconv(.C) noreturn,
    arg1: usize,
) kernel.arch.scheduling.CallError!void {
    const external = struct {
        // Implemented in 'x64/asm/callOneArgsImpl.S'
        extern fn _callOneArgsImpl(new_kernel_stack_pointer: core.VirtualAddress, previous_kernel_stack_pointer: *core.VirtualAddress) callconv(.C) void;
        extern fn _callOneArgsNoPreviousImpl(new_kernel_stack_pointer: core.VirtualAddress) callconv(.C) void;
    };

    var stack = new_stack;

    try stack.pushReturnAddress(core.VirtualAddress.fromPtr(@ptrCast(target_function)));
    try stack.push(arg1);

    if (opt_old_task) |old_task| {
        external._callOneArgsImpl(
            stack.stack_pointer,
            &old_task.stack.stack_pointer,
        );
    } else {
        external._callOneArgsNoPreviousImpl(stack.stack_pointer);
    }
}

/// Calls `target_function` on `new_stack` and if non-null saves the state of `old_task`.
pub fn callTwoArgs(
    opt_old_task: ?*kernel.Task,
    new_stack: kernel.Stack,
    target_function: *const fn (usize, usize) callconv(.C) noreturn,
    arg1: usize,
    arg2: usize,
) kernel.arch.scheduling.CallError!void {
    const external = struct {
        // Implemented in 'x64/asm/callTwoArgsImpl.S'
        extern fn _callTwoArgsImpl(new_kernel_stack_pointer: core.VirtualAddress, previous_kernel_stack_pointer: *core.VirtualAddress) callconv(.C) void;
        extern fn _callTwoArgsNoPreviousImpl(new_kernel_stack_pointer: core.VirtualAddress) callconv(.C) void;
    };

    var stack = new_stack;

    try stack.pushReturnAddress(core.VirtualAddress.fromPtr(@ptrCast(target_function)));
    try stack.push(arg2);
    try stack.push(arg1);

    if (opt_old_task) |old_task| {
        external._callTwoArgsImpl(
            stack.stack_pointer,
            &old_task.stack.stack_pointer,
        );
    } else {
        external._callTwoArgsNoPreviousImpl(stack.stack_pointer);
    }
}

/// Prepares the CPU for jumping to the idle state.
pub fn prepareForJumpToIdleFromTask(cpu: *kernel.Cpu, old_task: *kernel.Task) void {
    _ = old_task;

    kernel.vmm.switchToPageTable(kernel.vmm.kernel_page_table);

    cpu.arch.tss.setPrivilegeStack(
        .ring0,
        cpu.scheduler_stack.stack_pointer,
    );
}

/// Jumps to the idle task.
///
/// Saves the old task's state to it's stack.
///
/// **Warning** It is the caller's responsibility to call `prepareForJumpToIdleFromTask` before calling this function.
pub inline fn jumpToIdleFromTask(
    cpu: *kernel.Cpu,
    old_task: *kernel.Task,
) void {
    const external = struct {
        // Implemented in 'x64/asm/jumpToIdleFromTask.S'
        extern fn _jumpToIdleFromTask(new_kernel_stack_pointer: core.VirtualAddress, previous_kernel_stack_pointer: *core.VirtualAddress) callconv(.C) void;
    };
    external._jumpToIdleFromTask(
        cpu.scheduler_stack.stack_pointer,
        &old_task.stack.stack_pointer,
    );
}

/// Prepares the CPU for jumping to the given task from the idle state.
pub fn prepareForJumpToTaskFromIdle(cpu: *kernel.Cpu, new_task: *kernel.Task) void {
    if (new_task.process) |new_task_process| {
        kernel.vmm.switchToPageTable(new_task_process.page_table);
    }

    cpu.arch.tss.setPrivilegeStack(
        .ring0,
        new_task.stack.stack_pointer,
    );
}

/// Jumps to the given task from the idle state.
///
/// Saves the old task's state to allow it to be resumed later.
///
/// **Note**: It is the caller's responsibility to call `prepareForJumpToTaskFromIdle` before calling this function.
pub inline fn jumpToTaskFromIdle(
    task: *kernel.Task,
) noreturn {
    const external = struct {
        /// Implemented in 'x64/asm/jumpToTaskFromIdleImpl.S'
        extern fn _jumpToTaskFromIdleImpl(new_kernel_stack_pointer: core.VirtualAddress) callconv(.C) noreturn;
    };

    external._jumpToTaskFromIdleImpl(task.stack.stack_pointer);
    unreachable;
}

/// Prepares the CPU for jumping from `old_task` to `new_task`.
pub fn prepareForJumpToTaskFromTask(cpu: *kernel.Cpu, old_task: *kernel.Task, new_task: *kernel.Task) void {
    if (old_task.process != new_task.process) {
        if (new_task.process) |new_task_process| {
            kernel.vmm.switchToPageTable(new_task_process.page_table);
        } else {
            kernel.vmm.switchToPageTable(kernel.vmm.kernel_page_table);
        }
    }

    cpu.arch.tss.setPrivilegeStack(
        .ring0,
        new_task.stack.stack_pointer,
    );
}

/// Jumps from `old_task` to `new_task`.
///
/// Saves the old task's state to allow it to be resumed later.
///
/// **Note**: It is the caller's responsibility to call `prepareForJumpToTaskFromTask` before calling this function.
pub inline fn jumpToTaskFromTask(
    old_task: *kernel.Task,
    new_task: *kernel.Task,
) void {
    const external = struct {
        // Implemented in 'asm/jumpToTaskFromTaskImpl.S'
        extern fn _jumpToTaskFromTaskImpl(new_kernel_stack_pointer: core.VirtualAddress, previous_kernel_stack_pointer: *core.VirtualAddress) callconv(.C) void;
    };

    external._jumpToTaskFromTaskImpl(
        new_task.stack.stack_pointer,
        &old_task.stack.stack_pointer,
    );
}

/// Prepares the given task for being scheduled.
///
/// Ensures that when the task is scheduled it will release the scheduler then
/// call the `target_function` with the given `context`.
pub fn prepareNewTaskForScheduling(
    task: *kernel.Task,
    context: u64,
    target_function: kernel.arch.scheduling.NewTaskFunction,
) error{StackOverflow}!void {
    const external = struct {
        // Implemented in 'x64/asm/startNewTask.S'
        extern fn _startNewTask() callconv(.C) noreturn;

        fn startNewTask(
            current_task: *kernel.Task,
            task_context: u64,
            target_function_addr: *const anyopaque,
        ) callconv(.C) noreturn {
            const interrupt_exclusion = kernel.scheduler.releaseScheduler();

            const func: kernel.arch.scheduling.NewTaskFunction = @ptrCast(target_function_addr);
            func(interrupt_exclusion, current_task, task_context);
            unreachable;
        }
    };

    try task.stack.pushReturnAddress(core.VirtualAddress.fromPtr(@ptrCast(&external.startNewTask)));

    try task.stack.push(core.VirtualAddress.fromPtr(@ptrCast(target_function)));
    try task.stack.push(context);
    try task.stack.push(core.VirtualAddress.fromPtr(task));

    try task.stack.pushReturnAddress(core.VirtualAddress.fromPtr(@ptrCast(&external._startNewTask)));

    // general purpose registers
    for (0..6) |_| task.stack.push(@as(u64, 0)) catch unreachable;
}
