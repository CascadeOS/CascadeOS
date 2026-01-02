// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

// these constants are asserted in `kernel/x64/user.zig` to ensure they are in sync
// TODO: is there a better way of doing this?
#define MAXIMUM_NUMBER_OF_EXECUTORS 64
#define CURRENT_TASK_OFFSET 0
#define STACK_TOP_OFFSET 136

.section .bss
    .align 8
syscall_temp_rsp_storage:
    .zero MAXIMUM_NUMBER_OF_EXECUTORS * 8

.section .text

.extern syscallDispatch

.altmacro
.macro SYSCALL_ENTRY executor_number
    .global _syscall_entry_\executor_number
    .type _syscall_entry_\executor_number, @function
_syscall_entry_\executor_number:
    .set USER_RSP_OFFSET, (\executor_number * 8)

    mov %rsp, syscall_temp_rsp_storage+USER_RSP_OFFSET(%rip)
    swapgs
    mov %gs:CURRENT_TASK_OFFSET, %rsp
    swapgs
    mov STACK_TOP_OFFSET(%rsp), %rsp

    sub $8, %rsp // reserve space for the user rsp
    push %rcx // user rip
    push %r11 // user rflags

    mov syscall_temp_rsp_storage+USER_RSP_OFFSET(%rip), %r11
    mov %r11, 16(%rsp) // store user rsp in reserved space

    push %rax
    push %rbx
    push %rdx
    push %rbp
    push %rsi
    push %rdi
    push %r8
    push %r9
    push %r10
    push %r12
    push %r13
    push %r14
    push %r15
    push %gs
    push %fs

    xor %ebp, %ebp
    mov %rsp, %rdi
    call syscallDispatch

    pop %fs
    pop %gs
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %r10
    pop %r9
    pop %r8
    pop %rdi
    pop %rsi
    pop %rbp
    pop %rdx
    pop %rbx
    pop %rax

    pop %r11 // user rflags
    pop %rcx // user rip

    pop %rsp // user rsp
    sysretq
.endm

.set i, 0
.rept MAXIMUM_NUMBER_OF_EXECUTORS
    SYSCALL_ENTRY %i
    .set i, i + 1
.endr
