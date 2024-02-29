// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const builtin = @import("builtin");
const core = @import("core");
const kernel = @import("kernel");
const kernel_options = @import("kernel_options");
const std = @import("std");
const target_options = @import("cascade_target");

pub const mode: std.builtin.OptimizeMode = builtin.mode;
pub const arch = target_options.arch;
pub const version = kernel_options.cascade_version;
pub const root_path = kernel_options.root_path;

// This must be kept in sync with the linker scripts.
pub const kernel_base_address = core.VirtualAddress.fromInt(0xffffffff80000000);

/// Initialized during `initKernelStage1`.
pub var kernel_virtual_base_address: core.VirtualAddress = undefined;

/// Initialized during `initKernelStage1`.
pub var kernel_physical_base_address: core.PhysicalAddress = undefined;

/// Initialized during `initKernelStage1`.
pub var kernel_virtual_slide: ?core.Size = null;

/// Initialized during `initKernelStage1`.
pub var kernel_physical_to_virtual_offset: core.Size = undefined;

/// This direct map provides an identity mapping between virtual and physical addresses.
///
/// Initialized during `initKernelStage1`.
pub var direct_map: core.VirtualRange = undefined;

/// This direct map provides an identity mapping between virtual and physical addresses.
///
/// The page tables used disable caching for this range.
///
/// Initialized during `initKernelStage1`.
pub var non_cached_direct_map: core.VirtualRange = undefined;

/// This is the kernel's ELF file.
///
/// Initialized during `initKernelStage1`.
pub var kernel_file: ?core.VirtualRange = null;

/// The hypervisor we are running on or null if we are not running on a hypervisor.
pub var hypervisor: ?Hypervisor = null;

pub const Hypervisor = enum {
    kvm,
    tcg,
    hyperv,
    vmware,
    unknown,
};

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
