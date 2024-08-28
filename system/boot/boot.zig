// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

/// Exports bootloader entry points.
///
/// Required to be called at comptime from the kernels root file 'system/root.zig'.
pub fn exportEntryPoints() void {
    comptime {
        // export a fallback entry point for unknown bootloaders
        @export(&arch.init.unknownBootloaderEntryPoint, .{ .name = "_start" });

        // ensure the limine requests are exported
        _ = &limine_requests;
    }
}

pub const KernelBaseAddress = struct {
    virtual: core.VirtualAddress,
    physical: core.PhysicalAddress,
};

/// Returns the kernel virtual and physical base addresses provided by the bootloader, if any.
pub fn kernelBaseAddress() ?KernelBaseAddress {
    switch (bootloader_api) {
        .limine => {
            if (limine_requests.kernel_address.response) |resp| {
                return .{
                    .virtual = resp.virtual_base,
                    .physical = resp.physical_base,
                };
            }
            return null;
        },
        .unknown => return null,
    }
}

fn limineEntryPoint() callconv(.C) noreturn {
    bootloader_api = .limine;
    @call(.never_inline, @import("root").initEntryPoint, .{}) catch |err| {
        core.panicFmt("unhandled error: {s}", .{@errorName(err)}, @errorReturnTrace());
    };
    core.panic("`init.initStage1` returned", null);
}

const limine_requests = struct {
    export var limine_revison: limine.BaseRevison = .{ .revison = 2 };
    export var entry_point: limine.EntryPoint = .{ .entry = limineEntryPoint };
    export var kernel_address: limine.KernelAddress = .{};
};

var bootloader_api: BootloaderAPI = .unknown;

const BootloaderAPI = enum {
    unknown,
    limine,
};

const std = @import("std");
const core = @import("core");
const limine = @import("limine");
const arch = @import("arch");
