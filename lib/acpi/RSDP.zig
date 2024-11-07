// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

/// [ACPI 6.5 Specification Link](https://uefi.org/specs/ACPI/6.5/05_ACPI_Software_Programming_Model.html#root-system-description-pointer-rsdp-structure)
pub const RSDP = extern struct {
    /// "RSD PTR "
    signature: [8]u8 align(1),

    /// This is the checksum of the fields defined in the ACPI 1.0 specification.
    ///
    /// This includes only the first 20 bytes of this table, bytes 0 to 19, including the checksum field.
    ///
    /// These bytes must sum to zero.
    checksum: u8 align(1),

    /// An OEM-supplied string that identifies the OEM
    oem_id: [6]u8 align(1),

    /// The revision of this structure.
    ///
    /// Larger revision numbers are backward compatible to lower revision numbers.
    ///
    /// The ACPI version 1.0 revision number of this table is zero.
    ///
    /// The ACPI version 1.0 RSDP Structure only includes the first 20 bytes of this table, bytes 0 to 19.
    /// It does not include the Length field and beyond.
    ///
    /// The current value for this field is 2.
    revision: u8 align(1),

    /// 32 bit physical address of the RSDT.
    rsdt_addr: u32 align(1),

    /// The length of the table, in bytes, including the header, starting from offset 0.
    ///
    /// This field is used to record the size of the entire table.
    ///
    /// This field is not available in the ACPI version 1.0 RSDP Structure.
    length: u32 align(1),

    /// 64 bit physical address of the XSDT.
    ///
    /// This field is not available in the ACPI version 1.0 RSDP Structure.
    xsdt_addr: core.PhysicalAddress align(1),

    /// This is a checksum of the entire table, including both checksum fields.
    ///
    /// This field is not available in the ACPI version 1.0 RSDP Structure.
    extended_checksum: u8 align(1),

    _reserved: [3]u8 align(1),

    const BYTES_IN_ACPI_1_STRUCTURE = 20;

    pub fn sdtAddress(self: *const RSDP) core.PhysicalAddress {
        return switch (self.revision) {
            0 => core.PhysicalAddress.fromInt(self.rsdt_addr),
            2 => self.xsdt_addr,
            else => core.panicFmt("unknown ACPI revision: {d}", .{self.revision}, null),
        };
    }

    /// Returns `true` is the table is valid.
    pub fn isValid(self: *const RSDP) bool {
        // Before the RSDP is relied upon you should check that the checksum is valid.
        // For ACPI 1.0 you add up every byte in the structure and make sure the lowest byte of the result is equal
        // to zero.
        // For ACPI 2.0 and later you'd do exactly the same thing for the original (ACPI 1.0) part of the
        // structure, and then do it again for the fields that are part of the ACPI 2.0 extension.

        const bytes = blk: {
            const ptr: [*]const u8 = @ptrCast(self);
            const length_of_table = switch (self.revision) {
                0 => BYTES_IN_ACPI_1_STRUCTURE,
                2 => self.length,
                else => return false,
            };
            break :blk ptr[0..length_of_table];
        };

        var lowest_byte_of_sum: u8 = 0;
        for (bytes) |b| lowest_byte_of_sum +%= b;

        // the sum of all bytes must have zero in the lowest byte
        return lowest_byte_of_sum == 0;
    }

    comptime {
        core.testing.expectSize(@This(), @sizeOf(u8) * 16 + @sizeOf(u32) * 2 + @sizeOf(u64) + @sizeOf(u8) * 4);
    }
};

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

const std = @import("std");
const core = @import("core");

const acpi = @import("acpi");
