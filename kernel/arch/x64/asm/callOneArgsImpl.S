// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

/*
extern fn _callOneArgsImpl(
    new_kernel_stack_pointer: core.VirtualAddress // rdi
    previous_kernel_stack_pointer: *core.VirtualAddress // rsi
) callconv(.C) void;
*/

/*
The signature of the target function is:

export fn targetFunction(
    arg1: usize, // rdi
) callconv(.C) noreturn

The address of the target function is expected to be on the new stack to be used as the return address.

With the three arguments pushed to the stack in reverse order, the stack looks like:
    arg1
    return address
*/

.section .text
.global _callOneArgsImpl
.type _callOneArgsImpl, @function
_callOneArgsImpl:
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

    pop %rdi // arg1

    ret // the address of `targetFunction` should be on the stack as the return address

.section .text
.global _callOneArgsNoPreviousImpl
.type _callOneArgsNoPreviousImpl, @function
_callOneArgsNoPreviousImpl:
    // switch to `new_kernel_stack_pointer`
    mov %rdi, %rsp

    pop %rdi // arg1

    ret // the address of `targetFunction` should be on the stack as the return address
