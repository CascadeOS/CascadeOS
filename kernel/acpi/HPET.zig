// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");

const acpi = @import("acpi.zig");

/// The HPET Description Table is a means to report the Base Addresses of each Event Timer Block early in the OS boot
/// process.
///
/// The table is needed to allow Operating Systems to discover event timers and establish basic timer services for
/// driver load.
///
/// [IA-PC HPET Specification Link](https://www.intel.com/content/dam/www/public/us/en/documents/technical-specifications/software-developers-hpet-spec-1-0a.pdf)
pub const HPET = extern struct {
    header: acpi.SharedHeader align(1),

    /// Hardware ID of Event Timer Block.
    ///
    /// This field provides a quick access for software which needs to know the HPET implementation.
    event_timer_block_id: EventTimerBlockId align(1),

    /// The lower 32-bit base address of Event Timer Block.
    ///
    /// Each Event Timer Block consumes 1K of system memory, regardless of how many comparators are actually
    /// implemented by the hardware.
    base_address: acpi.Address align(1),

    /// This one byte field indicates the HPET sequence number.
    ///
    /// 0 = 1st table, 1 = 2nd table and so forth.
    ///
    /// This field is written by BIOS at boot time and should not be altered by any other software.
    hpet_number: u8,

    /// The minimum clock ticks can be set without lost interrupts while the counter is programmed to operate in periodic mode.
    main_counter_minimum_clock_tick_in_periodic_mode: u16 align(1),

    page_protection_and_oem_attributes: PageProtectionAndOemAttributes align(1),

    pub const SIGNATURE_STRING = "HPET";

    pub const EventTimerBlockId = packed struct(u32) {
        hardware_revision_id: u8,

        number_of_comparators_in_1st_timer_block: u5,

        main_counter_is_64bits: bool,

        _reserved: u1,

        legacy_replacement_irq_rounting_capable: bool,

        pci_vendor_id_of_1st_timer_block: u16,
    };

    pub const PageProtectionAndOemAttributes = packed struct(u8) {
        protection: Protection,

        oem_attributes: u4,

        pub const Protection = enum(u4) {
            /// no guarantee for page protection
            none = 0,

            /// 4KB page protected, access to the adjacent 3KB space will not generate machine check or compromise
            /// the system security.
            @"4kb" = 1,

            /// 64KB page protected, access to the adjacent 63KB space will not generate machine check or compromise
            /// the system security.
            @"64kb" = 2,

            _,
        };
    };

    comptime {
        core.testing.expectSize(@This(), 56);
    }
};
