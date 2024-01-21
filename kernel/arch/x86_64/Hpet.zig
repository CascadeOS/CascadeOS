// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

// [IA-PC HPET Specification Link](https://www.intel.com/content/dam/www/public/us/en/documents/technical-specifications/software-developers-hpet-spec-1-0a.pdf)

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");

const log = kernel.debug.log.scoped(.hpet);

const HPET = @This();

// Initalized during `initializeHPET`
var base: [*]volatile u64 = undefined;

/// The duration of a tick in femptoseconds.
var tick_duration_fs: u64 = undefined; // Initalized during `initializeHPET`

// Initalized during `initializeHPET`
var number_of_timers_minus_one: u5 = undefined;

pub const init = struct {
    pub fn registerTimeSource() linksection(kernel.info.init_code) void {
        if (kernel.acpi.init.getTable(DescriptionTable) == null) return;

        kernel.time.init.addTimeSource(.{
            .name = "hpet",
            .priority = 100,
            .per_core = false,
            .initialization = .{ .simple = initializeHPET },
            .reference_counter = .{
                .prepareToWaitForFn = prepareToWaitFor,
                .waitForFn = waitFor,
            },
        });
    }

    fn initializeHPET() linksection(kernel.info.init_code) void {
        base = getHpetBase();
        log.debug("using base address: {*}", .{base});

        const general_capabilities = GeneralCapabilitiesAndIDRegister.read();

        if (general_capabilities.counter_is_64bit) {
            log.debug("counter is 64-bit", .{});
        } else {
            core.panic("HPET counter is not 64-bit");
        }

        number_of_timers_minus_one = general_capabilities.number_of_timers_minus_one;

        tick_duration_fs = general_capabilities.counter_tick_period_fs;
        log.debug("tick duration (fs): {}", .{tick_duration_fs});

        var general_configuration = GeneralConfigurationRegister.read();
        general_configuration.enable = false;
        general_configuration.legacy_routing_enable = false;
        general_configuration.write();

        CounterRegister.write(0);
    }

    fn prepareToWaitFor(duration: core.Duration) linksection(kernel.info.init_code) void {
        _ = duration;

        var general_configuration = GeneralConfigurationRegister.read();
        general_configuration.enable = false;
        general_configuration.write();

        CounterRegister.write(0);

        general_configuration.enable = true;
        general_configuration.write();
    }

    fn waitFor(duration: core.Duration) linksection(kernel.info.init_code) void {
        const current_value = CounterRegister.read();

        const target_value = current_value + ((duration.value * kernel.time.fs_per_ns) / tick_duration_fs);

        while (CounterRegister.read() < target_value) {
            kernel.arch.spinLoopHint();
        }
    }

    fn getHpetBase() linksection(kernel.info.init_code) [*]volatile u64 {
        const description_table = kernel.acpi.init.getTable(DescriptionTable) orelse unreachable;

        if (description_table.base_address.address_space != .memory) core.panic("HPET base address is not memory mapped");

        return kernel.PhysicalAddress
            .fromInt(description_table.base_address.address)
            .toNonCachedDirectMap()
            .toPtr([*]volatile u64);
    }
};

const DescriptionTable = extern struct {
    header: kernel.acpi.SharedHeader align(1),

    /// Hardware ID of Event Timer Block.
    ///
    /// This field provides a quick access for software which needs to know the HPET implementation.
    event_timer_block_id: EventTimerBlockId align(1),

    /// The lower 32-bit base address of Event Timer Block.
    ///
    /// Each Event Timer Block consumes 1K of system memory, regardless of how many comparators are actually
    /// implemented by the hardware.
    base_address: kernel.acpi.Address align(1),

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
        /// Describes the timer hardware capability to guarantee the page protection.
        ///
        /// This information is required for the OSes that want to expose this timer to the user space.
        protection: Protection,

        /// OEM attributes.
        ///
        /// OEM can use this field for its implementation specific attributes.
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

const GeneralCapabilitiesAndIDRegister = packed struct(u64) {
    /// This indicates which revision of the function is implemented.
    ///
    /// The value must NOT be 00h.
    revision: u8,

    /// This indicates the number of timers in this block minus one.
    ///
    /// The number in this field indicates the last timer (i.e. if there are three timers, the value will be 02h, four
    /// timers will be 03h, five timers will be 04h, etc.).
    number_of_timers_minus_one: u5,

    counter_is_64bit: bool,

    _reserved: u1,

    /// Indicates if the hardware supports the LegacyReplacement Interrupt Route option.
    legacy_replacement_route_capable: bool,

    /// The PCI vendor ID.
    vendor_id: u16, // TODO: PCI vendor id

    /// This read-only field indicates the period at which the counter increments in femptoseconds (10^-15 seconds).
    ///
    /// A value of 0 in this field is not permitted.
    ///
    /// The value in this field must be less than or equal to 05F5E100h (10^8 femptoseconds = 100 nanoseconds).
    ///
    /// The resolution must be in femptoseconds (rather than picoseconds) in order to achieve a resolution of 50 ppm.
    counter_tick_period_fs: u32,

    const offset = 0x0 / @sizeOf(u64);

    pub fn read() GeneralCapabilitiesAndIDRegister {
        return @bitCast(base[offset]);
    }
};

const GeneralConfigurationRegister = packed struct(u64) {
    /// Overall Enable: This bit must be set to enable any of the timers to generate interrupts.
    ///
    /// If this bit is `false`, then the main counter will halt (will not increment) and no interrupts will be caused by
    /// any of these timers.
    ///  - `false`: halt main counter and disable all timer interrupts
    ///  - `true`: allow main counter to run, and allow timer interrupts if enabled
    enable: bool,

    /// If `enable` and `legacy_routing_enable` are both `true`, then the interrupts will be routed as follows:
    ///  - Timer 0 will be routed to IRQ0 in Non-APIC or IRQ2 in the I/O APIC
    ///  - Timer 1 will be routed to IRQ8 in Non-APIC or IRQ8 in the I/O APIC
    ///  - Timer 2-n will be routed as per the routing in the timer n config registers.
    ///
    /// If `true`, the individual routing bits for timers 0 and 1 (APIC or FSB) will have no impact.
    ///
    /// If `false`, the individual routing bits for each of the timers are used.
    legacy_routing_enable: bool,

    _reserved: u62,

    const offset = 0x10 / @sizeOf(u64);

    pub fn read() GeneralConfigurationRegister {
        return @bitCast(base[offset]);
    }

    pub fn write(register: GeneralConfigurationRegister) void {
        base[offset] = @bitCast(register);
    }
};

const CounterRegister = struct {
    const offset = 0xF0 / @sizeOf(u64);

    pub inline fn read() u64 {
        return base[offset];
    }

    pub fn write(value: u64) void {
        core.debugAssert(!GeneralConfigurationRegister.read().enable); // counter must be disabled
        base[offset] = value;
    }
};

const timer_offset = 0x20 / @sizeOf(u64);

const TimerConfigurationAndCapabilitiesRegister = packed struct(u64) {
    _reserved1: u1,

    interrupt_type: InterruptType,

    /// Enables an interrupt when the timer event fires.
    ///
    /// Note: If this is `false`, the timer will still operate and generate appropriate status bits, but will not cause
    /// an interrupt.
    interrupt_enable: bool,

    /// If `periodic_capable` is `false`, then this will always be `.oneshot` when read and writes will have no impact.
    timer_type: TimerType,

    /// Indicates if the hardware supports a periodic mode for this timer’s interrupt.
    periodic_capable: bool,

    timer_is_64bit: bool,

    /// Only valid for timers that have been set to periodic mode.
    ///
    /// By writing `true`, the software is then allowed to directly set a periodic timer’s accumulator.
    ///
    /// Software does NOT have to write this back to `false` (it automatically clears).
    ///
    /// Software should not write a `true` to this bit position if the timer is set to non-periodic mode.
    periodic_accumulator_enable_set: bool,

    _reserved2: u1,

    /// If set forces a 64-bit timer to behave as a 32-bit timer.
    ///
    /// This is typically needed if the software is not willing to halt the main counter to read or write a particular
    /// timer, and the software is not capable of doing an atomic 64-bit read to the timer.
    ///
    /// If the timer is not 64 bits wide, then this bit will always be read as `false` and writes will have no effect.
    force_32bit_mode: bool,

    /// This field indicates the routing for the interrupt to the I/O APIC.
    ///
    /// A maximum value of 32 interrupts are supported.
    ///
    /// If the value is not supported by this particular timer, then the value read back will not match what is written.
    ///
    /// The software must only write valid values.
    ///
    /// Note: If `GeneralConfigurationRegister.legacy_routing_enable` is `true`, then Timers 0 and 1 will have a
    /// different routing, and this field has no effect for those two timers.
    ///
    /// Note: If `fsb_enable` is `true`, then the interrupt will be delivered directly to the FSB, and this field has no
    /// effect.
    interrupt_route: u5,

    /// If `fsb_capable` is `true` for this timer, then setting this field to `true` will force the interrupts to be
    /// delivered directly as FSB messages, rather than using the I/O (x) APIC.
    ///
    /// In this case, the `interrupt_route` field in this register will be ignored.
    /// `TimerFSBInterruptRouteRegister` will be used instead.
    fsb_enable: bool,

    /// Indicates if the hardware supports fsb delivery of this timer’s interrupt.
    fsb_capable: bool,

    _reserved3: u16,

    /// This read-only field indicates to which interrupts in the I/O (x) APIC this timer’s interrupt can be routed.
    ///
    /// This is used in conjunction with the `interrupt_route` field.
    ///
    /// Each bit in this field corresponds to a particular interrupt.
    ///
    /// For example, if this timer’s interrupt can be mapped to interrupts 16, 18, 20, 22, or 24, then bits 16, 18, 20,
    /// 22, and 24 in this field will be set to 1. All other bits will be 0.
    interrupt_route_capability: u32,

    pub const InterruptType = enum(u1) {
        /// The timer interrupt is edge triggered.
        ///
        /// If another interrupt occurs, another edge will be generated.
        edge = 0,

        /// The timer interrupt is level triggered.
        ///
        /// The interrupt will be held active until it is cleared by writing to the bit in the General Interrupt Status
        /// Register.
        ///
        /// If another interrupt occurs before the interrupt is cleared, the interrupt will remain active
        level = 1,
    };

    pub const TimerType = enum(u1) {
        oneshot = 0,
        periodic = 1,
    };

    const base_offset = 0x100 / @sizeOf(u64);

    pub fn read(timer: u5) TimerConfigurationAndCapabilitiesRegister {
        core.debugAssert(timer <= number_of_timers_minus_one);
        return @bitCast(base[base_offset + (timer_offset * timer)]);
    }

    pub fn write(register: TimerConfigurationAndCapabilitiesRegister, timer: u5) void {
        core.debugAssert(timer <= number_of_timers_minus_one);
        base[base_offset + (timer_offset * timer)] = @bitCast(register);
    }
};

const TimerComparatorRegister = struct {
    const base_offset = 0x108 / @sizeOf(u64);

    pub fn read(timer: u5) u64 {
        core.debugAssert(timer <= number_of_timers_minus_one);
        return base[base_offset + (timer_offset * timer)];
    }

    pub fn write(timer: u5, value: u64) void {
        core.debugAssert(timer <= number_of_timers_minus_one);
        base[base_offset + (timer_offset * timer)] = value;
    }
};

const TimerFSBInterruptRouteRegister = packed struct(u64) {
    /// The value that is written during the FSB interrupt message.
    message_value: u32,

    /// The address that is written during the FSB interrupt message.
    fsb_address: u32,

    const base_offset = 0x110 / @sizeOf(u64);

    pub fn read(timer: u5) TimerFSBInterruptRouteRegister {
        core.debugAssert(timer <= number_of_timers_minus_one);
        return @bitCast(base[base_offset + (timer_offset * timer)]);
    }

    pub fn write(register: TimerFSBInterruptRouteRegister, timer: u5) void {
        core.debugAssert(timer <= number_of_timers_minus_one);
        base[base_offset + (timer_offset * timer)] = @bitCast(register);
    }
};
