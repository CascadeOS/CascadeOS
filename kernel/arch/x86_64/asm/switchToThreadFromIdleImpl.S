// SPDX-License-Identifier: MIT

/*
extern fn _switchToThreadFromIdleImpl(
    new_kernel_stack_pointer: kernel.VirtualAddress, // rdi
) callconv(.C) noreturn;
*/

.section .text
.global _switchToThreadFromIdleImpl
.type _switchToThreadFromIdleImpl, @function
_switchToThreadFromIdleImpl:
    // switch to `new_kernel_stack_pointer`
    mov %rdi, %rsp

    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbp
    pop %rbx

    ret
