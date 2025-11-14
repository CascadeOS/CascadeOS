// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const Task = cascade.Task;
pub const panic = cascade.debug.panic_interface;
const core = @import("core");

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

comptime {
    @import("boot").exportEntryPoints();
}
