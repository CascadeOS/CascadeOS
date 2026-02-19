/* SPDX-License-Identifier: LicenseRef-NON-AI-CC0-1.0 */
/* SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz> */

KERNEL_BASE = 0xffffffff80000000; /* this must be kept in sync with `cascade.config.kernel_base_address` */
STANDARD_PAGE_SIZE = 0x1000;

OUTPUT_FORMAT(elf64-littleaarch64)
OUTPUT_ARCH(aarch64)

PHDRS
{
    null    PT_NULL    FLAGS(0);                   /* Null segment */
    text    PT_LOAD    FLAGS((1 << 0) | (1 << 2)); /* Execute + Read */
    rodata  PT_LOAD    FLAGS((1 << 2));            /* Read only */
    data    PT_LOAD    FLAGS((1 << 1) | (1 << 2)); /* Write + Read */
    dynamic PT_DYNAMIC FLAGS((1 << 2));            /* Read only */
    sdf     PT_LOAD    FLAGS((1 << 2));            /* Read only */
}

SECTIONS
{
    . = KERNEL_BASE;

    . = ALIGN(STANDARD_PAGE_SIZE);

    __text_start = .;

    .text : {
        *(.text .text.*)
    } :text

    __text_end = .;

    . = ALIGN(STANDARD_PAGE_SIZE);

    __rodata_start = .;

    .rodata : {
        *(.rodata .rodata.*)
    } :rodata

    .rela.dyn : {
        *(.rela.dyn .rela.dyn.*)
    } :rodata

    .dynstr : {
        *(.dynstr .dynstr.*)
    } :rodata

    .dynsym : {
        *(.dynsym .dynsym.*)
    } :rodata

    __rodata_end = .;

    . = ALIGN(STANDARD_PAGE_SIZE);

    __data_start = .;

    .data : {
        *(.data .data.*)
    } :data

    .dynamic : {
        *(.dynamic .dynamic.*)
    } :data :dynamic

    .bss : {
        *(.bss .bss.*)
        *(COMMON)
    } :data

    __data_end = .;

    . = ALIGN(STANDARD_PAGE_SIZE);

    __sdf_start = .;

    .sdf : { /* sdf_builder embeds the SDF data into this section */
        . += STANDARD_PAGE_SIZE;
    } :sdf

    /DISCARD/ : {
        *(.eh_frame)
        *(.eh_frame_hdr)
        *(.gnu.hash)
        *(.hash)
        *(.note .note.*)
        *(.comment)
    }
}