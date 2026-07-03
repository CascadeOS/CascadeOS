// SPDX-License-Identifier: BSD-3-Clause
// SPDX-FileCopyrightText: CascadeOS Contributors

const cascade = @import("cascade");
const core = @import("core");
const std = @import("std");

const riscv = @import("riscv.zig");

pub const PageTable = extern struct {
    // TODO: these values are copied from the x64, so all of them need to be checked
    pub const small_page_size: core.Size = .from(4, .kib);
    pub const large_page_size: core.Size = .from(1, .gib);
};
