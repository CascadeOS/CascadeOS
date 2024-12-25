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

pub fn memoryMap(direction: core.Direction) ?boot.MemoryMap {
    const resp = requests.memmap.response orelse
        return null;

    var result: boot.MemoryMap = .{
        .backing = undefined,
    };

    const limine_memory_map = std.mem.bytesAsValue(MemoryMapIterator, &result.backing);

    const entries = resp.entries();

    limine_memory_map.* = .{
        .index = switch (direction) {
            .forward => 0,
            .backward => entries.len,
        },
        .entries = entries,
        .direction = direction,
    };

    return result;
}

pub const MemoryMapIterator = struct {
    index: usize,
    entries: []const *const limine.Memmap.Entry,
    direction: core.Direction,

    pub fn next(memory_map: *boot.MemoryMap) ?boot.MemoryMap.Entry {
        const self: *MemoryMapIterator = @ptrCast(@alignCast(&memory_map.backing));

        const limine_entry = switch (self.direction) {
            .backward => blk: {
                if (self.index == 0) return null;
                self.index -= 1;
                break :blk self.entries[self.index];
            },
            .forward => blk: {
                if (self.index >= self.entries.len) return null;
                const entry = self.entries[self.index];
                self.index += 1;
                break :blk entry;
            },
        };

        return .{
            .range = .fromAddr(limine_entry.base, limine_entry.length),
            .type = switch (limine_entry.type) {
                .usable => .free,
                .executable_and_modules, .framebuffer => .in_use,
                .reserved, .acpi_nvs => .reserved,
                .bootloader_reclaimable => .bootloader_reclaimable,
                .acpi_reclaimable => .acpi_reclaimable,
                .bad_memory => .unusable,
                else => .unknown,
            },
        };
    }
};

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
    var memmap: limine.Memmap = .{};
};

const std = @import("std");
const core = @import("core");
const limine = @import("limine");
const kernel = @import("../kernel.zig");
const boot = @import("boot.zig");
