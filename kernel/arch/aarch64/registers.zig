// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const aarch64 = @import("aarch64.zig");

pub const TPIDR_EL1_CoreData = MSR(*kernel.CoreData, "TPIDR_EL1");
pub const TPIDR_EL1_SafeCoreData = MSR(?*kernel.CoreData, "TPIDR_EL1");

pub fn MSR(comptime T: type, comptime name: []const u8) type {
    return struct {
        pub fn read() T {
            return asm volatile ("MRS %[out], " ++ name
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
