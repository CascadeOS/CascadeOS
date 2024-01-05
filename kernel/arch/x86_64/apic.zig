// SPDX-License-Identifier: MIT

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");
const x86_64 = @import("x86_64.zig");

const log = kernel.debug.log.scoped(.apic);

/// The local APIC pointer used when in xAPIC mode.
///
/// Initialized in `x86_64.init.captureMADTInformation`.
pub var lapic_ptr: [*]volatile u8 = undefined;

/// Initialized in `init.initApic`
var x2apic: bool = false;

/// Signal end of interrupt.
pub fn eoi() void {
    writeRegister(.eoi, 0);
}

pub const init = struct {
    pub fn initApic(_: *kernel.Processor) linksection(kernel.info.init_code) void {
        x2apic = kernel.boot.x2apicEnabled();
        if (x2apic) log.debug("x2apic mode", .{}) else log.debug("xapic mode", .{});

        const version = VersionRegister.read();
        log.debug("version register: {}", .{version});

        const spurious_interrupt_register: SupriousInterruptRegister = .{
            .apic_enable = true,
            .spurious_vector = @intFromEnum(x86_64.interrupts.IdtVector.spurious_interrupt),
        };
        spurious_interrupt_register.write();
    }

    const VersionRegister = packed struct(u32) {
        version: u8,

        _reserved1: u8,

        /// The number of LVT entries minus 1.
        max_lvt_entry: u8,

        /// Indicates whether software can inhibit the broadcast of EOI messages.
        supports_eoi_broadcast_suppression: bool,

        _reserved2: u7,

        pub fn read() linksection(kernel.info.init_code) VersionRegister {
            return @bitCast(readRegister(.version));
        }
    };

    const SupriousInterruptRegister = packed struct(u32) {
        /// The vector number to be delivered to the processor when the local APIC generates a spurious vector.
        spurious_vector: u8,

        /// Indicates whether the local APIC is enabled.
        apic_enable: bool,

        /// Is focus processor checking enabled when using lowest-priority delivery mode.
        ///
        /// In Pentium 4 and Intel Xeon processors, this bit is reserved and should be set to `false`.
        focus_processor_checking: bool = false,

        _reserved1: u2 = 0,

        /// Determines whether an EOI for a level-triggered interrupt causes EOI messages to be broadcast to the I/O APICs or not.
        ///
        /// The default value is `false`, indicating that EOI broadcasts are performed.
        ///
        /// This is reserved to `false` if the processor does not support EOI-broadcast suppression.
        eoi_broadcast_suppression: bool = false,

        _reserved2: u19 = 0,

        pub fn read() linksection(kernel.info.init_code) SupriousInterruptRegister {
            return @bitCast(readRegister(.spurious_interrupt));
        }

        pub fn write(self: SupriousInterruptRegister) linksection(kernel.info.init_code) void {
            writeRegister(.spurious_interrupt, @bitCast(self));
        }
    };
};

fn readRegister(register: LAPICRegister) u32 {
    if (x2apic) {
        core.debugAssert(register != .interrupt_command_32_63); // not supported in x2apic mode
        if (register == .interrupt_command_0_31) core.panic("this is a 64-bit register");

        return x86_64.registers.readMSR(u32, register.x2apicRegister());
    }

    const ptr: *align(16) volatile u32 = @ptrCast(@alignCast(
        lapic_ptr + register.xapicOffset(),
    ));
    return ptr.*;
}

fn writeRegister(register: LAPICRegister, value: u32) void {
    if (x2apic) {
        core.debugAssert(register != .interrupt_command_32_63); // not supported in x2apic mode
        if (register == .interrupt_command_0_31) core.panic("this is a 64-bit register");

        x86_64.registers.writeMSR(u32, register.x2apicRegister(), value);
        return;
    }

    const ptr: *align(16) volatile u32 = @ptrCast(@alignCast(
        lapic_ptr + register.xapicOffset(),
    ));
    ptr.* = value;
}

const LAPICRegister = enum(u32) {
    /// Local APIC ID Register
    ///
    /// Read only
    id = 0x2,

    /// Local APIC Version Register
    ///
    /// Read only
    version = 0x3,

    /// Task Priority Register (TPR)
    ///
    /// Read/Write
    task_priority = 0x8,

    /// Arbitration Priority Register (APR)
    ///
    /// Read Only
    arbitration_priority = 0x9,

    /// kernel.Processor Priority Register (PPR)
    ///
    /// Read Only
    processor_priority = 0xA,

    /// EOI Register
    ///
    /// Write Only
    eoi = 0xB,

    /// Remote Read Register (RRD)
    ///
    /// Read Only
    remote_read = 0xC,

    /// Logical Destination Register
    ///
    /// Read/Write
    logical_destination = 0xD,

    /// Destination Format Register
    ///
    /// Read/Write
    destination_format = 0xE,

    /// Spurious Interrupt Vector Register
    ///
    /// Read/Write
    spurious_interrupt = 0xF,

    /// In-Service Register (ISR); bits 31:0
    ///
    /// Read Only
    in_service_31_0 = 0x10,

    /// In-Service Register (ISR); bits 63:32
    ///
    /// Read Only
    in_service_63_32 = 0x11,

    /// In-Service Register (ISR); bits 95:64
    ///
    /// Read Only
    in_service_95_64 = 0x12,

    /// In-Service Register (ISR); bits 127:96
    ///
    /// Read Only
    in_service_127_96 = 0x13,

    /// In-Service Register (ISR); bits 159:128
    ///
    /// Read Only
    in_service_159_128 = 0x14,

    /// In-Service Register (ISR); bits 191:160
    ///
    /// Read Only
    in_service_191_160 = 0x15,

    /// In-Service Register (ISR); bits 223:192
    ///
    /// Read Only
    in_service_223_192 = 0x16,

    /// In-Service Register (ISR); bits 255:224
    ///
    /// Read Only
    in_service_255_224 = 0x17,

    /// Trigger Mode Register (TMR); bits 31:0
    ///
    /// Read Only
    trigger_mode_31_0 = 0x18,

    /// Trigger Mode Register (TMR); bits 63:32
    ///
    /// Read Only
    trigger_mode_63_32 = 0x19,

    /// Trigger Mode Register (TMR); bits 95:64
    ///
    /// Read Only
    trigger_mode_95_64 = 0x1A,

    /// Trigger Mode Register (TMR); bits 127:96
    ///
    /// Read Only
    trigger_mode_127_96 = 0x1B,

    /// Trigger Mode Register (TMR); bits 159:128
    ///
    /// Read Only
    trigger_mode_159_128 = 0x1C,

    /// Trigger Mode Register (TMR); bits 191:160
    ///
    /// Read Only
    trigger_mode_191_160 = 0x1D,

    /// Trigger Mode Register (TMR); bits 223:192
    ///
    /// Read Only
    trigger_mode_223_192 = 0x1E,

    /// Trigger Mode Register (TMR); bits 255:224
    ///
    /// Read Only
    trigger_mode_255_224 = 0x1F,

    /// Interrupt Request Register (IRR); bits 31:0
    ///
    /// Read Only
    interrupt_request_31_0 = 0x20,

    /// Interrupt Request Register (IRR); bits 63:32
    ///
    /// Read Only
    interrupt_request_63_32 = 0x21,

    /// Interrupt Request Register (IRR); bits 95:64
    ///
    /// Read Only
    interrupt_request_95_64 = 0x22,

    /// Interrupt Request Register (IRR); bits 127:96
    ///
    /// Read Only
    interrupt_request_127_96 = 0x23,

    /// Interrupt Request Register (IRR); bits 159:128
    ///
    /// Read Only
    interrupt_request_159_128 = 0x24,

    /// Interrupt Request Register (IRR); bits 191:160
    ///
    /// Read Only
    interrupt_request_191_160 = 0x25,

    /// Interrupt Request Register (IRR); bits 223:192
    ///
    /// Read Only
    interrupt_request_223_192 = 0x26,

    /// Interrupt Request Register (IRR); bits 255:224
    ///
    /// Read Only
    interrupt_request_255_224 = 0x27,

    /// Error Status Register
    ///
    /// Read Only
    error_status = 0x28,

    /// LVT Corrected Machine Check Interrupt (CMCI) Register
    ///
    /// Read/Write
    corrected_machine_check = 0x2F,

    /// Interrupt Command Register (ICR); bits 0-31
    ///
    /// In x2APIC mode this is a single 64-bit register.
    ///
    /// Read/Write
    interrupt_command_0_31 = 0x30,

    /// Interrupt Command Register (ICR); bits 32-63
    ///
    /// Not available in x2APIC mode, `interrupt_command_0_31` is the full 64-bit register.
    ///
    /// Read/Write
    interrupt_command_32_63 = 0x31,

    /// LVT Timer Register
    ///
    /// Read/Write
    lvt_timer = 0x32,

    /// LVT Thermal Sensor Register
    ///
    /// Read/Write
    lvt_thermal_sensor = 0x33,

    /// LVT Performance Monitoring Counters Register
    ///
    /// Read/Write
    lvt_performance_monitoring = 0x34,

    /// LVT LINT0 Register
    ///
    /// Read/Write
    lint0 = 0x35,

    /// LVT LINT1 Register
    ///
    /// Read/Write
    lint1 = 0x36,

    /// LVT Error Register
    ///
    /// Read/Write
    lvt_error = 0x37,

    /// Initial Count Register (for Timer)
    ///
    /// Read/Write
    initial_count = 0x38,

    /// Current Count Register (for Timer)
    ///
    /// Read Only
    current_count = 0x39,

    /// Divide Configuration Register (for Timer)
    ///
    /// Read/Write
    divide_configuration = 0x3E,

    /// Self IPI Register
    ///
    /// Only usable in x2APIC mode
    ///
    /// Write Only
    self_ipi = 0x3F,

    pub fn xapicOffset(self: LAPICRegister) usize {
        core.debugAssert(self != .self_ipi); // not supported in xAPIC mode

        return @intFromEnum(self) * 0x10;
    }

    pub fn x2apicRegister(self: LAPICRegister) u32 {
        core.debugAssert(self != .interrupt_command_32_63); // not supported in x2APIC mode

        return 0x800 + @intFromEnum(self);
    }
};
