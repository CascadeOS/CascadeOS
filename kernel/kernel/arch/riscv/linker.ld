/* SPDX-License-Identifier: CC0-1.0 */
/* SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz> */

OUTPUT_FORMAT(elf64-littleriscv)
OUTPUT_ARCH(riscv)

PHDRS
{
    null         PT_NULL    FLAGS(0) ;                   /* Null segment */
    text         PT_LOAD    FLAGS((1 << 0) | (1 << 2)) ; /* Execute + Read */
    rodata       PT_LOAD    FLAGS((1 << 2)) ;            /* Read only */
    data         PT_LOAD    FLAGS((1 << 1) | (1 << 2)) ; /* Write + Read */
    dynamic      PT_DYNAMIC FLAGS((1 << 2)) ;            /* Read only */

    sdf          PT_LOAD    FLAGS((1 << 2)) ;            /* Read only */
}

SECTIONS
{
    /* This must be kept in sync with `kernel.config.kernel_base_address` */
    . = 0xffffffff80000000;

    . = ALIGN(CONSTANT(MAXPAGESIZE));

    __text_start = .;

    .text : {
        *(.text .text.*)
    } :text

    __text_end = .;

    PROVIDE(_global_pointer = .);

    . = ALIGN(CONSTANT(MAXPAGESIZE));

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

    . = ALIGN(CONSTANT(MAXPAGESIZE));

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

    . = ALIGN(CONSTANT(MAXPAGESIZE));

    __sdf_start = .;

    .sdf : { /* sdf_builder embeds the SDF data into this section */
        . += CONSTANT(MAXPAGESIZE);
    } :sdf

    /DISCARD/ : {
        *(.eh_frame)
        *(.eh_frame_hdr)
        *(.gnu.hash)
        *(.hash)
        *(.note .note.*)
        *(.comment)
        *(.riscv.attributes)
    }
}