// SPDX-License-Identifier: MIT

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");
const VirtualAddress = kernel.VirtualAddress;

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
