// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

/*
extern fn _callTwoArgsImpl(
    new_kernel_stack_pointer: core.VirtualAddress // rdi
    previous_kernel_stack_pointer: *core.VirtualAddress // rsi
) callconv(.C) void;
*/

/*
The signature of the target function is:

export fn targetFunction(
    arg1: usize, // rdi
    arg2: usize, // rsi
) callconv(.C) noreturn

The address of the target function is expected to be on the new stack to be used as the return address.

With the three arguments pushed to the stack in reverse order, the stack looks like:
    arg2
    arg1
    return address
*/

.section .text
.global _callTwoArgsImpl
.type _callTwoArgsImpl, @function
_callTwoArgsImpl:
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
    pop %rsi // arg2

    ret // the address of `targetFunction` should be on the stack as the return address

.section .text
.global _callTwoArgsNoPreviousImpl
.type _callTwoArgsNoPreviousImpl, @function
_callTwoArgsNoPreviousImpl:
    // switch to `new_kernel_stack_pointer`
    mov %rdi, %rsp

    pop %rdi // arg1
    pop %rsi // arg2

    ret // the address of `targetFunction` should be on the stack as the return address
