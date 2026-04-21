// SPDX-License-Identifier: BSD-3-Clause
// SPDX-FileCopyrightText: CascadeOS Contributors

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");

pub const panic = cascade.debug.panic_interface;

pub const std_options: std.Options = .{
    .log_level = cascade.debug.log.log_level.toStd(),
    .logFn = cascade.debug.log.stdLogImpl,

    .page_size_min = arch.paging.standard_page_size.value,
    .page_size_max = arch.paging.largest_page_size.value,
    .queryPageSize = struct {
        fn queryPageSize() usize {
            return arch.paging.standard_page_size.value;
        }
    }.queryPageSize,

    .side_channels_mitigations = .full,
};

pub const std_options_debug_io: std.Io = undefined;

pub const debug = cascade.debug.std_debug_exports;

comptime {
    @import("boot").exportEntryPoints();
}
