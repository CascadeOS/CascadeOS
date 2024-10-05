/* SPDX-License-Identifier: CC0-1.0 */
/* SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz> */

OUTPUT_FORMAT(elf64-x86-64)
OUTPUT_ARCH(i386:x86-64)

PHDRS
{
    null         PT_NULL    FLAGS(0) ;                   /* Null segment */
    text         PT_LOAD    FLAGS((1 << 0) | (1 << 2)) ; /* Execute + Read */
    rodata       PT_LOAD    FLAGS((1 << 2)) ;            /* Read only */
    data         PT_LOAD    FLAGS((1 << 1) | (1 << 2)) ; /* Write + Read */

    sdf          PT_LOAD    FLAGS((1 << 2)) ;            /* Read only */
}

SECTIONS
{
    /* This must be kept in sync with `kernel.config.kernel_base_address` */
    . = 0xffffffff80000000;

    .text : {
        __text_start = .;
        *(.text .text.*)
        __text_end = .;
    } :text

    . = ALIGN(CONSTANT(MAXPAGESIZE));

    .rodata : {
        __rodata_start = .;
        *(.rodata .rodata.*)
        __rodata_end = .;
    } :rodata

    . = ALIGN(CONSTANT(MAXPAGESIZE));

    .data : {
        __data_start = .;
        *(.data .data.*)
    } :data

    .bss : {
        *(COMMON)
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        __data_end = .;
    } :data

    . = ALIGN(CONSTANT(MAXPAGESIZE));

    .sdf : { /* sdf_builder embeds the SDF data into this section */
        __sdf_start = .;
        . += 0x1000;
    } :sdf

    /DISCARD/ : {
        *(.eh_frame)
        *(.note .note.*)
        *(.comment)
    }
}