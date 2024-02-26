// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");

pub const Address = @import("Address.zig").Address;
pub const FADT = @import("FADT.zig").FADT;
pub const HPET = @import("HPET.zig").HPET;
pub const MADT = @import("MADT.zig").MADT;
pub const MCFG = @import("MCFG.zig").MCFG;
pub const RSDP = @import("RSDP.zig").RSDP;
pub const SharedHeader = @import("SharedHeader.zig").SharedHeader;

/// Creates an iterator over the tables in the System Description Table.
///
/// Supports both XSDT and RSDT.
pub fn tableIterator(sdt_header: *const SharedHeader) TableIterator {
    const sdt_ptr: [*]const u8 = @ptrCast(sdt_header);

    const is_xsdt = sdt_header.signatureIs("XSDT");
    core.assert(is_xsdt or sdt_header.signatureIs("RSDT")); // Invalid SDT signature.

    return .{
        .ptr = sdt_ptr + @sizeOf(SharedHeader),
        .end_ptr = sdt_ptr + sdt_header.length,
        .is_xsdt = is_xsdt,
    };
}

pub const TableIterator = struct {
    ptr: [*]const u8,
    end_ptr: [*]const u8,

    is_xsdt: bool,

    /// Returns the physical address of header of the next table in the System Description Table.
    ///
    /// No validation of the table is performed.
    pub fn next(self: *TableIterator) ?u64 {
        if (self.is_xsdt) return self.nextImpl(u64);
        return self.nextImpl(u32);
    }

    fn nextImpl(self: *TableIterator, comptime T: type) ?u64 {
        if (@intFromPtr(self.ptr) + @sizeOf(T) >= @intFromPtr(self.end_ptr)) return null;

        const physical_address = std.mem.readInt(T, @ptrCast(self.ptr), .little);

        self.ptr += @sizeOf(T);

        return physical_address;
    }
};

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
