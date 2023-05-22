// SPDX-License-Identifier: MIT

const std = @import("std");
const kernel = @import("root");

const ArchInterface = @This();

/// Responsible for:
/// - Setting up the early output used by `earlyLogFn`
/// - Installing a simple panic function
setupEarlyOutput: fn () void,

/// Use whatever early output system is available to print a message.
earlyOutputRaw: fn (str: []const u8) void,

/// Use the early output system to print a formatted log message.
earlyLogFn: fn (
    comptime scope: @Type(.EnumLiteral),
    comptime message_level: kernel.log.Level,
    comptime format: []const u8,
    args: anytype,
) void,

/// Disable interrupts and put the CPU to sleep.
disableInterruptsAndHalt: fn () noreturn,
