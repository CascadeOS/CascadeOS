// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

/*
extern fn _jumpToIdleFromTaskImpl(
    new_kernel_stack_pointer: core.VirtualAddress // rdi
    previous_kernel_stack_pointer: *core.VirtualAddress // rsi
) callconv(.C) void;
*/

.section .text
.global _jumpToIdleFromTaskImpl
.type _jumpToIdleFromTaskImpl, @function
_jumpToIdleFromTaskImpl:
    // all other registers are saved by the caller due to the calling convention
    push %rbx
    push %rbp
    push %r12
    push %r13
    push %r14
    push %r15

    // save current stack to `previous_kernel_stack_pointer`
    mov %rsp, %rax
    mov %rax, (%rsi)

    // switch to `new_kernel_stack_pointer`
    mov %rdi, %rsp

    ret
