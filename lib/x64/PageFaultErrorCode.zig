// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");

pub const PageFaultErrorCode = packed struct(u64) {
    /// When set, the page fault was caused by a page-protection violation.
    ///
    /// When not set, it was caused by a non-present page.
    present: bool,

    /// When set, the page fault was caused by a write access.
    ///
    /// When not set, it was caused by a read access.
    write: bool,

    /// When set, the page fault was caused while CPL = 3.
    user: bool,

    /// When set, one or more page directory entries contain reserved bits which are set to 1.
    ///
    /// This only applies when the PSE or PAE flags in CR4 are set to 1.
    reserved_write: bool,

    /// When set, the page fault was caused by an instruction fetch.
    ///
    /// This only applies when the No-Execute bit is supported and enabled.
    instruction_fetch: bool,

    /// When set, the page fault was caused by a protection-key violation.
    ///
    /// The PKRU register (for user-mode accesses) or PKRS MSR (for supervisor-mode accesses) specifies the protection
    /// key rights.
    protection_key: bool,

    /// When set, the page fault was caused by a shadow stack access.
    shadow_stack: bool,

    /// When set there is no translation for the linear address using HLAT paging.
    hlat: bool,

    _reserved1: u7,

    /// When set, the fault was due to an SGX violation.
    software_guard_exception: bool,

    _reserved2: u48,

    pub inline fn fromErrorCode(error_code: u64) PageFaultErrorCode {
        return @bitCast(error_code);
    }

    pub fn print(self: PageFaultErrorCode, writer: std.io.AnyWriter, indent: usize) !void {
        _ = indent;

        try writer.writeAll("PageFaultErrorCode{ ");

        if (!self.present) {
            try writer.writeAll("Not Present }");
            return;
        }

        if (self.user) {
            try writer.writeAll("User - ");
        } else {
            try writer.writeAll("Kernel - ");
        }

        if (self.write) {
            try writer.writeAll("Write");
        } else {
            try writer.writeAll("Read");
        }

        if (self.reserved_write) {
            try writer.writeAll("- Reserved Bit Set");
        }

        if (self.instruction_fetch) {
            try writer.writeAll("- No Execute");
        }

        if (self.instruction_fetch) {
            try writer.writeAll("- Protection Key");
        }

        if (self.instruction_fetch) {
            try writer.writeAll("- Shadow Stack");
        }

        if (self.hlat) {
            try writer.writeAll("- Hypervisor Linear Address Translation");
        }

        if (self.instruction_fetch) {
            try writer.writeAll("- Software Guard Extension");
        }

        try writer.writeAll(" }");
    }

    pub inline fn format(
        self: PageFaultErrorCode,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        _ = fmt;
        return if (@TypeOf(writer) == std.io.AnyWriter)
            print(self, writer, 0)
        else
            print(self, writer.any(), 0);
    }

    fn __helpZls() void {
        PageFaultErrorCode.print(undefined, @as(std.fs.File.Writer, undefined), 0);
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
