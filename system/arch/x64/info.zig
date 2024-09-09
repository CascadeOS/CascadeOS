// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

//! Architecture specific runtime discovered/calculated values.

pub const cpu_id = lib_x64.cpu_id;

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

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const x64 = @import("x64.zig");
const lib_x64 = @import("lib_x64");
