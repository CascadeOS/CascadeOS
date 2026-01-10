// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

.cfi_sections .debug_frame

.extern interruptDispatch
.set .HasError, 1
.set .NoError, 2

.macro INTERRUPT_HANDLER type, number

.section .text
.global _interrupt_handler_\number
.type _interrupt_handler_\number, @function
_interrupt_handler_\number:
	.cfi_startproc simple
	.cfi_signal_frame
    .cfi_undefined rip
	.cfi_def_cfa %rsp, 0
	.cfi_offset %rip, 0
	.cfi_offset %rsp, 24

.if \type != .HasError
    push $0
.endif
    .cfi_adjust_cfa_offset 8

    push $\number
    .cfi_adjust_cfa_offset 8

    // if we interrupted userspace then swapgs
    testl $3, 0x18(%rsp)
    jz 1f
    swapgs
1:
    push %rax
    .cfi_adjust_cfa_offset 8
	.cfi_rel_offset %rax, 0
    push %rbx
    .cfi_adjust_cfa_offset 8
	.cfi_rel_offset %rbx, 0
    push %rcx
    .cfi_adjust_cfa_offset 8
	.cfi_rel_offset %rcx, 0
    push %rdx
    .cfi_adjust_cfa_offset 8
	.cfi_rel_offset %rdx, 0
    push %rbp
    .cfi_adjust_cfa_offset 8
	.cfi_rel_offset %rbp, 0
    push %rsi
    .cfi_adjust_cfa_offset 8
	.cfi_rel_offset %rsi, 0
    push %rdi
    .cfi_adjust_cfa_offset 8
	.cfi_rel_offset %rdi, 0
    push %r8
    .cfi_adjust_cfa_offset 8
	.cfi_rel_offset %r8, 0
    push %r9
    .cfi_adjust_cfa_offset 8
	.cfi_rel_offset %r9, 0
    push %r10
    .cfi_adjust_cfa_offset 8
	.cfi_rel_offset %r10, 0
    push %r11
    .cfi_adjust_cfa_offset 8
	.cfi_rel_offset %r11, 0
    push %r12
    .cfi_adjust_cfa_offset 8
	.cfi_rel_offset %r12, 0
    push %r13
    .cfi_adjust_cfa_offset 8
	.cfi_rel_offset %r13, 0
    push %r14
    .cfi_adjust_cfa_offset 8
	.cfi_rel_offset %r14, 0
    push %r15
    .cfi_adjust_cfa_offset 8
	.cfi_rel_offset %r15, 0

    cld
    xor %ebp, %ebp
    mov %rsp, %rdi
    call interruptDispatch

    pop %r15
    .cfi_adjust_cfa_offset -8
	.cfi_restore %r15
    pop %r14
    .cfi_adjust_cfa_offset -8
	.cfi_restore %r14
    pop %r13
    .cfi_adjust_cfa_offset -8
	.cfi_restore %r13
    pop %r12
    .cfi_adjust_cfa_offset -8
	.cfi_restore %r12
    pop %r11
    .cfi_adjust_cfa_offset -8
	.cfi_restore %r11
    pop %r10
    .cfi_adjust_cfa_offset -8
	.cfi_restore %r10
    pop %r9
    .cfi_adjust_cfa_offset -8
	.cfi_restore %r9
    pop %r8
    .cfi_adjust_cfa_offset -8
	.cfi_restore %r8
    pop %rdi
    .cfi_adjust_cfa_offset -8
	.cfi_restore %rdi
    pop %rsi
    .cfi_adjust_cfa_offset -8
	.cfi_restore %rsi
    pop %rbp
    .cfi_adjust_cfa_offset -8
	.cfi_restore %rbp
    pop %rdx
    .cfi_adjust_cfa_offset -8
	.cfi_restore %rdx
    pop %rcx
    .cfi_adjust_cfa_offset -8
	.cfi_restore %rcx
    pop %rbx
    .cfi_adjust_cfa_offset -8
	.cfi_restore %rbx
    pop %rax
    .cfi_adjust_cfa_offset -8
	.cfi_restore %rax

	// if returning to userspace swapgs
	testl $3, 0x18(%rsp)
	jz 1f
	swapgs
1:
    add $16, %rsp // pop the error code and interrupt number
    .cfi_adjust_cfa_offset -16
    iretq
    .cfi_endproc

.size _interrupt_handler_\number, . - _interrupt_handler_\number
.endm

INTERRUPT_HANDLER .NoError,  0
INTERRUPT_HANDLER .NoError,  1
INTERRUPT_HANDLER .NoError,  2
INTERRUPT_HANDLER .NoError,  3
INTERRUPT_HANDLER .NoError,  4
INTERRUPT_HANDLER .NoError,  5
INTERRUPT_HANDLER .NoError,  6
INTERRUPT_HANDLER .NoError,  7
INTERRUPT_HANDLER .HasError, 8
INTERRUPT_HANDLER .NoError,  9
INTERRUPT_HANDLER .HasError, 10
INTERRUPT_HANDLER .HasError, 11
INTERRUPT_HANDLER .HasError, 12
INTERRUPT_HANDLER .HasError, 13
INTERRUPT_HANDLER .HasError, 14
INTERRUPT_HANDLER .NoError,  15
INTERRUPT_HANDLER .NoError,  16
INTERRUPT_HANDLER .HasError, 17
INTERRUPT_HANDLER .NoError,  18
INTERRUPT_HANDLER .NoError,  19
INTERRUPT_HANDLER .NoError,  20
INTERRUPT_HANDLER .HasError, 21
INTERRUPT_HANDLER .NoError,  22
INTERRUPT_HANDLER .NoError,  23
INTERRUPT_HANDLER .NoError,  24
INTERRUPT_HANDLER .NoError,  25
INTERRUPT_HANDLER .NoError,  26
INTERRUPT_HANDLER .NoError,  27
INTERRUPT_HANDLER .NoError,  28
INTERRUPT_HANDLER .HasError, 29
INTERRUPT_HANDLER .HasError, 30
INTERRUPT_HANDLER .NoError,  31
INTERRUPT_HANDLER .NoError,  32
INTERRUPT_HANDLER .NoError,  33
INTERRUPT_HANDLER .NoError,  34
INTERRUPT_HANDLER .NoError,  35
INTERRUPT_HANDLER .NoError,  36
INTERRUPT_HANDLER .NoError,  37
INTERRUPT_HANDLER .NoError,  38
INTERRUPT_HANDLER .NoError,  39
INTERRUPT_HANDLER .NoError,  40
INTERRUPT_HANDLER .NoError,  41
INTERRUPT_HANDLER .NoError,  42
INTERRUPT_HANDLER .NoError,  43
INTERRUPT_HANDLER .NoError,  44
INTERRUPT_HANDLER .NoError,  45
INTERRUPT_HANDLER .NoError,  46
INTERRUPT_HANDLER .NoError,  47
INTERRUPT_HANDLER .NoError,  48
INTERRUPT_HANDLER .NoError,  49
INTERRUPT_HANDLER .NoError,  50
INTERRUPT_HANDLER .NoError,  51
INTERRUPT_HANDLER .NoError,  52
INTERRUPT_HANDLER .NoError,  53
INTERRUPT_HANDLER .NoError,  54
INTERRUPT_HANDLER .NoError,  55
INTERRUPT_HANDLER .NoError,  56
INTERRUPT_HANDLER .NoError,  57
INTERRUPT_HANDLER .NoError,  58
INTERRUPT_HANDLER .NoError,  59
INTERRUPT_HANDLER .NoError,  60
INTERRUPT_HANDLER .NoError,  61
INTERRUPT_HANDLER .NoError,  62
INTERRUPT_HANDLER .NoError,  63
INTERRUPT_HANDLER .NoError,  64
INTERRUPT_HANDLER .NoError,  65
INTERRUPT_HANDLER .NoError,  66
INTERRUPT_HANDLER .NoError,  67
INTERRUPT_HANDLER .NoError,  68
INTERRUPT_HANDLER .NoError,  69
INTERRUPT_HANDLER .NoError,  70
INTERRUPT_HANDLER .NoError,  71
INTERRUPT_HANDLER .NoError,  72
INTERRUPT_HANDLER .NoError,  73
INTERRUPT_HANDLER .NoError,  74
INTERRUPT_HANDLER .NoError,  75
INTERRUPT_HANDLER .NoError,  76
INTERRUPT_HANDLER .NoError,  77
INTERRUPT_HANDLER .NoError,  78
INTERRUPT_HANDLER .NoError,  79
INTERRUPT_HANDLER .NoError,  80
INTERRUPT_HANDLER .NoError,  81
INTERRUPT_HANDLER .NoError,  82
INTERRUPT_HANDLER .NoError,  83
INTERRUPT_HANDLER .NoError,  84
INTERRUPT_HANDLER .NoError,  85
INTERRUPT_HANDLER .NoError,  86
INTERRUPT_HANDLER .NoError,  87
INTERRUPT_HANDLER .NoError,  88
INTERRUPT_HANDLER .NoError,  89
INTERRUPT_HANDLER .NoError,  90
INTERRUPT_HANDLER .NoError,  91
INTERRUPT_HANDLER .NoError,  92
INTERRUPT_HANDLER .NoError,  93
INTERRUPT_HANDLER .NoError,  94
INTERRUPT_HANDLER .NoError,  95
INTERRUPT_HANDLER .NoError,  96
INTERRUPT_HANDLER .NoError,  97
INTERRUPT_HANDLER .NoError,  98
INTERRUPT_HANDLER .NoError,  99
INTERRUPT_HANDLER .NoError,  100
INTERRUPT_HANDLER .NoError,  101
INTERRUPT_HANDLER .NoError,  102
INTERRUPT_HANDLER .NoError,  103
INTERRUPT_HANDLER .NoError,  104
INTERRUPT_HANDLER .NoError,  105
INTERRUPT_HANDLER .NoError,  106
INTERRUPT_HANDLER .NoError,  107
INTERRUPT_HANDLER .NoError,  108
INTERRUPT_HANDLER .NoError,  109
INTERRUPT_HANDLER .NoError,  110
INTERRUPT_HANDLER .NoError,  111
INTERRUPT_HANDLER .NoError,  112
INTERRUPT_HANDLER .NoError,  113
INTERRUPT_HANDLER .NoError,  114
INTERRUPT_HANDLER .NoError,  115
INTERRUPT_HANDLER .NoError,  116
INTERRUPT_HANDLER .NoError,  117
INTERRUPT_HANDLER .NoError,  118
INTERRUPT_HANDLER .NoError,  119
INTERRUPT_HANDLER .NoError,  120
INTERRUPT_HANDLER .NoError,  121
INTERRUPT_HANDLER .NoError,  122
INTERRUPT_HANDLER .NoError,  123
INTERRUPT_HANDLER .NoError,  124
INTERRUPT_HANDLER .NoError,  125
INTERRUPT_HANDLER .NoError,  126
INTERRUPT_HANDLER .NoError,  127
INTERRUPT_HANDLER .NoError,  128
INTERRUPT_HANDLER .NoError,  129
INTERRUPT_HANDLER .NoError,  130
INTERRUPT_HANDLER .NoError,  131
INTERRUPT_HANDLER .NoError,  132
INTERRUPT_HANDLER .NoError,  133
INTERRUPT_HANDLER .NoError,  134
INTERRUPT_HANDLER .NoError,  135
INTERRUPT_HANDLER .NoError,  136
INTERRUPT_HANDLER .NoError,  137
INTERRUPT_HANDLER .NoError,  138
INTERRUPT_HANDLER .NoError,  139
INTERRUPT_HANDLER .NoError,  140
INTERRUPT_HANDLER .NoError,  141
INTERRUPT_HANDLER .NoError,  142
INTERRUPT_HANDLER .NoError,  143
INTERRUPT_HANDLER .NoError,  144
INTERRUPT_HANDLER .NoError,  145
INTERRUPT_HANDLER .NoError,  146
INTERRUPT_HANDLER .NoError,  147
INTERRUPT_HANDLER .NoError,  148
INTERRUPT_HANDLER .NoError,  149
INTERRUPT_HANDLER .NoError,  150
INTERRUPT_HANDLER .NoError,  151
INTERRUPT_HANDLER .NoError,  152
INTERRUPT_HANDLER .NoError,  153
INTERRUPT_HANDLER .NoError,  154
INTERRUPT_HANDLER .NoError,  155
INTERRUPT_HANDLER .NoError,  156
INTERRUPT_HANDLER .NoError,  157
INTERRUPT_HANDLER .NoError,  158
INTERRUPT_HANDLER .NoError,  159
INTERRUPT_HANDLER .NoError,  160
INTERRUPT_HANDLER .NoError,  161
INTERRUPT_HANDLER .NoError,  162
INTERRUPT_HANDLER .NoError,  163
INTERRUPT_HANDLER .NoError,  164
INTERRUPT_HANDLER .NoError,  165
INTERRUPT_HANDLER .NoError,  166
INTERRUPT_HANDLER .NoError,  167
INTERRUPT_HANDLER .NoError,  168
INTERRUPT_HANDLER .NoError,  169
INTERRUPT_HANDLER .NoError,  170
INTERRUPT_HANDLER .NoError,  171
INTERRUPT_HANDLER .NoError,  172
INTERRUPT_HANDLER .NoError,  173
INTERRUPT_HANDLER .NoError,  174
INTERRUPT_HANDLER .NoError,  175
INTERRUPT_HANDLER .NoError,  176
INTERRUPT_HANDLER .NoError,  177
INTERRUPT_HANDLER .NoError,  178
INTERRUPT_HANDLER .NoError,  179
INTERRUPT_HANDLER .NoError,  180
INTERRUPT_HANDLER .NoError,  181
INTERRUPT_HANDLER .NoError,  182
INTERRUPT_HANDLER .NoError,  183
INTERRUPT_HANDLER .NoError,  184
INTERRUPT_HANDLER .NoError,  185
INTERRUPT_HANDLER .NoError,  186
INTERRUPT_HANDLER .NoError,  187
INTERRUPT_HANDLER .NoError,  188
INTERRUPT_HANDLER .NoError,  189
INTERRUPT_HANDLER .NoError,  190
INTERRUPT_HANDLER .NoError,  191
INTERRUPT_HANDLER .NoError,  192
INTERRUPT_HANDLER .NoError,  193
INTERRUPT_HANDLER .NoError,  194
INTERRUPT_HANDLER .NoError,  195
INTERRUPT_HANDLER .NoError,  196
INTERRUPT_HANDLER .NoError,  197
INTERRUPT_HANDLER .NoError,  198
INTERRUPT_HANDLER .NoError,  199
INTERRUPT_HANDLER .NoError,  200
INTERRUPT_HANDLER .NoError,  201
INTERRUPT_HANDLER .NoError,  202
INTERRUPT_HANDLER .NoError,  203
INTERRUPT_HANDLER .NoError,  204
INTERRUPT_HANDLER .NoError,  205
INTERRUPT_HANDLER .NoError,  206
INTERRUPT_HANDLER .NoError,  207
INTERRUPT_HANDLER .NoError,  208
INTERRUPT_HANDLER .NoError,  209
INTERRUPT_HANDLER .NoError,  210
INTERRUPT_HANDLER .NoError,  211
INTERRUPT_HANDLER .NoError,  212
INTERRUPT_HANDLER .NoError,  213
INTERRUPT_HANDLER .NoError,  214
INTERRUPT_HANDLER .NoError,  215
INTERRUPT_HANDLER .NoError,  216
INTERRUPT_HANDLER .NoError,  217
INTERRUPT_HANDLER .NoError,  218
INTERRUPT_HANDLER .NoError,  219
INTERRUPT_HANDLER .NoError,  220
INTERRUPT_HANDLER .NoError,  221
INTERRUPT_HANDLER .NoError,  222
INTERRUPT_HANDLER .NoError,  223
INTERRUPT_HANDLER .NoError,  224
INTERRUPT_HANDLER .NoError,  225
INTERRUPT_HANDLER .NoError,  226
INTERRUPT_HANDLER .NoError,  227
INTERRUPT_HANDLER .NoError,  228
INTERRUPT_HANDLER .NoError,  229
INTERRUPT_HANDLER .NoError,  230
INTERRUPT_HANDLER .NoError,  231
INTERRUPT_HANDLER .NoError,  232
INTERRUPT_HANDLER .NoError,  233
INTERRUPT_HANDLER .NoError,  234
INTERRUPT_HANDLER .NoError,  235
INTERRUPT_HANDLER .NoError,  236
INTERRUPT_HANDLER .NoError,  237
INTERRUPT_HANDLER .NoError,  238
INTERRUPT_HANDLER .NoError,  239
INTERRUPT_HANDLER .NoError,  240
INTERRUPT_HANDLER .NoError,  241
INTERRUPT_HANDLER .NoError,  242
INTERRUPT_HANDLER .NoError,  243
INTERRUPT_HANDLER .NoError,  244
INTERRUPT_HANDLER .NoError,  245
INTERRUPT_HANDLER .NoError,  246
INTERRUPT_HANDLER .NoError,  247
INTERRUPT_HANDLER .NoError,  248
INTERRUPT_HANDLER .NoError,  249
INTERRUPT_HANDLER .NoError,  250
INTERRUPT_HANDLER .NoError,  251
INTERRUPT_HANDLER .NoError,  252
INTERRUPT_HANDLER .NoError,  253
INTERRUPT_HANDLER .NoError,  254
INTERRUPT_HANDLER .NoError,  255
 