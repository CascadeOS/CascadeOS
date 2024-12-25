// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

//! Defines the interface of the architecture specific code.

pub const interrupts = struct {
    /// Disable interrupts and halt the CPU.
    ///
    /// This is a decl not a wrapper function like the other functions so that it can be inlined into a naked function.
    pub const disableInterruptsAndHalt = current.interrupts.disableInterruptsAndHalt;
};

const current = switch (cascade_target) {
    // x64 is first to help zls, atleast while x64 is the main target.
    .x64 => @import("x64/x64.zig"),
    .arm64 => @import("arm64/arm64.zig"),
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const cascade_target = @import("cascade_target").arch;
