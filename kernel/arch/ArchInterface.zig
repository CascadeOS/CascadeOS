// SPDX-License-Identifier: MIT

const std = @import("std");
const kernel = @import("root");

const ArchInterface = @This();

earlyLogFn: fn (
    comptime scope: @Type(.EnumLiteral),
    comptime message_level: kernel.log.Level,
    comptime format: []const u8,
    args: anytype,
) void,

disableInterruptsAndHalt: fn () noreturn,
