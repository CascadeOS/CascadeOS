// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

// [IA-PC HPET Specification Link](https://www.intel.com/content/dam/www/public/us/en/documents/technical-specifications/software-developers-hpet-spec-1-0a.pdf)

const globals = struct {
    var hpet: Hpet = undefined; // Initalized during `initializeHPET`

    /// The duration of a tick in femptoseconds.
    var tick_duration_fs: u64 = undefined; // Initalized during `initializeHPET`

    var number_of_timers_minus_one: u5 = undefined; // Initalized during `initializeHPET`
};

pub const init = struct {
    pub fn registerTimeSource(context: *kernel.Context, candidate_time_sources: *kernel.time.init.CandidateTimeSources) void {
        const acpi_table = kernel.acpi.getTable(kernel.acpi.tables.HPET, 0) orelse return;
        acpi_table.deinit();

        candidate_time_sources.addTimeSource(context, .{
            .name = "hpet",
            .priority = 100,
            .initialization = .{ .simple = initializeHPET },
            .reference_counter = .{
                .prepareToWaitForFn = referenceCounterPrepareToWaitFor,
                .waitForFn = referenceCounterWaitFor,
            },
        });
    }

    fn initializeHPET(context: *kernel.Context) void {
        globals.hpet = .{ .base = getHpetBase() };
        init_log.debug(context, "using hpet: {}", .{globals.hpet});

        const general_capabilities = globals.hpet.readGeneralCapabilitiesAndIDRegister();

        init_log.debug(context, "counter is 64-bit: {}", .{general_capabilities.counter_is_64bit});

        globals.number_of_timers_minus_one = general_capabilities.number_of_timers_minus_one;

        globals.tick_duration_fs = general_capabilities.counter_tick_period_fs;
        init_log.debug(context, "tick duration (fs): {}", .{globals.tick_duration_fs});

        var general_configuration = globals.hpet.readGeneralConfigurationRegister();
        general_configuration.enable = false;
        general_configuration.legacy_routing_enable = false;
        globals.hpet.writeGeneralConfigurationRegister(general_configuration);

        globals.hpet.writeCounterRegister(0);
    }

    fn referenceCounterPrepareToWaitFor(duration: core.Duration) void {
        _ = duration;

        var general_configuration = globals.hpet.readGeneralConfigurationRegister();
        general_configuration.enable = false;
        globals.hpet.writeGeneralConfigurationRegister(general_configuration);

        globals.hpet.writeCounterRegister(0);

        general_configuration.enable = true;
        globals.hpet.writeGeneralConfigurationRegister(general_configuration);
    }

    fn referenceCounterWaitFor(duration: core.Duration) void {
        const duration_ticks = ((duration.value * kernel.time.fs_per_ns) / globals.tick_duration_fs);

        const current_value = globals.hpet.readCounterRegister();

        const target_value = current_value + duration_ticks;

        while (globals.hpet.readCounterRegister() < target_value) {
            arch.spinLoopHint();
        }
    }

    fn getHpetBase() [*]volatile u64 {
        const acpi_table = kernel.acpi.getTable(kernel.acpi.tables.HPET, 0) orelse {
            // the table is known to exist as it is checked in `registerTimeSource`
            @panic("hpet table missing");
        };
        defer acpi_table.deinit();

        const hpet_table = acpi_table.table;

        if (hpet_table.base_address.address_space != .memory) @panic("HPET base address is not memory mapped");

        return kernel.mem
            .nonCachedDirectMapFromPhysical(core.PhysicalAddress.fromInt(hpet_table.base_address.address))
            .toPtr([*]volatile u64);
    }

    const init_log = kernel.debug.log.scoped(.init_hpet);
};

/// High Precision Event Timer (HPET)
///
/// [IA-PC HPET Specification Link](https://www.intel.com/content/dam/www/public/us/en/documents/technical-specifications/software-developers-hpet-spec-1-0a.pdf)
const Hpet = struct {
    base: [*]volatile u64,

    pub const GeneralCapabilitiesAndIDRegister = packed struct(u64) {
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
    };

    pub fn readGeneralCapabilitiesAndIDRegister(hpet: Hpet) GeneralCapabilitiesAndIDRegister {
        return @bitCast(hpet.base[general_capabilities_and_id_register_offset]);
    }

    pub const GeneralConfigurationRegister = packed struct(u64) {
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
    };

    pub fn readGeneralConfigurationRegister(hpet: Hpet) GeneralConfigurationRegister {
        return @bitCast(hpet.base[general_configuration_register_offset]);
    }

    pub fn writeGeneralConfigurationRegister(hpet: Hpet, register: GeneralConfigurationRegister) void {
        hpet.base[general_configuration_register_offset] = @bitCast(register);
    }

    pub inline fn readCounterRegister(hpet: Hpet) u64 {
        return hpet.base[counter_register_offset];
    }

    pub fn writeCounterRegister(hpet: Hpet, value: u64) void {
        std.debug.assert(!hpet.readGeneralConfigurationRegister().enable); // counter must be disabled
        hpet.base[counter_register_offset] = value;
    }

    pub const TimerConfigurationAndCapabilitiesRegister = packed struct(u64) {
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
    };

    /// It is the callers responsibility to ensure that `timer` is a valid timer.
    pub fn readTimerConfigurationAndCapabilitiesRegister(hpet: Hpet, timer: u5) TimerConfigurationAndCapabilitiesRegister {
        return @bitCast(hpet.base[timer_configuration_and_capabilities_register_base_offset + (timer_register_step * timer)]);
    }

    /// It is the callers responsibility to ensure that `timer` is a valid timer.
    pub fn writeTimerConfigurationAndCapabilitiesRegister(hpet: Hpet, register: TimerConfigurationAndCapabilitiesRegister, timer: u5) void {
        hpet.base[timer_configuration_and_capabilities_register_base_offset + (timer_register_step * timer)] = @bitCast(register);
    }

    /// It is the callers responsibility to ensure that `timer` is a valid timer.
    pub fn readTimerComparatorRegister(hpet: Hpet, timer: u5) u64 {
        return hpet.base[timer_comparator_register_base_offset + (timer_register_step * timer)];
    }

    /// It is the callers responsibility to ensure that `timer` is a valid timer.
    pub fn writeTimerComparatorRegister(hpet: Hpet, timer: u5, value: u64) void {
        hpet.base[timer_comparator_register_base_offset + (timer_register_step * timer)] = value;
    }

    pub const TimerFSBInterruptRouteRegister = packed struct(u64) {
        /// The value that is written during the FSB interrupt message.
        message_value: u32,

        /// The address that is written during the FSB interrupt message.
        fsb_address: u32,

        const base_offset = 0x110 / @sizeOf(u64);
    };

    /// It is the callers responsibility to ensure that `timer` is a valid timer.
    pub fn readTimerFSBInterruptRouteRegister(hpet: Hpet, timer: u5) TimerFSBInterruptRouteRegister {
        return @bitCast(hpet.base[timer_fsb_interrupt_route_register_base_offset + (timer_register_step * timer)]);
    }

    /// It is the callers responsibility to ensure that `timer` is a valid timer.
    pub fn writeTimerFSBInterruptRouteRegister(hpet: Hpet, register: TimerFSBInterruptRouteRegister, timer: u5) void {
        hpet.base[timer_fsb_interrupt_route_register_base_offset + (timer_register_step * timer)] = @bitCast(register);
    }

    pub const general_capabilities_and_id_register_offset: usize = 0x0 / @sizeOf(u64);
    pub const general_configuration_register_offset: usize = 0x10 / @sizeOf(u64);
    pub const counter_register_offset: usize = 0xF0 / @sizeOf(u64);

    pub const timer_register_step: usize = 0x20 / @sizeOf(u64);
    pub const timer_configuration_and_capabilities_register_base_offset: usize = 0x100 / @sizeOf(u64);
    pub const timer_comparator_register_base_offset: usize = 0x108 / @sizeOf(u64);
    pub const timer_fsb_interrupt_route_register_base_offset: usize = 0x110 / @sizeOf(u64);
};

const arch = @import("arch");
const kernel = @import("kernel");
const x64 = @import("x64.zig");

const core = @import("core");
const std = @import("std");
const Tick = kernel.time.wallclock.Tick;
