// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const kernel = @import("kernel");
const Task = kernel.Task;
const core = @import("core");

const x64 = @import("../x64.zig");

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

    pub fn print(page_fault_error_code: PageFaultErrorCode, writer: *std.Io.Writer, indent: usize) !void {
        _ = indent;

        try writer.writeAll("PageFaultErrorCode{ ");

        if (!page_fault_error_code.present) {
            try writer.writeAll("Not Present }");
            return;
        }

        if (page_fault_error_code.user) {
            try writer.writeAll("User - ");
        } else {
            try writer.writeAll("Kernel - ");
        }

        if (page_fault_error_code.write) {
            try writer.writeAll("Write");
        } else {
            try writer.writeAll("Read");
        }

        if (page_fault_error_code.reserved_write) {
            try writer.writeAll("- Reserved Bit Set");
        }

        if (page_fault_error_code.instruction_fetch) {
            try writer.writeAll("- No Execute");
        }

        if (page_fault_error_code.instruction_fetch) {
            try writer.writeAll("- Protection Key");
        }

        if (page_fault_error_code.instruction_fetch) {
            try writer.writeAll("- Shadow Stack");
        }

        if (page_fault_error_code.hlat) {
            try writer.writeAll("- Hypervisor Linear Address Translation");
        }

        if (page_fault_error_code.instruction_fetch) {
            try writer.writeAll("- Software Guard Extension");
        }

        try writer.writeAll(" }");
    }

    pub inline fn format(page_fault_error_code: PageFaultErrorCode, writer: *std.Io.Writer) !void {
        return page_fault_error_code.print(writer, 0);
    }
};
