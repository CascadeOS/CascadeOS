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
    opt_old_thread: ?*kernel.Thread,
) noreturn {
    const old_thread = opt_old_thread orelse {
        // we were already idle
        changeStackAndReturn(stack_pointer);
        unreachable;
    };

    if (!old_thread.isKernel()) {
        // the process was not the kernel so we need to switch to the kernel page table
        kernel.vmm.switchToKernelPageTable();
    }

    cpu.arch.tss.setPrivilegeStack(
        .ring0,
        cpu.idle_stack.stack_pointer,
    );

    _switchToIdleImpl(
        stack_pointer,
        &old_thread.kernel_stack.stack_pointer,
    );
}

// Implemented in 'x64/asm/switchToIdleImpl.S'
extern fn _switchToIdleImpl(new_kernel_stack_pointer: core.VirtualAddress, previous_kernel_stack_pointer: *core.VirtualAddress) callconv(.C) noreturn;

pub fn switchToThreadFromIdle(
    cpu: *kernel.Cpu,
    thread: *kernel.Thread,
) noreturn {
    if (thread.process) |process| {
        // If the process is not the kernel we need to switch the page table and privilege stack.

        process.loadPageTable();

        cpu.arch.tss.setPrivilegeStack(
            .ring0,
            thread.kernel_stack.stack_pointer,
        );
    }

    _switchToThreadFromIdleImpl(thread.kernel_stack.stack_pointer);
    unreachable;
}

// Implemented in 'x64/asm/switchToThreadFromIdleImpl.S'
extern fn _switchToThreadFromIdleImpl(new_kernel_stack_pointer: core.VirtualAddress) callconv(.C) noreturn;

pub fn switchToThreadFromThread(
    cpu: *kernel.Cpu,
    old_thread: *kernel.Thread,
    new_thread: *kernel.Thread,
) void {

    // If the process is changing we need to switch the page table.
    if (old_thread.process != new_thread.process) {
        if (new_thread.process) |new_process| {
            new_process.loadPageTable();
        } else {
            kernel.vmm.switchToKernelPageTable();
        }
    }

    cpu.arch.tss.setPrivilegeStack(
        .ring0,
        new_thread.kernel_stack.stack_pointer,
    );

    _switchToThreadFromThreadImpl(
        new_thread.kernel_stack.stack_pointer,
        &old_thread.kernel_stack.stack_pointer,
    );
}
// Implemented in 'x64/asm/switchToThreadFromThreadImpl.S'
extern fn _switchToThreadFromThreadImpl(new_kernel_stack_pointer: core.VirtualAddress, previous_kernel_stack_pointer: *core.VirtualAddress) callconv(.C) void;
