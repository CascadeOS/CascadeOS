// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

pub fn kernelBaseAddress() ?boot.KernelBaseAddress {
    const resp = requests.kernel_address.response orelse
        return null;

    return .{
        .virtual = resp.virtual_base,
        .physical = resp.physical_base,
    };
}

fn limineEntryPoint() callconv(.C) noreturn {
    kernel.boot.bootloader_api = .limine;

    if (requests.limine_base_revison.revison == .@"0") {
        // limine sets the `revison` field to `0` to signal that the requested revision is supported
        limine_revison = target_limine_revison;
    }

    @call(.never_inline, kernel.init.initStage1, .{}) catch |err| {
        core.panicFmt("unhandled error: {s}", .{@errorName(err)}, @errorReturnTrace());
    };
    core.panic("`initStage1` returned", null);
}

// TODO: update to 3, needs annoying changes as things like the ACPI RSDP are not mapped in the
//       HHDM from that revision onwards
const target_limine_revison: limine.BaseRevison.Revison = .@"2";
var limine_revison: limine.BaseRevison.Revison = .@"0";

pub fn exportRequests() void {
    @export(&requests.limine_base_revison, .{ .name = "limine_base_revison_request" });
    @export(&requests.entry_point, .{ .name = "limine_entry_point_request" });
    @export(&requests.kernel_address, .{ .name = "limine_kernel_address_request" });
    @export(&requests.memmap, .{ .name = "limine_memmap_request" });
    @export(&requests.hhdm, .{ .name = "limine_hhdm_request" });
}

const requests = struct {
    var limine_base_revison: limine.BaseRevison = .{ .revison = target_limine_revison };
    var entry_point: limine.EntryPoint = .{ .entry = limineEntryPoint };
    var kernel_address: limine.ExecutableAddress = .{};
};

const std = @import("std");
const core = @import("core");
const limine = @import("limine");
const kernel = @import("../kernel.zig");
const boot = @import("boot.zig");
