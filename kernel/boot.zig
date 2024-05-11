// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const limine = @import("limine");

export fn _start() callconv(.C) noreturn {
    @call(.never_inline, @import("init.zig").earlyInit, .{}) catch |err| {
        core.panicFmt("unhandled error: {s}", .{@errorName(err)});
    };
    core.panic("`init.earlyInit` returned");
}

pub const KernelBaseAddress = struct {
    virtual: core.VirtualAddress,
    physical: core.PhysicalAddress,
};

/// Returns the kernel virtual and physical base addresses provided by the bootloader, if any.
pub fn kernelBaseAddress() ?KernelBaseAddress {
    if (limine_requests.kernel_address.response) |resp| {
        return .{
            .virtual = resp.virtual_base,
            .physical = resp.physical_base,
        };
    }
    return null;
}

const limine_requests = struct {
    export var limine_revison: limine.BaseRevison = .{ .revison = 1 };
    export var kernel_address: limine.KernelAddress = .{};
};

comptime {
    _ = &limine_requests;
}
