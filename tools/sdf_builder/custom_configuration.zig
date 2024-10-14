// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

pub fn customConfiguration(
    b: *std.Build,
    tool_description: ToolDescription,
    exe: *std.Build.Step.Compile,
) void {
    if (b.graph.host.result.os.tag == .linux) {
        // Use musl to remove include of "/usr/include"
        exe.root_module.resolved_target.?.query.abi = .musl;
        exe.root_module.resolved_target.?.result.abi = .musl;
    }

    exe.linkLibC();

    const lib_dwarf = b.dependency("libdwarf", .{});

    const own_directory_path = b.pathJoin(&.{
        "tools",
        tool_description.name,
    });

    exe.addIncludePath(b.path(own_directory_path));

    exe.addIncludePath(lib_dwarf.path("src/lib/libdwarf"));

    const c_files: []const []const u8 = &.{
        "src/lib/libdwarf/dwarf_abbrev.c",
        "src/lib/libdwarf/dwarf_alloc.c",
        "src/lib/libdwarf/dwarf_arange.c",
        "src/lib/libdwarf/dwarf_crc.c",
        "src/lib/libdwarf/dwarf_crc32.c",
        "src/lib/libdwarf/dwarf_debugaddr.c",
        "src/lib/libdwarf/dwarf_debuglink.c",
        "src/lib/libdwarf/dwarf_die_deliv.c",
        "src/lib/libdwarf/dwarf_debugnames.c",
        "src/lib/libdwarf/dwarf_debug_sup.c",
        "src/lib/libdwarf/dwarf_dsc.c",
        "src/lib/libdwarf/dwarf_elf_load_headers.c",
        "src/lib/libdwarf/dwarf_elfread.c",
        "src/lib/libdwarf/dwarf_elf_rel_detector.c",
        "src/lib/libdwarf/dwarf_error.c",
        "src/lib/libdwarf/dwarf_fill_in_attr_form.c",
        "src/lib/libdwarf/dwarf_find_sigref.c",
        "src/lib/libdwarf/dwarf_fission_to_cu.c",
        "src/lib/libdwarf/dwarf_form.c",
        "src/lib/libdwarf/dwarf_form_class_names.c",
        "src/lib/libdwarf/dwarf_frame.c",
        "src/lib/libdwarf/dwarf_frame2.c",
        "src/lib/libdwarf/dwarf_gdbindex.c",
        "src/lib/libdwarf/dwarf_generic_init.c",
        "src/lib/libdwarf/dwarf_global.c",
        "src/lib/libdwarf/dwarf_gnu_index.c",
        "src/lib/libdwarf/dwarf_groups.c",
        "src/lib/libdwarf/dwarf_harmless.c",
        "src/lib/libdwarf/dwarf_init_finish.c",
        "src/lib/libdwarf/dwarf_leb.c",
        "src/lib/libdwarf/dwarf_line.c",
        "src/lib/libdwarf/dwarf_loc.c",
        "src/lib/libdwarf/dwarf_locationop_read.c",
        "src/lib/libdwarf/dwarf_loclists.c",
        "src/lib/libdwarf/dwarf_machoread.c",
        "src/lib/libdwarf/dwarf_macro.c",
        "src/lib/libdwarf/dwarf_macro5.c",
        "src/lib/libdwarf/dwarf_memcpy_swap.c",
        "src/lib/libdwarf/dwarf_names.c",
        "src/lib/libdwarf/dwarf_object_detector.c",
        "src/lib/libdwarf/dwarf_object_read_common.c",
        "src/lib/libdwarf/dwarf_peread.c",
        "src/lib/libdwarf/dwarf_print_lines.c",
        "src/lib/libdwarf/dwarf_query.c",
        "src/lib/libdwarf/dwarf_ranges.c",
        "src/lib/libdwarf/dwarf_rnglists.c",
        "src/lib/libdwarf/dwarf_safe_arithmetic.c",
        "src/lib/libdwarf/dwarf_safe_strcpy.c",
        "src/lib/libdwarf/dwarf_secname_ck.c",
        "src/lib/libdwarf/dwarf_seekr.c",
        "src/lib/libdwarf/dwarf_setup_sections.c",
        "src/lib/libdwarf/dwarf_str_offsets.c",
        "src/lib/libdwarf/dwarf_string.c",
        "src/lib/libdwarf/dwarf_stringsection.c",
        "src/lib/libdwarf/dwarf_tied.c",
        "src/lib/libdwarf/dwarf_tsearchhash.c",
        "src/lib/libdwarf/dwarf_util.c",
        "src/lib/libdwarf/dwarf_xu_index.c",
    };

    exe.addCSourceFiles(.{
        .root = lib_dwarf.path(""),
        .files = c_files,
        .flags = &.{"-fno-sanitize=undefined"},
    });
}

const std = @import("std");
const builtin = @import("builtin");

const helpers = @import("../../build/helpers.zig");
const ToolDescription = @import("../../build/ToolDescription.zig");
