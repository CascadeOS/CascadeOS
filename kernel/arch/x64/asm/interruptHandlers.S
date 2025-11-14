// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

.section .text

.extern interruptDispatch

.altmacro
.macro INTERRUPT_HANDLER interrupt_number
    .global _interrupt_handler_\interrupt_number
    .type _interrupt_handler_\interrupt_number, @function
    _interrupt_handler_\interrupt_number:
.if !(                                                      \
    \interrupt_number == 8 ||                               \
    (\interrupt_number >= 10 && \interrupt_number <= 14) || \
    \interrupt_number == 17 ||                              \
    \interrupt_number == 21 ||                              \
    \interrupt_number == 29 ||                              \
    \interrupt_number == 30                                 \
)
    push $0
.endif
    push $\interrupt_number

    push %rax
    push %rbx
    push %rcx
    push %rdx
    push %rbp
    push %rsi
    push %rdi
    push %r8
    push %r9
    push %r10
    push %r11
    push %r12
    push %r13
    push %r14
    push %r15

    mov %rsp, %rdi
    call interruptDispatch

    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %r11
    pop %r10
    pop %r9
    pop %r8
    pop %rdi
    pop %rsi
    pop %rbp
    pop %rdx
    pop %rcx
    pop %rbx
    pop %rax

    add $16, %rsp // pop the error code and interrupt number
    iretq
.endm

.set i, 0
.rept 256
    INTERRUPT_HANDLER %i
    .set i, i + 1
.endr