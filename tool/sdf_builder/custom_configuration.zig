// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const ToolDescription = @import("../../build/ToolDescription.zig");

pub fn customConfiguration(
    b: *std.Build,
    tool_description: ToolDescription,
    module: *std.Build.Module,
) void {
    _ = tool_description;

    const lib_dwarf = b.dependency("libdwarf", .{}).path("src/lib/libdwarf");

    module.link_libc = true;
    module.addIncludePath(lib_dwarf);

    module.addCSourceFiles(.{
        .root = lib_dwarf,
        .files = &.{
            "dwarf_abbrev.c",
            "dwarf_alloc.c",
            "dwarf_arange.c",
            "dwarf_crc.c",
            "dwarf_crc32.c",
            "dwarf_debugaddr.c",
            "dwarf_debuglink.c",
            "dwarf_die_deliv.c",
            "dwarf_debugnames.c",
            "dwarf_debug_sup.c",
            "dwarf_dsc.c",
            "dwarf_elf_load_headers.c",
            "dwarf_elfread.c",
            "dwarf_elf_rel_detector.c",
            "dwarf_error.c",
            "dwarf_fill_in_attr_form.c",
            "dwarf_find_sigref.c",
            "dwarf_fission_to_cu.c",
            "dwarf_form.c",
            "dwarf_form_class_names.c",
            "dwarf_frame.c",
            "dwarf_frame2.c",
            "dwarf_gdbindex.c",
            "dwarf_generic_init.c",
            "dwarf_global.c",
            "dwarf_gnu_index.c",
            "dwarf_groups.c",
            "dwarf_harmless.c",
            "dwarf_init_finish.c",
            "dwarf_leb.c",
            "dwarf_line.c",
            "dwarf_loc.c",
            "dwarf_locationop_read.c",
            "dwarf_loclists.c",
            "dwarf_machoread.c",
            "dwarf_macro.c",
            "dwarf_macro5.c",
            "dwarf_memcpy_swap.c",
            "dwarf_names.c",
            "dwarf_object_detector.c",
            "dwarf_object_read_common.c",
            "dwarf_peread.c",
            "dwarf_print_lines.c",
            "dwarf_query.c",
            "dwarf_ranges.c",
            "dwarf_rnglists.c",
            "dwarf_safe_arithmetic.c",
            "dwarf_safe_strcpy.c",
            "dwarf_secname_ck.c",
            "dwarf_seekr.c",
            "dwarf_setup_sections.c",
            "dwarf_str_offsets.c",
            "dwarf_string.c",
            "dwarf_stringsection.c",
            "dwarf_tied.c",
            "dwarf_tsearchhash.c",
            "dwarf_util.c",
            "dwarf_xu_index.c",
        },
    });

    // TODO: im sure this is not the correct way to do this, but :shrug:
    module.addConfigHeader(b.addConfigHeader(.{}, .{
        .HAVE_DLFCN_H = 1,
        .HAVE_FCNTL_H = 1,
        .HAVE_INTPTR_T = 1,
        .HAVE_INTTYPES_H = 1,
        .HAVE_STDDEF_H = 1,
        .HAVE_STDINT_H = 1,
        .HAVE_STDIO_H = 1,
        .HAVE_STDLIB_H = 1,
        .HAVE_STRINGS_H = 1,
        .HAVE_STRING_H = 1,
        .HAVE_SYS_STAT_H = 1,
        .HAVE_SYS_TYPES_H = 1,
        .HAVE_UINTPTR_T = 1,
        .HAVE_UNISTD_H = 1,
        .HAVE_UNUSED_ATTRIBUTE = 1,
        .PACKAGE_VERSION = "0.9.2",
    }));
}
