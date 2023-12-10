// SPDX-License-Identifier: MIT

/*
extern fn switchToThreadFromIdleImpl(
    new_kernel_stack_pointer: VirtualAddress, // rdi
) callconv(.C) void;
*/

.section .text
.global switchToThreadFromIdleImpl
.type switchToThreadFromIdleImpl, @function
switchToThreadFromIdleImpl:
    // switch to `new_kernel_stack_pointer`
    mov %rdi, %rsp

    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbp
    pop %rbx

    ret
