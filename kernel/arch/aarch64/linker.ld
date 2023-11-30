/* SPDX-License-Identifier: MIT */

OUTPUT_FORMAT(elf64-littleaarch64)
OUTPUT_ARCH(aarch64)

ENTRY(_start)

PHDRS
{
    null         PT_NULL    FLAGS(0) ;                   /* Null segment */
    init_text    PT_LOAD    FLAGS((1 << 0) | (1 << 2)) ; /* Execute + Read */
    init_data    PT_LOAD    FLAGS((1 << 1) | (1 << 2)) ; /* Write + Read */
    text         PT_LOAD    FLAGS((1 << 0) | (1 << 2)) ; /* Execute + Read */
    rodata       PT_LOAD    FLAGS((1 << 2)) ;            /* Read only */
    data         PT_LOAD    FLAGS((1 << 1) | (1 << 2)) ; /* Write + Read */
    dynamic      PT_DYNAMIC FLAGS((1 << 1) | (1 << 2)) ; /* Dynamic */
}

SECTIONS
{
    /* This must be kept in sync with `kernel.info.kernel_base_address` */
    . = 0xffffffff80000000;

    /* This must be kept in sync with `kernel.info.init_code` */
    .init_text ALIGN(4K) : {
        __init_text_start = .;
        *(.init_text .init_text.*)
        __init_text_end = .;
    } :init_text

    /* This must be kept in sync with `kernel.info.init_data` */
    .init_data ALIGN(4K) : {
        __init_data_start = .;
        *(.init_data .init_data.*)
        __init_data_end = .;
    } :init_data

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

    /DISCARD/ : {
        *(.eh_frame)
        *(.note .note.*)
        *(.comment)
    }
}