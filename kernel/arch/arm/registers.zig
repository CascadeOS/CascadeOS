// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const Task = cascade.Task;
const core = @import("core");

const arm = @import("arm.zig");

pub const TPIDR_EL1 = MSR(u64, "TPIDR_EL1");

pub fn MSR(comptime T: type, comptime name: []const u8) type {
    return struct {
        pub inline fn read() T {
            return asm ("MRS %[out], " ++ name
                : [out] "=r" (-> T),
            );
        }

        pub inline fn write(val: T) void {
            asm volatile ("MSR " ++ name ++ ", %[in]"
                :
                : [in] "X" (val),
            );
        }

        pub inline fn writeImm(comptime val: T) void {
            asm volatile ("MSR " ++ name ++ ", %[in]"
                :
                : [in] "i" (val),
            );
        }
    };
}
