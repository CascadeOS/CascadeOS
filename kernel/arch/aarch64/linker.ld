/* SPDX-License-Identifier: CC0-1.0 */
/* SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz> */

OUTPUT_FORMAT(elf64-littleaarch64)
OUTPUT_ARCH(aarch64)

PHDRS
{
    null         PT_NULL    FLAGS(0) ;                   /* Null segment */
    text         PT_LOAD    FLAGS((1 << 0) | (1 << 2)) ; /* Execute + Read */
    rodata       PT_LOAD    FLAGS((1 << 2)) ;            /* Read only */
    data         PT_LOAD    FLAGS((1 << 1) | (1 << 2)) ; /* Write + Read */
    dynamic      PT_DYNAMIC FLAGS((1 << 1) | (1 << 2)) ; /* Dynamic */

    sdf          PT_LOAD    FLAGS((1 << 2)) ;            /* Read only - assumed to be the last program header by sdf_builder */
}

SECTIONS
{
    . = 0xffffffff80000000;

    .text ALIGN(4K) : {
        __text_start = .;
        *(.text .text.*)
        __text_end = .;
    } :text

    .rodata ALIGN(4K) : {
        __rodata_start = .;
        *(.rodata .rodata.*)
        __rodata_end = .;
    } :rodata

    .data ALIGN(4K) : {
        __data_start = .;
        *(.data .data.*)
    } :data

    .dynamic : {
        *(.dynamic .dynamic.*)
    } :data :dynamic

    .bss : {
        *(COMMON)
        *(.bss .bss.*)
        __data_end = .;
    } :data

    .sdf ALIGN(4K) : { /* sdf_builder embeds the SDF data into this section */
        __sdf_start = .;
        . += 0x1000;
    } :sdf

    /DISCARD/ : {
        *(.eh_frame)
        *(.note .note.*)
        *(.comment)
    }
}