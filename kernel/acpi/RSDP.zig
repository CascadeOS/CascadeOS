// SPDX-License-Identifier: MIT

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");

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
    xsdt_addr: u64 align(1),

    /// This is a checksum of the entire table, including both checksum fields.
    extended_checksum: u8 align(1),

    _reserved: [3]u8 align(1),

    const BYTES_IN_ACPI_1_STRUCTURE = 20;

    /// Validates the table.
    ///
    /// Panics if the table is invalid.
    pub fn validate(self: *const RSDP) void {
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
                else => unreachable,
            };
            break :blk ptr[0..length_of_table];
        };

        const sum_of_bytes = blk: {
            var value: usize = 0;
            for (bytes) |b| value += b;
            break :blk value;
        };

        // the sum of all bytes must have zero in the lowest byte
        if (sum_of_bytes & 0xFF != 0) core.panic("RSDP validation failed");
    }

    comptime {
        core.testing.expectSize(@This(), @sizeOf(u8) * 16 + @sizeOf(u32) * 2 + @sizeOf(u64) + @sizeOf(u8) * 4);
    }
};
