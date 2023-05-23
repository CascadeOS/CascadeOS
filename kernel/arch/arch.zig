// SPDX-License-Identifier: MIT

const std = @import("std");
const kernel = @import("root");

pub const aarch64 = @import("aarch64/aarch64.zig");
pub const x86_64 = @import("x86_64/x86_64.zig");

const current = switch (kernel.info.arch) {
    .aarch64 => aarch64,
    .x86_64 => x86_64,
};

comptime {
    // ensure any architecture specific code is referenced
    _ = current;
}

/// Functionality that is only intended to be used during system setup only.
pub const setup = struct {
    /// Responsible for:
    /// - Setting up the early output used by `earlyLogFn`
    /// - Installing a simple panic function
    ///
    /// Signature compatible with: `fn () void`
    pub const setupEarlyOutput = current.exposed.setupEarlyOutput;

    /// Use whatever early output system is available to print a message.
    ///
    /// Signature compatible with: `fn (str: []const u8) void`
    pub const earlyOutputRaw = current.exposed.earlyOutputRaw;

    /// Use the early output system to print a formatted log message.
    ///
    /// Signature compatible with: `fn (scope: @Type(.EnumLiteral), message_level: kernel.log.Level, format: []const u8, args: anytype) void`
    pub const earlyLogFn = current.exposed.earlyLogFn;
};

/// Disable interrupts and put the CPU to sleep.
///
/// Signature compatible with: `fn () noreturn`
pub const disableInterruptsAndHalt = current.exposed.disableInterruptsAndHalt;
