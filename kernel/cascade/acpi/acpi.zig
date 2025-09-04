// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub fn tryShutdown(context: *cascade.Context) !void {
    if (!globals.acpi_initialized) return;

    try uacpi.prepareForSleep(.S5);

    context.incrementInterruptDisable();
    defer context.decrementInterruptDisable();

    try uacpi.sleep(.S5);
}

pub const Address = @import("Address.zig").Address;
pub const tables = @import("tables/tables.zig");
pub const uacpi = @import("uacpi.zig");

pub const globals = struct {
    /// Pointer to the RSDP table.
    ///
    /// Set by `init.acpi.earlyInitialize`.
    pub var rsdp: *const tables.RSDP = undefined;

    /// Set by `init.acpi.initialize`.
    pub var acpi_initialized: bool = false;
};

pub fn earlyPowerButtonHandler(_: ?*void) uacpi.InterruptReturn {
    const context: *cascade.Context = .current();
    log.warn(context, "power button pressed", .{});
    tryShutdown(context) catch |err| {
        std.debug.panic("failed to shutdown: {t}", .{err});
    };
    @panic("shutdown failed");
}

comptime {
    _ = @import("uacpi_kernel_api.zig"); // ensure kernel api is exported
}

const arch = @import("arch");
const cascade = @import("cascade");

const core = @import("core");
const log = cascade.debug.log.scoped(.acpi);
const std = @import("std");
