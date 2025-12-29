// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

//! Architecture specific runtime discovered/calculated values.

const std = @import("std");

const arch = @import("arch");
const kernel = @import("kernel");
const Task = kernel.Task;
const core = @import("core");

const x64 = @import("../x64.zig");
pub const cpu_id = @import("cpu_id.zig");

/// The duration of a TSC tick in femptopseconds, if known from CPUID.
pub var tsc_tick_duration_fs: ?u64 = null;

/// The duration of a LAPIC tick in femptoseconds, if known from CPUID.
///
/// This needs to be multipled by the divide configuration register value to get the actual tick duration.
pub var lapic_base_tick_duration_fs: ?u64 = null;

/// Do we have a PIC?
///
/// Assumed to be true until proven otherwise.
pub var have_pic: bool = true;

/// Do we have a PS/2 controller (Intel 8042)?
///
/// Assumed to be true until proven otherwise.
pub var have_ps2_controller: bool = true;

/// Do we have a CMOS RTC?
///
/// Assumed to be true until proven otherwise.
pub var have_cmos_rtc: bool = true;

/// Are message signaled interrupts (MSI) supported?
///
/// Assumed to be false until proven otherwise.
pub var msi_supported: bool = false;

/// The number of MTRR variable range registers.
pub var mtrr_number_of_variable_registers: u8 = 0;

/// Are write combining memory types supported?
pub var mtrr_write_combining_supported: bool = false;

pub const xsave = struct {
    /// The method used to save extended state.
    ///
    /// UNDEFINED: xsave is asserted to be supported
    pub var method: Method = undefined;

    /// The value that each executor sets XCr0 to, also used on extended state save/restore.
    ///
    /// UNDEFINED: xsave is asserted to be supported
    pub var xcr0_value: x64.registers.XCr0 = undefined;

    /// The size of the xsave area.
    ///
    /// UNDEFINED: xsave is asserted to be supported
    pub var xsave_area_size: core.Size = undefined;

    pub const Method = enum {
        xsave,
        xsaveopt,
    };
};
