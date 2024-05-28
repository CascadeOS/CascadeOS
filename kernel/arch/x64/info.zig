// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

//! Architecture specific runtime discovered/calculated values.

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const x64 = @import("x64.zig");

pub const cpu_id = x64.cpu_id;

/// The duration of a TSC tick in femptopseconds, if known from CPUID.
pub var tsc_tick_duration_fs: ?u64 = null;

/// The duration of a LAPIC tick in femptoseconds, if known from CPUID.
///
/// This needs to be multipled by the divide configuration register value to get the actual tick duration.
pub var lapic_base_tick_duration_fs: ?u64 = null;
