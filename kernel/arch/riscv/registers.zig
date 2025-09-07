// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const core = @import("core");

/// Supervisor Scratch Register (sscratch)
pub const SupervisorScratch = CSR("sscratch");

/// Supervisor Status Register (sstatus)
pub const SupervisorStatus = packed struct(u64) {
    _reserved1: u1,
    sie: bool,
    _reserved2: u3,
    spie: u1,
    ube: u1,
    _reserved3: u1,
    spp: u1,
    vs_0_1: u2,
    _reserved4: u2,
    fs_0_1: u2,
    xs_0_1: u2,
    _reserved5: u1,
    sum: u1,
    mxr: u1,
    _reserved6: u3,
    spelp: u1,
    sdt: u1,
    _reserved7: u7,
    uxl_0_1: u2,
    _reserved8: u29,
    sd: u1,

    pub inline fn read() SupervisorStatus {
        return @bitCast(csr.read());
    }

    pub inline fn write(supervisor_status: SupervisorStatus) void {
        csr.write(@bitCast(supervisor_status));
    }

    pub const csr = CSR("sstatus");
};

pub fn CSR(comptime name: []const u8) type {
    return struct {
        pub inline fn read() u64 {
            return asm ("csrr %[out], " ++ name
                : [out] "=r" (-> u64),
            );
        }

        pub inline fn write(val: u64) void {
            asm volatile ("csrw " ++ name ++ ", %[in]"
                :
                : [in] "r" (val),
            );
        }

        pub inline fn clearBits(mask: u64) void {
            asm volatile ("csrc " ++ name ++ ", %[in]"
                :
                : [in] "r" (mask),
            );
        }

        pub inline fn setBits(mask: u64) void {
            asm volatile ("csrrs zero, " ++ name ++ ", %[in]"
                :
                : [in] "r" (mask),
            );
        }

        pub inline fn clearBitsImmediate(comptime immediate: u4) void {
            const immediate_str = comptime std.fmt.comptimePrint("{d}", .{immediate});
            asm volatile ("csrci " ++ name ++ ", " ++ immediate_str);
        }

        pub inline fn setBitsImmediate(comptime immediate: u4) void {
            const immediate_str = comptime std.fmt.comptimePrint("{d}", .{immediate});
            asm volatile ("csrsi " ++ name ++ ", " ++ immediate_str);
        }
    };
}
