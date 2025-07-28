// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

#define HANDLER_NAME(interrupt_number) _interrupt_handler_##interrupt_number

#define HANDLER_NO_ERROR_CODE(interrupt_number)      \
    .global HANDLER_NAME(interrupt_number);          \
    .type HANDLER_NAME(interrupt_number), @function; \
    HANDLER_NAME(interrupt_number):                  \
        push $0;                                     \
        push $interrupt_number;                      \
        jmp _interrupt_handler_common;

#define HANDLER_ERROR_CODE(interrupt_number)         \
    .global HANDLER_NAME(interrupt_number);          \
    .type HANDLER_NAME(interrupt_number), @function; \
    HANDLER_NAME(interrupt_number):                  \
        push $interrupt_number;                      \
        jmp _interrupt_handler_common;

.section .text

.global _interrupt_handler_common
.type _interrupt_handler_common, @function
_interrupt_handler_common:
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
    mov %ds, %rax
    push %rax
    mov %es, %rax
    push %rax
    mov %rsp, %rdi
    mov $0x10, %ax // the kernel data selector is asserted to be 0x10 in 'x64/interrupts.zig'
    mov %ax, %es
    mov %ax, %ds
    call interruptDispatch
    pop %rax
    mov %rax, %es
    pop %rax
    mov %rax, %ds
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

// exceptions with no error codes
.irp interrupt_number, 0, 1, 2, 3, 4, 5, 6, 7, 9, 15, 16, 18, 19, 20, 22, 23, 24, 25, 26, 27, 28, 31
    HANDLER_NO_ERROR_CODE(\interrupt_number)
.endr

// exceptions with error codes
.irp interrupt_number, 8, 10, 11, 12, 13, 14, 17, 21, 29, 30
    HANDLER_ERROR_CODE(\interrupt_number)
.endr

// TODO: why does using .rept not work here? it would be better than a hardcoded list

// interrupts
.irp interrupt_number, \
        32, 33, 34, 35, 36, 37, 38, 39, \
        40, 41, 42, 43, 44, 45, 46, 47, 48, 49 \
        50, 51, 52, 53, 54, 55, 56, 57, 58, 59, \
        60, 61, 62, 63, 64, 65, 66, 67, 68, 69, \
        70, 71, 72, 73, 74, 75, 76, 77, 78, 79, \
        80, 81, 82, 83, 84, 85, 86, 87, 88, 89, \
        90, 91, 92, 93, 94, 95, 96, 97, 98, 99, \
        100, 101, 102, 103, 104, 105, 106, 107, 108, 109, \
        110, 111, 112, 113, 114, 115, 116, 117, 118, 119, \
        120, 121, 122, 123, 124, 125, 126, 127, 128, 129, \
        130, 131, 132, 133, 134, 135, 136, 137, 138, 139, \
        140, 141, 142, 143, 144, 145, 146, 147, 148, 149, \
        150, 151, 152, 153, 154, 155, 156, 157, 158, 159, \
        160, 161, 162, 163, 164, 165, 166, 167, 168, 169, \
        170, 171, 172, 173, 174, 175, 176, 177, 178, 179, \
        180, 181, 182, 183, 184, 185, 186, 187, 188, 189, \
        190, 191, 192, 193, 194, 195, 196, 197, 198, 199, \
        200, 201, 202, 203, 204, 205, 206, 207, 208, 209, \
        210, 211, 212, 213, 214, 215, 216, 217, 218, 219, \
        220, 221, 222, 223, 224, 225, 226, 227, 228, 229, \
        230, 231, 232, 233, 234, 235, 236, 237, 238, 239, \
        240, 241, 242, 243, 244, 245, 246, 247, 248, 249, \
        250, 251, 252, 253, 254, 255
    HANDLER_NO_ERROR_CODE(\interrupt_number)
.endr
