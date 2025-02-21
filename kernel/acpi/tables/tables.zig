// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>

pub const DBG2 = @import("DBG2.zig").DBG2;
pub const DSDT = @import("DSDT.zig").DSDT;
pub const FADT = @import("FADT.zig").FADT;
pub const HPET = @import("HPET.zig").HPET;
pub const MADT = @import("MADT.zig").MADT;
pub const MCFG = @import("MCFG.zig").MCFG;
pub const RSDP = @import("RSDP.zig").RSDP;
pub const SharedHeader = @import("SharedHeader.zig").SharedHeader;
pub const SPCR = @import("SPCR.zig").SPCR;

const core = @import("core");
const std = @import("std");
