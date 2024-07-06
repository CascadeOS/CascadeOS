// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

/*
extern fn _jumpToTaskFromIdleImpl(
    new_kernel_stack_pointer: core.VirtualAddress, // rdi
) callconv(.C) noreturn;
*/

.section .text
.global _jumpToTaskFromIdleImpl
.type _jumpToTaskFromIdleImpl, @function
_jumpToTaskFromIdleImpl:
    // switch to `new_kernel_stack_pointer`
    mov %rdi, %rsp

    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbp
    pop %rbx

    ret
