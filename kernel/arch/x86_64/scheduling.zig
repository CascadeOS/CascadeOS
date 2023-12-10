// SPDX-License-Identifier: MIT

const core = @import("core");
const kernel = @import("kernel");
const PhysicalAddress = kernel.PhysicalAddress;
const Processor = kernel.Processor;
const std = @import("std");
const Thread = kernel.Thread;
const VirtualAddress = kernel.VirtualAddress;
const x86_64 = @import("x86_64.zig");

/// Switches to the provided stack and returns.
///
/// It is the caller's responsibility to ensure the stack is valid, with a return address.
pub inline fn changeStackAndReturn(stack_pointer: VirtualAddress) noreturn {
    asm volatile (
        \\  mov %[stack], %%rsp
        \\  ret
        :
        : [stack] "rm" (stack_pointer.value),
        : "memory", "stack"
    );
    unreachable;
}

pub fn switchToThreadFromIdle(processor: *Processor, thread: *Thread) noreturn {
    const process = thread.process;

    if (!process.isKernel()) {
        // If the process is not the kernel we need to switch the page table and privilege stack.

        x86_64.paging.switchToPageTable(process.page_table);

        processor.arch.tss.setPrivilegeStack(.kernel, thread.kernel_stack);
    }

    switchToThreadFromIdleImpl(thread.kernel_stack.stack_pointer);
    unreachable;
}

// Implemented in 'x86_64/asm/switchToThreadFromIdleImpl.S'
extern fn switchToThreadFromIdleImpl(new_kernel_stack_pointer: VirtualAddress) callconv(.C) void;
