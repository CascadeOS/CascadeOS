// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

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

comptime {
    refAllDeclsRecursive(@This());
}

// Copy of `std.testing.refAllDeclsRecursive`, being in the file give access to private decls.
fn refAllDeclsRecursive(comptime T: type) void {
    if (!@import("builtin").is_test) return;

    inline for (switch (@typeInfo(T)) {
        .@"struct" => |info| info.decls,
        .@"enum" => |info| info.decls,
        .@"union" => |info| info.decls,
        .@"opaque" => |info| info.decls,
        else => @compileError("Expected struct, enum, union, or opaque type, found '" ++ @typeName(T) ++ "'"),
    }) |decl| {
        if (@TypeOf(@field(T, decl.name)) == type) {
            switch (@typeInfo(@field(T, decl.name))) {
                .@"struct", .@"enum", .@"union", .@"opaque" => refAllDeclsRecursive(@field(T, decl.name)),
                else => {},
            }
        }
        _ = &@field(T, decl.name);
    }
}

const core = @import("core");
const std = @import("std");

const aarch64 = @import("aarch64");
