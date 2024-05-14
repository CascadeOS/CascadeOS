// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

//! Runtime discovered/calculated values.

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

/// The virtual base address that the kernel was loaded at.
///
/// Initialized during `init.captureKernelOffsets.
pub var kernel_virtual_base_address: core.VirtualAddress = undefined;

/// The offset from the requested ELF virtual base address to the address that the kernel was actually loaded at.
///
/// Initialized during `init.captureKernelOffsets`.
pub var kernel_virtual_offset: ?core.Size = null;

/// Offset from the virtual address of kernel sections to the physical address of the section.
///
/// Initialized during `init.captureKernelOffsets`.
pub var kernel_physical_to_virtual_offset: core.Size = undefined;

/// This direct map provides an identity mapping between virtual and physical addresses.
///
/// Initialized during `init.captureBootloaderDirectMap`.
pub var direct_map: core.VirtualRange = undefined;

pub fn sdfSlice() []const u8 {
    const static = struct {
        const sdf = @import("sdf");

        var opt_sdf_slice: ?[]const u8 = null;
        extern const __sdf_start: u8;
    };

    if (static.opt_sdf_slice) |s| return s;

    const ptr: [*]const u8 = @ptrCast(&static.__sdf_start);
    var fbs = std.io.fixedBufferStream(ptr[0..@sizeOf(static.sdf.Header)]);

    const header = static.sdf.Header.read(fbs.reader()) catch core.panic("SDF data is invalid");

    const slice = ptr[0..header.total_size_of_sdf_data];

    static.opt_sdf_slice = slice;
    return slice;
}
