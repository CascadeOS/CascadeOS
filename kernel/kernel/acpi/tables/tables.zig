// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const kernel = @import("kernel");
const Task = kernel.Task;
const acpi = kernel.acpi;
const core = @import("core");

pub const DBG2 = @import("DBG2.zig").DBG2;
pub const DSDT = @import("DSDT.zig").DSDT;
pub const FADT = @import("FADT.zig").FADT;
pub const HPET = @import("HPET.zig").HPET;
pub const MADT = @import("MADT.zig").MADT;
pub const MCFG = @import("MCFG.zig").MCFG;
pub const RSDP = @import("RSDP.zig").RSDP;
pub const SharedHeader = @import("SharedHeader.zig").SharedHeader;
pub const SPCR = @import("SPCR.zig").SPCR;
pub const TPM2 = @import("TPM2.zig").TPM2;
