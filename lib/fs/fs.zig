// SPDX-License-Identifier: BSD-3-Clause
// SPDX-FileCopyrightText: CascadeOS Contributors

const std = @import("std");

/// Ext2/3/4
pub const ext = @import("ext.zig");
/// File Allocation Table (FAT)
pub const fat = @import("fat.zig");
/// GUID Partition Table (GPT)
pub const gpt = @import("gpt.zig");
/// Master Boot Record (MBR)
pub const mbr = @import("mbr.zig");

comptime {
    std.testing.refAllDecls(@This());
}
