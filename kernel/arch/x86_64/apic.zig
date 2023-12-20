// SPDX-License-Identifier: MIT

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");
const x86_64 = @import("x86_64.zig");

// TODO: Support x2apic

const log = kernel.debug.log.scoped(.apic);

/// The local APIC base pointer when in xAPIC mode.
///
/// Not set when in x2APIC mode.
var lapic_ptr: [*]volatile u8 = undefined;

fn readRegister(comptime T: type, register: LAPICRegister) T {
    if (x86_64.arch_info.x2apic_enabled) {
        core.panic("x2APIC not supported yet");
    }

    switch (T) {
        u32 => {
            const ptr: *align(16) volatile u32 = @ptrCast(@alignCast(
                lapic_ptr + @intFromEnum(register),
            ));
            return ptr.*;
        },
        else => @compileError("unimplemented size"),
    }
}

fn writeRegister(comptime T: type, register: LAPICRegister, value: T) void {
    if (x86_64.arch_info.x2apic_enabled) {
        core.panic("x2APIC not supported yet");
    }

    switch (T) {
        u32 => {
            const ptr: *align(16) volatile u32 = @ptrCast(@alignCast(
                lapic_ptr + @intFromEnum(register),
            ));
            ptr.* = value;
        },
        else => @compileError("unimplemented size"),
    }
}

const LAPICRegister = enum(usize) {
    /// Local APIC ID Register
    /// Read only
    id = 0x0020,

    /// Local APIC Version Register
    /// Read only
    version = 0x0030,

    /// Task Priority Register (TPR)
    /// Read/Write
    task_priority = 0x0080,

    /// Arbitration Priority Register (APR)
    /// Read Only
    arbitration_priority = 0x0090,

    /// kernel.Processor Priority Register (PPR)
    /// Read Only
    processor_priority = 0x00A0,

    /// EOI Register
    /// Write Only
    eoi = 0x00B0,

    /// Remote Read Register (RRD)
    /// Read Only
    remote_read = 0x00C0,

    /// Logical Destination Register
    /// Read/Write
    logical_destination = 0x00D0,

    /// Destination Format Register
    /// Read/Write
    destination_format = 0x00E0,

    /// Spurious Interrupt Vector Register
    /// Read/Write
    spurious_interrupt = 0x00F0,

    /// In-Service Register (ISR); bits 31:0
    /// Read Only
    in_service_31_0 = 0x0100,

    /// In-Service Register (ISR); bits 63:32
    /// Read Only
    in_service_63_32 = 0x0110,

    /// In-Service Register (ISR); bits 95:64
    /// Read Only
    in_service_95_64 = 0x0120,

    /// In-Service Register (ISR); bits 127:96
    /// Read Only
    in_service_127_96 = 0x0130,

    /// In-Service Register (ISR); bits 159:128
    /// Read Only
    in_service_159_128 = 0x0140,

    /// In-Service Register (ISR); bits 191:160
    /// Read Only
    in_service_191_160 = 0x0150,

    /// In-Service Register (ISR); bits 223:192
    /// Read Only
    in_service_223_192 = 0x0160,

    /// In-Service Register (ISR); bits 255:224
    /// Read Only
    in_service_255_224 = 0x0170,

    /// Trigger Mode Register (TMR); bits 31:0
    /// Read Only
    trigger_mode_31_0 = 0x0180,

    /// Trigger Mode Register (TMR); bits 63:32
    /// Read Only
    trigger_mode_63_32 = 0x0190,

    /// Trigger Mode Register (TMR); bits 95:64
    /// Read Only
    trigger_mode_95_64 = 0x01A0,

    /// Trigger Mode Register (TMR); bits 127:96
    /// Read Only
    trigger_mode_127_96 = 0x01B0,

    /// Trigger Mode Register (TMR); bits 159:128
    /// Read Only
    trigger_mode_159_128 = 0x01C0,

    /// Trigger Mode Register (TMR); bits 191:160
    /// Read Only
    trigger_mode_191_160 = 0x01D0,

    /// Trigger Mode Register (TMR); bits 223:192
    /// Read Only
    trigger_mode_223_192 = 0x01E0,

    /// Trigger Mode Register (TMR); bits 255:224
    /// Read Only
    trigger_mode_255_224 = 0x01F0,

    /// Interrupt Request Register (IRR); bits 31:0
    /// Read Only
    interrupt_request_31_0 = 0x0200,

    /// Interrupt Request Register (IRR); bits 63:32
    /// Read Only
    interrupt_request_63_32 = 0x0210,

    /// Interrupt Request Register (IRR); bits 95:64
    /// Read Only
    interrupt_request_95_64 = 0x0220,

    /// Interrupt Request Register (IRR); bits 127:96
    /// Read Only
    interrupt_request_127_96 = 0x0230,

    /// Interrupt Request Register (IRR); bits 159:128
    /// Read Only
    interrupt_request_159_128 = 0x0240,

    /// Interrupt Request Register (IRR); bits 191:160
    /// Read Only
    interrupt_request_191_160 = 0x0250,

    /// Interrupt Request Register (IRR); bits 223:192
    /// Read Only
    interrupt_request_223_192 = 0x0260,

    /// Interrupt Request Register (IRR); bits 255:224
    /// Read Only
    interrupt_request_255_224 = 0x0270,

    /// Error Status Register
    /// Read Only
    error_status = 0x0280,

    /// LVT Corrected Machine Check Interrupt (CMCI) Register
    /// Read/Write
    corrected_machine_check = 0x02F0,

    /// Interrupt Command Register (ICR); bits 0-31
    /// Read/Write
    interrupt_command_0_31 = 0x0300,

    /// Interrupt Command Register (ICR); bits 32-63
    /// Read/Write
    interrupt_command_32_63 = 0x0310,

    /// LVT Timer Register
    /// Read/Write
    lvt_timer = 0x0320,

    /// LVT Thermal Sensor Register
    /// Read/Write
    lvt_thermal_sensor = 0x0330,

    /// LVT Performance Monitoring Counters Register
    /// Read/Write
    lvt_performance_monitoring = 0x0340,

    /// LVT LINT0 Register
    /// Read/Write
    lint0 = 0x0350,

    /// LVT LINT1 Register
    /// Read/Write
    lint1 = 0x0360,

    /// LVT Error Register
    /// Read/Write
    lvt_error = 0x0370,

    /// Initial Count Register (for Timer)
    /// Read/Write
    initial_count = 0x0380,

    /// Current Count Register (for Timer)
    /// Read Only
    current_count = 0x0390,

    /// Divide Configuration Register (for Timer)
    /// Read/Write
    divide_configuration = 0x03E0,
};

pub const init = struct {
    pub fn initApic(_: *kernel.Processor) linksection(kernel.info.init_code) void {
        if (x86_64.arch_info.x2apic_enabled) {
            core.panic("x2APIC not supported yet");
        } else {
            const lapic_base = getLapicBase();

            log.debug("lapic base: {}", .{lapic_base});

            lapic_ptr = lapic_base.toNonCachedDirectMap().toPtr([*]volatile u8);

            log.debug("lapic ptr: {*}", .{lapic_ptr});
        }

        const version = readVersionRegister();
        log.debug("version register: {}", .{version});

        enable(@intFromEnum(x86_64.interrupts.IdtVector.spurious_interrupt));
    }

    const VersionRegister = packed struct(u32) {
        version: u8,

        _reserved1: u8,

        /// The number of LVT entries minus 1.
        max_lvt_entry: u8,

        /// Indicates whether software can inhibit the broadcast of EOI messages.
        supports_eoi_broadcast_suppression: bool,

        _reserved2: u7,

        pub const format = core.formatStructIgnoreReservedAndHiddenFields;
    };

    fn readVersionRegister() linksection(kernel.info.init_code) VersionRegister {
        return @bitCast(readRegister(u32, .version));
    }

    const APIC_ENABLE_BIT: u32 = 0b100000000;

    fn enable(spurious_interrupt_number: u8) linksection(kernel.info.init_code) void {
        writeRegister(u32, .spurious_interrupt, APIC_ENABLE_BIT | spurious_interrupt_number);
    }

    const IA32_APIC_BASE_MSR = x86_64.registers.MSR(u32, 0x1B);

    fn getLapicBase() linksection(kernel.info.init_code) kernel.PhysicalAddress {
        return kernel.PhysicalAddress.fromInt(IA32_APIC_BASE_MSR.read() & 0xfffff000);
    }
};
