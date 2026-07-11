// SPDX-License-Identifier: BSD-3-Clause
// SPDX-FileCopyrightText: CascadeOS Contributors

const std = @import("std");

const cascade = @import("cascade");

pub fn main() void {
    // TODO: support normal `std.debug.print`
    cascade.debugPrint("hello world\n");
}

// TODO: all the decls below should only be defined when building for cascade, this is no longer possible without usingnamespace
//       for now building user applications targeting the host is disabled, a possible temporary solution could be seperate cascade and non-cascade root files

pub const _start = void;
comptime {
    cascade.exportEntry();
}

pub const std_options: std.Options = .{
    .page_size_min = cascade.std_override.heap.page_size_min,
    .page_size_max = cascade.std_override.heap.page_size_max,
    .queryPageSize = cascade.std_override.heap.queryPageSize,
};

pub const panic = cascade.std_override.panic;

pub const std_options_debug_threaded_io = cascade.std_override.std_options.debug_threaded_io;
pub const std_options_debug_io = cascade.std_override.std_options.debug_io;
pub const std_options_FilePermissions = cascade.std_override.std_options.FilePermissions;
pub const std_options_cwd = cascade.std_override.std_options.cwd;
pub const std_options_elf_debug_info_search_paths = cascade.std_override.std_options.debugInfoSearchPaths;

pub const debug = cascade.std_override.debug;
pub const os = cascade.std_override.os;
