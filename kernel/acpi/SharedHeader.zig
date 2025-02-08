// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>

/// All system description tables begin with this structure.
///
/// [ACPI 6.5 Specification Link](https://uefi.org/specs/ACPI/6.5/05_ACPI_Software_Programming_Model.html#system-description-table-header)
pub const SharedHeader = extern struct {
    /// The ASCII string representation of the table identifier.
    ///
    /// Note that if OSPM finds a signature in a table that is not listed in the ACPI specification,
    /// then OSPM ignores the entire table (it is not loaded into ACPI namespace);
    /// OSPM ignores the table even though the values in the Length and Checksum fields are correct.
    signature: [4]u8 align(1),

    /// The length of the table, in bytes, including the header, starting from offset 0.
    ///
    /// This field is used to record the size of the entire table.
    length: u32 align(1),

    /// The revision of the structure corresponding to the signature field for this table.
    ///
    /// Larger revision numbers are backward compatible to lower revision numbers with the same signature.
    revision: u8,

    /// The entire table, including the checksum field, must add to zero to be considered valid.
    checksum: u8,

    /// An OEM-supplied string that identifies the OEM.
    oem_id: [6]u8 align(1),

    /// An OEM-supplied string that the OEM uses to identify the particular data table.
    ///
    /// This field is particularly useful when defining a definition block to distinguish definition block functions.
    ///
    /// The OEM assigns each dissimilar table a new OEM Table ID.
    oem_table_id: [8]u8 align(1),

    /// An OEM-supplied revision number.
    ///
    /// Larger numbers are assumed to be newer revisions.
    oem_revision: u32 align(1),

    /// Vendor ID of utility that created the table.
    ///
    /// For tables containing Definition Blocks, this is the ID for the ASL Compiler.
    creator_id: u32 align(1),

    /// Revision of utility that created the table.
    ///
    /// For tables containing Definition Blocks, this is the revision for the ASL Compiler.
    creator_revision: u32 align(1),

    pub fn signatureIs(self: *const SharedHeader, signature: *const [4]u8) bool {
        return std.mem.eql(u8, signature, &self.signature);
    }

    pub fn signatureAsString(self: *const SharedHeader) []const u8 {
        return std.mem.asBytes(&self.signature);
    }

    /// Returns `true` is the table is valid.
    pub fn isValid(self: *const SharedHeader) bool {
        const bytes = blk: {
            const ptr: [*]const u8 = @ptrCast(self);
            break :blk ptr[0..self.length];
        };

        var lowest_byte_of_sum: u8 = 0;
        for (bytes) |b| lowest_byte_of_sum +%= b;

        // the sum of all bytes must have zero in the lowest byte
        return lowest_byte_of_sum == 0;
    }

    comptime {
        core.testing.expectSize(@This(), @sizeOf(u8) * 4 + @sizeOf(u32) + @sizeOf(u8) * 16 + @sizeOf(u32) * 3);
    }
};

comptime {
    std.testing.refAllDeclsRecursive(@This());
}

const core = @import("core");
const std = @import("std");
