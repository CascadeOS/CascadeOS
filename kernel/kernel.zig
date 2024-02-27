// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const core = @import("core");
const std = @import("std");

pub const acpi = @import("acpi.zig");
pub const arch = @import("arch/arch.zig");
pub const boot = @import("boot/boot.zig");
pub const debug = @import("debug/debug.zig");
pub const heap = @import("heap/heap.zig");
pub const info = @import("info.zig");
pub const init = @import("init.zig");
pub const memory = @import("memory/memory.zig");
pub const Processor = @import("Processor.zig");
pub const scheduler = @import("scheduler/scheduler.zig");
pub const SpinLock = @import("SpinLock.zig");
pub const Stack = @import("Stack.zig");
pub const time = @import("time.zig");

/// Returns the virtual address corresponding to this physical address in the direct map.
pub inline fn physicalToDirectMap(self: core.PhysicalAddress) core.VirtualAddress {
    return .{ .value = self.value + info.direct_map.address.value };
}

/// Returns the virtual address corresponding to this physical address in the non-cached direct map.
pub inline fn physicalToNonCachedDirectMap(self: core.PhysicalAddress) core.VirtualAddress {
    return .{ .value = self.value + info.non_cached_direct_map.address.value };
}

/// Returns the physical address of the given virtual address if it is in one of the direct maps.
pub fn directMapToPhysical(self: core.VirtualAddress) error{AddressNotInAnyDirectMap}!core.PhysicalAddress {
    if (info.direct_map.contains(self)) {
        return .{ .value = self.value -% info.direct_map.address.value };
    }
    if (info.non_cached_direct_map.contains(self)) {
        return .{ .value = self.value -% info.non_cached_direct_map.address.value };
    }
    return error.AddressNotInAnyDirectMap;
}

/// Returns the physical address of the given direct map virtual address.
///
/// It is the caller's responsibility to ensure that the given virtual address is in the direct map.
pub fn unsafeDirectMapToPhysical(self: core.VirtualAddress) core.PhysicalAddress {
    return .{ .value = self.value -% info.direct_map.address.value };
}

/// Returns a virtual range corresponding to this physical range in the direct map.
pub inline fn physicalRangeToDirectMap(self: core.PhysicalRange) core.VirtualRange {
    return .{
        .address = physicalToDirectMap(self.address),
        .size = self.size,
    };
}

pub var kernel_process: scheduler.Process = .{
    .id = .kernel,
    ._name = scheduler.Process.Name.fromSlice("kernel") catch unreachable,
    .page_table = undefined, // initialized in `initVirtualMemory`
};

comptime {
    // make sure any bootloader specific code that needs to be referenced is
    _ = &boot;

    // ensure any architecture specific code that needs to be referenced is
    _ = &arch;
}

pub const std_options: std.Options = .{
    // ensure using `std.log` in the kernel is a compile error
    .log_level = undefined,

    // ensure using `std.log` in the kernel is a compile error
    .logFn = struct {
        fn logFn(comptime _: std.log.Level, comptime _: @TypeOf(.enum_literal), comptime _: []const u8, _: anytype) void {
            @compileError("use `kernel.log` for logging in the kernel");
        }
    }.logFn,
};

pub const panic = debug.panic;
