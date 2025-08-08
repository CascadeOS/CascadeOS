// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub const TPIDR_EL1 = MSR(u64, "TPIDR_EL1");

pub fn MSR(comptime T: type, comptime name: []const u8) type {
    return struct {
        pub fn read() T {
            return asm ("MRS %[out], " ++ name
                : [out] "=r" (-> T),
            );
        }

        pub fn write(val: T) void {
            asm volatile ("MSR " ++ name ++ ", %[in]"
                :
                : [in] "X" (val),
            );
        }

        pub fn writeImm(comptime val: T) void {
            asm volatile ("MSR " ++ name ++ ", %[in]"
                :
                : [in] "i" (val),
            );
        }
    };
}

const core = @import("core");
const std = @import("std");
