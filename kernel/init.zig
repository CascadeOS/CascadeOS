// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const log = kernel.log.scoped(.init);

/// Entry point from bootloader specific code.
///
/// Only the bootstrap cpu executes this function.
pub fn earlyInit() !void {
    // get output up and running as soon as possible
    kernel.arch.init.setupEarlyOutput();

    // now that early output is ready, we can switch to the init panic
    kernel.debug.init.loadInitPanic();

    if (kernel.arch.init.getEarlyOutput()) |early_output| {
        early_output.writeAll(comptime "starting CascadeOS " ++ kernel.config.cascade_version ++ "\n") catch {};
    }

    log.debug("capturing kernel offsets", .{});
    try captureKernelOffsets();
}

fn captureKernelOffsets() !void {
    const kernel_base_address = kernel.boot.kernelBaseAddress() orelse return error.KernelBaseAddressNotProvided;

    const kernel_virtual = kernel_base_address.virtual;
    const kernel_physical = kernel_base_address.physical;

    kernel.info.kernel_virtual_base_address = kernel_virtual;
    log.debug("kernel virtual base address: {}", .{kernel.info.kernel_virtual_base_address});
    log.debug("kernel physical base address: {}", .{kernel_physical});

    kernel.info.kernel_virtual_offset = core.Size.from(kernel_virtual.value - kernel.config.kernel_base_address.value, .byte);
    kernel.info.kernel_physical_to_virtual_offset = core.Size.from(kernel_virtual.value - kernel_physical.value, .byte);
    log.debug("kernel virtual offset: 0x{x}", .{kernel.info.kernel_virtual_offset.?.value});
    log.debug("kernel physical to virtual offset: 0x{x}", .{kernel.info.kernel_physical_to_virtual_offset.value});
}
