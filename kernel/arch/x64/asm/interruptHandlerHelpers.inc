// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

#define HANDLER_NAME(interrupt_number) _interrupt_handler_##interrupt_number

#define HANDLER_COMMON(interrupt_number)                                          \
    push $interrupt_number;                                                       \
    push %rax;                                                                    \
    push %rbx;                                                                    \
    push %rcx;                                                                    \
    push %rdx;                                                                    \
    push %rbp;                                                                    \
    push %rsi;                                                                    \
    push %rdi;                                                                    \
    push %r8;                                                                     \
    push %r9;                                                                     \
    push %r10;                                                                    \
    push %r11;                                                                    \
    push %r12;                                                                    \
    push %r13;                                                                    \
    push %r14;                                                                    \
    push %r15;                                                                    \
    mov %ds, %rax;                                                                \
    push %rax;                                                                    \
    mov %es, %rax;                                                                \
    push %rax;                                                                    \
    mov %rsp, %rdi;                                                               \
    /* the kernel data selector is asserted to be 0x10 in 'x64/interrupts.zig' */ \
    mov $0x10, %ax;                                                               \
    mov %ax, %es;                                                                 \
    mov %ax, %ds;                                                                 \
    call interruptDispatch;                                                       \
    pop %rax;                                                                     \
    mov %rax, %es;                                                                \
    pop %rax;                                                                     \
    mov %rax, %ds;                                                                \
    pop %r15;                                                                     \
    pop %r14;                                                                     \
    pop %r13;                                                                     \
    pop %r12;                                                                     \
    pop %r11;                                                                     \
    pop %r10;                                                                     \
    pop %r9;                                                                      \
    pop %r8;                                                                      \
    pop %rdi;                                                                     \
    pop %rsi;                                                                     \
    pop %rbp;                                                                     \
    pop %rdx;                                                                     \
    pop %rcx;                                                                     \
    pop %rbx;                                                                     \
    pop %rax;                                                                     \
    /* pop the error code and interrupt number */                                 \
    add $16, %rsp;                                                                \
    iretq;

#define HANDLER_NO_ERROR_CODE(interrupt_number)      \
    .global HANDLER_NAME(interrupt_number);          \
    .type HANDLER_NAME(interrupt_number), @function; \
HANDLER_NAME(interrupt_number):                      \
    push $0;                                         \
    HANDLER_COMMON(interrupt_number)

#define HANDLER_ERROR_CODE(interrupt_number)         \
    .global HANDLER_NAME(interrupt_number);          \
    .type HANDLER_NAME(interrupt_number), @function; \
HANDLER_NAME(interrupt_number):                      \
    HANDLER_COMMON(interrupt_number)
