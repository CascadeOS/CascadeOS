// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>

/// Ext2/3/4
pub const ext = @import("ext.zig");

/// File Allocation Table (FAT)
pub const fat = @import("fat.zig");

/// GUID Partition Table (GPT)
pub const gpt = @import("gpt.zig");

/// Master Boot Record (MBR)
pub const mbr = @import("mbr.zig");

comptime {
    std.testing.refAllDeclsRecursive(@This());
}

const std = @import("std");
const core = @import("core");
