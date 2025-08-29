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
    /// Set by `setRsdp`, only valid if `acpi_present` is true.
    pub var rsdp: *const tables.RSDP = undefined;

    /// If this is true, then ACPI is present and the RSDP pointer is valid.
    var acpi_present: bool = false;

    var acpi_initialized: bool = false;
};

pub const init = struct {
    pub fn setRsdp(rsdp: *const tables.RSDP) void {
        globals.rsdp = rsdp;
        globals.acpi_present = true;
    }

    pub fn initialize(context: *cascade.Context) !void {
        init_log.debug(context, "entering ACPI mode", .{});
        try uacpi.initialize(.{});

        try uacpi.FixedEvent.power_button.installHandler(
            void,
            earlyPowerButtonHandler,
            null,
        );

        init_log.debug(context, "loading namespace", .{});
        try uacpi.namespaceLoad();

        if (arch.current_arch == .x64) {
            try uacpi.setInterruptModel(.ioapic);
        }

        init_log.debug(context, "initializing namespace", .{});
        try uacpi.namespaceInitialize();

        init_log.debug(context, "finializing GPEs", .{});
        try uacpi.finializeGpeInitialization();

        globals.acpi_initialized = true;
    }

    fn earlyPowerButtonHandler(_: ?*void) uacpi.InterruptReturn {
        const context: *cascade.Context = .current();
        init_log.warn(context, "power button pressed", .{});
        tryShutdown(context) catch |err| {
            std.debug.panic("failed to shutdown: {t}", .{err});
        };
        @panic("shutdown failed");
    }

    const init_log = cascade.debug.log.scoped(.init_acpi);
};

comptime {
    _ = @import("uacpi_kernel_api.zig"); // ensure kernel api is exported
}

const arch = @import("arch");
const cascade = @import("cascade");

const core = @import("core");
const log = cascade.debug.log.scoped(.acpi);
const std = @import("std");
