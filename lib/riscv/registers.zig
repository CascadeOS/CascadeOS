// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const core = @import("core");
const std = @import("std");

const riscv = @import("riscv");

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

    pub fn read() SupervisorStatus {
        return @bitCast(csr.read());
    }

    pub fn write(self: SupervisorStatus) void {
        csr.write(@bitCast(self));
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

comptime {
    refAllDeclsRecursive(@This());
}

// Copy of `std.testing.refAllDeclsRecursive`, being in the file give access to private decls.
fn refAllDeclsRecursive(comptime T: type) void {
    if (!@import("builtin").is_test) return;

    inline for (switch (@typeInfo(T)) {
        .Struct => |info| info.decls,
        .Enum => |info| info.decls,
        .Union => |info| info.decls,
        .Opaque => |info| info.decls,
        else => @compileError("Expected struct, enum, union, or opaque type, found '" ++ @typeName(T) ++ "'"),
    }) |decl| {
        if (@TypeOf(@field(T, decl.name)) == type) {
            switch (@typeInfo(@field(T, decl.name))) {
                .Struct, .Enum, .Union, .Opaque => refAllDeclsRecursive(@field(T, decl.name)),
                else => {},
            }
        }
        _ = &@field(T, decl.name);
    }
}
