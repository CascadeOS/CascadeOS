// SPDX-License-Identifier: MIT

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");

const log = kernel.debug.log.scoped(.acpi);
const RSDP = @import("RSDP.zig").RSDP;

pub const Address = @import("Address.zig").Address;
pub const FADT = @import("FADT.zig").FADT;
pub const SharedHeader = @import("SharedHeader.zig").SharedHeader;

/// Initialized during `initializeACPITables`.
var sdt_header: *const SharedHeader = undefined;

/// Get the ACPI table if present.
///
/// Uses the `SIGNATURE_STRING: *const [4]u8` decl on the given `T` to find the table.
pub fn getTable(comptime T: type) ?*const T {
    var iter = tableIterator();

    while (iter.next()) |table| {
        if (table.signatureIs(T.SIGNATURE_STRING)) return @ptrCast(table);
    }

    return null;
}

pub fn tableIterator() TableIterator {
    const sdt_ptr: [*]const u8 = @ptrCast(sdt_header);

    return .{
        .ptr = sdt_ptr + @sizeOf(SharedHeader),
        .end_ptr = sdt_ptr + sdt_header.length,
        .is_xsdt = sdt_header.signatureIs("XSDT"),
    };
}

pub const TableIterator = struct {
    ptr: [*]const u8,
    end_ptr: [*]const u8,

    is_xsdt: bool,

    pub fn next(self: *TableIterator) ?*const SharedHeader {
        if (self.is_xsdt) return self.nextImpl(u64);
        return self.nextImpl(u32);
    }

    fn nextImpl(self: *TableIterator, comptime T: type) ?*const SharedHeader {
        if (@intFromPtr(self.ptr) + @sizeOf(T) >= @intFromPtr(self.end_ptr)) return null;

        const physical_address = kernel.PhysicalAddress.fromInt(
            std.mem.readInt(T, @ptrCast(self.ptr), .little), // TODO: is little endian correct?
        );

        self.ptr += @sizeOf(T);

        return physical_address.toDirectMap().toPtr(*const SharedHeader);
    }
};

pub const init = struct {
    /// Initializes access to the ACPI tables.
    pub fn initializeACPITables() linksection(kernel.info.init_code) void {
        const rsdp_address = kernel.boot.rsdp() orelse core.panic("RSDP not provided by bootloader");
        const rsdp = rsdp_address.toPtr(*const RSDP);

        log.debug("ACPI revision: {d}", .{rsdp.revision});

        log.debug("validating rsdp", .{});
        rsdp.validate();

        const sdt_physical_address = kernel.PhysicalAddress.fromInt(
            switch (rsdp.revision) {
                0 => rsdp.rsdt_addr,
                2 => rsdp.xsdt_addr,
                else => core.panicFmt("unknown ACPI revision: {d}", .{rsdp.revision}),
            },
        );

        sdt_header = sdt_physical_address.toDirectMap().toPtr(*const SharedHeader);

        log.debug("validating sdt", .{});
        sdt_header.validate();
    }
};
