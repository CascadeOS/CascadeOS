// SPDX-License-Identifier: MIT

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");
const x86_64 = @import("x86_64.zig");

const log = kernel.debug.log.scoped(.apic);

/// The local APIC pointer used when in xAPIC mode.
///
/// Initialized in `x86_64.init.captureMADTInformation`.
var lapic_ptr: [*]volatile u8 = undefined;

/// Initialized in `init.captureApicInformation`
var x2apic: bool = false;

/// Signal end of interrupt.
///
/// For all interrupts except those delivered with the NMI, SMI, INIT, ExtINT, the start-up, or INIT-Deassert delivery
/// mode, the interrupt handler must include a write to the end-of-interrupt (EOI) register.
///
/// This write must occur at the end of the handler routine, sometime before the IRET instruction.
///
/// This action indicates that the servicing of the current interrupt is complete and the local APIC can issue the next
/// interrupt from the ISR.
pub fn eoi() void {
    writeRegister(.eoi, 0);
}

/// Set the task priority to the given priority.
pub fn setTaskPriority(priority: kernel.scheduler.Priority) void {
    // Set the TPR `priority_class` to 2 as that is the lowest priority that does not overlap with
    // exceptions/PIC interrupts.
    TaskPriorityRegister.write(.{
        .priority_sub_class = @intFromEnum(priority),
        .priority_class = 2,
    });

    log.debug("set task priority to: {s}", .{@tagName(priority)});
}

pub const init = struct {
    pub fn captureApicInformation(
        fadt: *const kernel.acpi.FADT,
        madt: *const kernel.acpi.MADT,
    ) linksection(kernel.info.init_code) void {
        x2apic = kernel.boot.x2apicEnabled();
        if (x2apic) {
            log.debug("x2apic mode", .{});
        } else {
            log.debug("xapic mode", .{});

            lapic_ptr = kernel.PhysicalAddress
                .fromInt(madt.local_interrupt_controller_address)
                .toNonCachedDirectMap()
                .toPtr([*]volatile u8);
            log.debug("lapic address: {*}", .{lapic_ptr});
        }

        if (fadt.fixed_feature_flags.FORCE_APIC_PHYSICAL_DESTINATION_MODE) {
            core.panic("physical destination mode is forced");
        }
    }

    pub fn initApicOnProcessor(_: *kernel.Processor) linksection(kernel.info.init_code) void {
        setTaskPriority(.idle);

        const spurious_interrupt_register: SupriousInterruptRegister = .{
            .apic_enable = true,
            .spurious_vector = @intFromEnum(x86_64.interrupts.IdtVector.spurious_interrupt),
        };
        spurious_interrupt_register.write();
    }

    /// Local APIC Version Register
    const VersionRegister = packed struct(u32) {
        /// The version numbers of the local APIC.
        ///
        ///  - 0XH - 82489DX discrete APIC.
        ///  - 10H - 15H Integrated APIC.
        ///  - Other values reserved.
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

    /// Spurious-Interrupt Vector Register
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

        /// Determines whether an EOI for a level-triggered interrupt causes EOI messages to be broadcast to the I/O
        /// APICs or not.
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

    /// LVT Timer Register
    ///
    /// The timer can be configured through the timer LVT entry for one-shot or periodic operation.
    ///
    /// In one-shot mode, the timer is started by programming its initial-count register. The initial count value is
    /// then copied into the current count register and count-down begins.
    /// After the timer reaches zero, a timer interrupt is generated and the timer remains at its 0 value until reprogrammed.
    ///
    /// In periodic mode, the timer is started by writing to the initial-count register (as in one-shot mode), and the
    /// value written is copied into the current-count register, which counts down.
    /// The current-count register is automatically reloaded from the initial-count register when the count reaches 0
    /// and a timer interrupt is generated, and the count-down is repeated.
    /// If during the count-down process the initial-count register is set, counting will restart, using the new
    /// initial-count value.
    const LVTTimerRegister = packed struct(u32) {
        /// Interrupt vector number.
        vector: u8,

        _reserved1: u4 = 0,

        /// Indicates the interrupt delivery status.
        ///
        /// Read Only
        status: DeliveryStatus,

        _reserved2: u3 = 0,

        /// Interrupt mask: `false` enables reception of the interrupt and `true` inhibits reception of the interrupt.
        ///
        /// When the local APIC handles a performance-monitoring counters interrupt, it automatically sets the mask flag in
        /// the LVT performance counter register.
        ///
        /// This flag is set to `true` on reset.
        ///
        /// It can be cleared only by software.
        masked: bool,

        /// The timer mode.
        timer_mode: TimerMode,

        _reserved3: u13 = 0,

        pub const TimerMode = enum(u2) {
            /// One-shot mode using a count-down value.
            oneshot = 0b00,

            /// Periodic mode reloading a count-down value.
            periodic = 0b01,

            /// TSC-Deadline mode using absolute target value in IA32_TSC_DEADLINE MSR.
            ///
            /// TSC-deadline mode allows software to use the local APIC timer to signal an interrupt at an absolute time.
            ///
            /// In TSC-deadline mode, writes to the initial-count register are ignored; and current-count register
            /// always reads 0.
            ///
            /// Instead, timer behavior is controlled using the IA32_TSC_DEADLINE MSR.
            ///
            /// The IA32_TSC_DEADLINE MSR (MSR address 6E0H) is a per-logical processor MSR that specifies the time at
            /// which a timer interrupt should occur.
            /// Writing a non-zero 64-bit value into IA32_TSC_DEADLINE arms the timer.
            /// An interrupt is generated when the logical processor’s time-stamp counter equals or exceeds the target
            /// value in the IA32_TSC_DEADLINE MSR.
            ///
            /// When the timer generates an interrupt, it disarms itself and clears the IA32_TSC_DEADLINE MSR.
            /// Thus, each write to the IA32_TSC_DEADLINE MSR generates at most one timer interrupt.
            ///
            /// In TSC-deadline mode, writing 0 to the IA32_TSC_DEADLINE MSR disarms the local-APIC timer.
            ///
            /// Transitioning between TSC-deadline mode and other timer modes also disarms the timer.
            ///
            /// If software disarms the timer or postpones the deadline, race conditions may result in the delivery of
            /// a spurious timer interrupt.
            /// Software is expected to detect such spurious interrupts by checking the current value of the time-stamp
            /// counter to confirm that the interrupt was desired.
            ///
            /// In xAPIC mode (in which the local-APIC registers are memory-mapped), software must order the
            /// memory-mapped write to the LVT entry that enables TSC-deadline mode and any subsequent WRMSR to the
            /// IA32_TSC_DEADLINE MSR.
            /// Software can assure proper ordering by executing the MFENCE instruction after the memory-mapped write
            /// and before any WRMSR.
            /// (In x2APIC mode, the WRMSR instruction is used to write to the LVT entry. The processor ensures the
            /// ordering of this write and any subsequent WRMSR to the deadline; no fencing is required.)
            tsc_deadline = 0b10,

            _,
        };

        pub fn read() linksection(kernel.info.init_code) LVTTimerRegister {
            return @bitCast(readRegister(.lvt_timer));
        }

        pub fn write(self: LVTTimerRegister) linksection(kernel.info.init_code) void {
            writeRegister(.lvt_timer, @bitCast(self));
        }
    };

    /// LVT Error Register
    const LVTErrorRegister = packed struct(u32) {
        /// Interrupt vector number.
        vector: u8,

        /// Specifies the type of interrupt to be sent to the processor.
        ///
        /// Some delivery modes will only operate as intended when used in conjunction with a specific trigger mode.
        delivery_mode: DeliveryMode,

        /// Indicates the interrupt delivery status.
        ///
        /// Read Only
        status: DeliveryStatus,

        _reserved2: u3 = 0,

        /// Interrupt mask: `false` enables reception of the interrupt and `true` inhibits reception of the interrupt.
        ///
        /// When the local APIC handles a performance-monitoring counters interrupt, it automatically sets the mask flag in
        /// the LVT performance counter register.
        ///
        /// This flag is set to `true` on reset.
        ///
        /// It can be cleared only by software.
        masked: bool,

        _reserved3: u16 = 0,

        pub fn read() linksection(kernel.info.init_code) LVTErrorRegister {
            return @bitCast(readRegister(.lvt_error));
        }

        pub fn write(self: LVTErrorRegister) linksection(kernel.info.init_code) void {
            writeRegister(.lvt_error, @bitCast(self));
        }
    };

    /// Divide Configuration Register
    ///
    /// The APIC timer frequency will be the processor’s bus clock or core crystal clock frequency (when TSC/core
    /// crystal clock ratio is enumerated in CPUID leaf 0x15) divided by the value specified in the divide configuration
    /// register.
    const DivideConfigurationRegister = enum(u32) {
        /// Divide by 2
        @"2" = 0b0000,

        /// Divide by 4
        @"4" = 0b0001,

        /// Divide by 8
        @"8" = 0b0010,

        /// Divide by 16
        @"16" = 0b0011,

        /// Divide by 32
        @"32" = 0b1000,

        /// Divide by 64
        @"64" = 0b1001,

        /// Divide by 128
        @"128" = 0b1010,

        /// Divide by 1
        @"1" = 0b1011,

        pub fn read() linksection(kernel.info.init_code) DivideConfigurationRegister {
            return @enumFromInt(readRegister(.divide_configuration));
        }

        pub fn write(self: DivideConfigurationRegister) linksection(kernel.info.init_code) void {
            writeRegister(.divide_configuration, @intFromEnum(self));
        }
    };

    /// In x2APIC mode, the Logical Destination Register (LDR) is increased to 32 bits wide and is read-only.
    const LogicalDestinationRegister = packed union {
        xapic: packed struct(u32) {
            _reserved: u24 = 0,

            /// The 8-bit logical APIC ID used to create an identifier that can be compared with the MDA.
            logical_apic_id: u8,
        },

        x2apic: packed struct(u32) {
            /// The 32-bit logical APIC ID used to create an identifier that can be compared with the MDA.
            ///
            /// The 32-bit logical x2APIC ID field of LDR is partitioned into two sub-fields:
            ///  - Cluster ID (LDR[31:16]): is the address of the destination cluster
            ///  - Logical ID (LDR[15:0]): defines a logical ID of the individual local x2APIC within the cluster specified
            ///    by LDR[31:16].
            logical_apic_id: u32,
        },

        pub fn read() linksection(kernel.info.init_code) LogicalDestinationRegister {
            return @bitCast(readRegister(.logical_destination));
        }

        pub fn write(self: LogicalDestinationRegister) linksection(kernel.info.init_code) void {
            core.debugAssert(!x2apic); // read only in x2APIC mode
            writeRegister(.logical_destination, @bitCast(self));
        }
    };

    /// This register selects one of two models (flat or cluster) that can be used to interpret the MDA when using
    /// logical destination mode.
    ///
    /// NOTE: All processors that have their APIC software enabled (using the spurious vector enable/disable bit) must
    /// have their DFRs (Destination Format Registers) programmed identically.
    ///
    /// The default mode for DFR is flat mode.
    ///
    /// If you are using cluster mode, DFRs must be programmed before the APIC is software enabled.
    ///
    /// Since some chipsets do not accurately track a system view of the logical mode, program DFRs as soon as possible
    /// after starting the processor.
    ///
    /// Not supported in x2APIC mode, where the destination mode is always cluster.
    const DestinationFormatRegister = packed struct(u32) {
        _reserved: u28 = std.math.maxInt(u28),

        model: Model,

        pub const Model = enum(u4) {
            /// This model supports two basic destination schemes:
            ///  - flat cluster
            ///  - hierarchical cluster
            ///
            /// The flat cluster destination model is only supported for P6 family and Pentium processors.
            /// Using this model, all APICs are assumed to be connected through the APIC bus.
            /// Bits 60 through 63 of the MDA contains the encoded address of the destination cluster and bits 56
            /// through 59 identify up to four local APICs within the cluster (each bit is assigned to one local APIC in
            /// the cluster, as in the flat connection model).
            /// To identify one or more local APICs, bits 60 through 63 of the MDA are compared with bits 28 through 31
            /// of the LDR to determine if a local APIC is part of the cluster.
            /// Bits 56 through 59 of the MDA are compared with Bits 24 through 27 of the LDR to identify a local APICs
            /// within the cluster.
            /// Sets of processors within a cluster can be specified by writing the target cluster address in bits 60
            /// through 63 of the MDA and setting selected bits in bits 56 through 59 of the MDA, corresponding to the
            /// chosen members of the cluster.
            /// In this mode, 15 clusters (with cluster addresses of 0 through 14) each having 4 local APICs can be
            /// specified in the message.
            /// For the P6 and Pentium processor's local APICs, however, the APIC arbitration ID supports only 15 APIC
            /// agents.
            /// Therefore, the total number of processors and their local APICs supported in this mode is limited to 15.
            /// Broadcast to all local APICs is achieved by setting all destination bits to one.
            /// This guarantees a match on all clusters and selects all APICs in each cluster.
            /// A broadcast IPI or I/O subsystem broadcast interrupt with lowest priority delivery mode is not supported
            /// n cluster mode and must not be configured by software.
            ///
            /// The hierarchical cluster destination model can be used with Pentium 4, Intel Xeon, P6 family, or Pentium
            /// processors.
            /// With this model, a hierarchical network can be created by connecting different flat clusters via
            /// independent system or APIC buses.
            ///
            /// This scheme requires a cluster manager within each cluster, which is responsible for handling message
            /// passing between system or APIC buses.
            ///
            /// One cluster contains up to 4 agents. Thus 15 cluster managers, each with 4 agents, can form a network of
            /// up to 60 APIC agents. Note that hierarchical APIC networks requires a special cluster manager device,
            /// which is not part of the local or the I/O APIC units.
            cluster = 0b0000,

            /// Here, a unique logical APIC ID can be established for up to 8 local APICs by setting a different bit in
            /// the logical APIC ID field of the LDR for each local APIC.
            ///
            /// A group of local APICs can then be selected by setting one or more bits in the MDA.
            ///
            /// Each local APIC performs a bit-wise AND of the MDA and its logical APIC ID.
            /// If a true condition (non-zero) is detected, the local APIC accepts the IPI message.
            ///
            /// A broadcast to all APICs is achieved by setting the MDA to 1s.
            flat = 0b1111,
        };

        pub fn read() linksection(kernel.info.init_code) DestinationFormatRegister {
            core.debugAssert(!x2apic); // not supported in x2APIC mode
            return @bitCast(readRegister(.logical_destination));
        }

        pub fn write(self: DestinationFormatRegister) linksection(kernel.info.init_code) void {
            core.debugAssert(!x2apic); // not supported in x2APIC mode
            writeRegister(.logical_destination, @bitCast(self));
        }
    };
};

/// The task priority register allows software to set a priority threshold for interrupting the processor.
///
/// This mechanism enables the operating system to temporarily block low priority interrupts from disturbing
/// high-priority work that the processor is doing.
///
/// The ability to block such interrupts using task priority results from the way that the TPR controls the value of the
/// processor-priority register (PPR).
const TaskPriorityRegister = packed struct(u32) {
    priority_sub_class: u4,

    priority_class: u4,

    _reserved: u24 = 0,

    pub fn read() TaskPriorityRegister {
        return @bitCast(readRegister(.task_priority));
    }

    pub fn write(self: TaskPriorityRegister) void {
        writeRegister(.task_priority, @bitCast(self));
    }
};

/// In one-shot mode, the timer is started by programming its initial-count register. The initial count value is
/// then copied into the current count register and count-down begins.
/// After the timer reaches zero, a timer interrupt is generated and the timer remains at its 0 value until reprogrammed.
///
/// In periodic mode, the timer is started by writing to the initial-count register (as in one-shot mode), and the
/// value written is copied into the current-count register, which counts down.
/// The current-count register is automatically reloaded from the initial-count register when the count reaches 0
/// and a timer interrupt is generated, and the count-down is repeated.
/// If during the count-down process the initial-count register is set, counting will restart, using the new
/// initial-count value.
///
/// A write of 0 to the initial-count register effectively stops the local APIC timer, in both one-shot and periodic mode.
pub const InitialCountRegister = struct {
    pub fn read() linksection(kernel.info.init_code) u32 {
        return readRegister(.initial_count);
    }

    pub fn write(count: u32) linksection(kernel.info.init_code) void {
        writeRegister(.initial_count, count);
    }
};

/// The primary local APIC facility for issuing IPIs is the interrupt command register (ICR).
///
/// The ICR can be used for the following functions:
///  - To send an interrupt to another processor.
///  - To allow a processor to forward an interrupt that it received but did not service to another processor for
///    servicing.
///  - To direct the processor to interrupt itself (perform a self interrupt).
///  - To deliver special IPIs, such as the start-up IPI (SIPI) message, to other processors.
///
/// Interrupts generated with this facility are delivered to the other processors in the system through the system bus
/// (for Pentium 4 and Intel Xeon processors) or the APIC bus (for P6 family and Pentium processors).
///
/// The ability for a processor to send a lowest priority IPI is model specific and should be avoided by BIOS and
/// operating system software.
///
/// To send an IPI, software must set up the ICR to indicate the type of IPI message to be sent and the destination
/// processor or processors.
///
/// The act of writing to the low doubleword of the ICR causes the IPI to be sent.
pub const InterruptCommandRegister = packed struct(u64) {
    /// The vector number of the interrupt being sent.
    vector: x86_64.interrupts.IdtVector,

    /// Specifies the type of IPI to be sent.
    delivery_mode: DeliveryMode,

    /// Specifies the destination mode to use.
    destination_mode: DestinationMode,

    /// Indicates the IPI delivery status.
    ///
    /// Reserved in x2APIC mode.
    delivery_status: DeliveryStatus,

    _reserved1: u1 = 0,

    /// For the INIT level de-assert delivery mode this flag must be set to 0; for all other delivery modes it must be
    /// set to 1.
    ///
    ///
    /// This flag has no meaning in Pentium 4 and Intel Xeon processors, and will always be issued as `assert`.
    level: Level,

    /// Selects the trigger mode when using the INIT level de-assert delivery mode.
    ///
    /// It is ignored for all other delivery modes.
    ///
    /// This flag has no meaning in Pentium 4 and Intel Xeon processors, and will always be issued as `edge`.
    trigger_mode: TriggerMode,

    _reserved2: u2 = 0,

    /// Indicates whether a shorthand notation is used to specify the destination of the interrupt and, if so, which
    /// shorthand is used.
    ///
    /// Destination shorthands are used in place of the 8-bit destination field, and can be sent by software using a
    /// single write to the low doubleword of the ICR.
    destination_shorthand: DestinationShorthand,

    _reserved3: u12 = 0,

    /// Specifies the target processor or processors.
    ///
    /// This field is only used when the `destination_shorthand` field is set to `.no_shorthand`.
    ///
    /// If `destination_mode` is set to `.physical`, then bits 56 through 59 contain the APIC ID of the target processor
    /// for Pentium and P6 family processors and bits 56 through 63 contain the APIC ID of the target processor the for
    /// Pentium 4 and Intel Xeon processors.
    ///
    /// If the `destination_mode` is set to `.logical`, the interpretation of the 8-bit destination field depends on the
    /// settings of the DFR and LDR registers of the local APICs in all the processors in the system.
    ///
    /// The destination field is expanded to 32 bits in x2APIC mode.
    ///
    /// In x2APIC mode a destination value of FFFF_FFFFH is used for broadcast of interrupts in both logical destination
    /// and physical destination modes.
    destination_field: Destination,

    pub const Destination = packed union {
        xapic: packed struct(u32) {
            _reserved: u24 = 0,
            destination: u8,
        },
        x2apic: packed struct {
            destination: u32,
        },
    };

    pub const DestinationShorthand = enum(u2) {
        /// The destination is specified in the destination field.
        no_shorthand = 0b00,

        /// The issuing APIC is the one and only destination of the IPI.
        ///
        /// This destination shorthand allows software to interrupt the processor on which it is executing.
        ///
        /// An APIC implementation is free to deliver the self-interrupt message internally or to issue the message to
        /// the bus and "snoop" it as with any other IPI message.
        self = 0b01,

        /// The IPI is sent to all processors in the system including the processor sending the IPI.
        ///
        /// The APIC will broadcast an IPI message with the destination field set to FH for Pentium and P6 family
        /// processors and to FFH for Pentium 4 and Intel Xeon processors.
        all_including_self = 0b10,

        /// The IPI is sent to all processors in a system with the exception of the processor sending the IPI.
        ///
        /// The APIC broadcasts a message with the physical destination mode and destination field set to FH for Pentium
        /// and P6 family processors and to FFH for Pentium 4 and Intel Xeon processors.
        ///
        /// Support for this destination shorthand in conjunction with the lowest-priority delivery mode is model
        /// specific.
        ///
        /// For Pentium 4 and Intel Xeon processors, when this shorthand is used together with lowest priority delivery
        /// mode, the IPI may be redirected back to the issuing processor.
        all_excluding_self = 0b11,
    };

    pub fn read() InterruptCommandRegister {
        if (x2apic) {
            return @bitCast(
                x86_64.registers.readMSR(u64, LAPICRegister.interrupt_command_0_31.x2apicRegister()),
            );
        }

        const low: u64 = readRegister(.interrupt_command_0_31);
        const high: u64 = readRegister(.interrupt_command_32_63);

        return @bitCast(high << 32 | low);
    }

    pub fn write(self: InterruptCommandRegister) void {
        if (x2apic) {
            x86_64.registers.writeMSR(
                u64,
                LAPICRegister.interrupt_command_0_31.x2apicRegister(),
                @bitCast(self),
            );
            return;
        }

        const value: u64 = @bitCast(self);

        writeRegister(.interrupt_command_32_63, @truncate(value >> 32));
        @fence(.SeqCst);
        writeRegister(.interrupt_command_0_31, @truncate(value));
    }
};

pub const Level = enum(u1) {
    deassert = 0,
    assert = 1,
};

pub const TriggerMode = enum(u1) {
    edge = 0,
    level = 1,
};

pub const DestinationMode = enum(u1) {
    /// In physical destination mode, the destination processor is specified by its local APIC ID.
    ///
    /// For Pentium 4 and Intel Xeon processors, either a single destination (local APIC IDs 00H through FEH) or a
    /// broadcast to all APICs (the APIC ID is FFH) may be specified in physical destination mode.
    ///
    /// A broadcast IPI (bits 28-31 of the MDA are 1's) or I/O subsystem initiated interrupt with lowest priority
    /// delivery mode is not supported in physical destination mode and must not be configured by software.
    ///
    /// Also, for any non-broadcast IPI or I/O subsystem initiated interrupt with lowest priority delivery mode,
    /// software must ensure that APICs defined in the interrupt address are present and enabled to receive interrupts.
    ///
    /// For the P6 family and Pentium processors, a single destination is specified in physical destination mode
    /// with a local APIC ID of 0H through 0EH, allowing up to 15 local APICs to be addressed on the APIC bus.
    ///
    /// A broadcast to all local APICs is specified with 0FH.
    physical = 0,

    /// In logical destination mode, IPI destination is specified using an 8-bit message destination address (MDA),
    /// which is entered in the destination field of the ICR.
    ///
    /// Upon receiving an IPI message that was sent using logical destination mode, a local APIC compares the MDA in
    /// the message with the values in its LDR and DFR to determine if it should accept and handle the IPI.
    ///
    /// For both configurations of logical destination mode, when combined with lowest priority delivery mode,
    /// software is responsible for ensuring that all of the local APICs included in or addressed by the IPI or I/O
    /// subsystem interrupt are present and enabled to receive the interrupt.
    logical = 1,
};

/// The local APIC records errors detected during interrupt handling in the error status register (ESR).
///
/// The ESR is a write/read register.
///
/// Before attempt to read from the ESR, software should first write to it.
/// (The value written does not affect the values read subsequently; only zero may be written in x2APIC mode.)
///
/// This write clears any previously logged errors and updates the ESR with any errors detected since the last write to
/// the ESR.
///
/// This write also rearms the APIC error interrupt triggering mechanism.
///
/// The LVT Error Register allows specification of the vector of the interrupt to be delivered to the processor core
/// when APIC error is detected.
/// The register also provides a means of masking an APIC-error interrupt.
/// This masking only prevents delivery of APIC-error interrupts; the APIC continues to record errors in the ESR.
pub const ErrorStatusRegister = packed struct(u32) {
    /// Set when the local APIC detects a checksum error for a message that it sent on the APIC bus.
    ///
    /// Used only on P6 family and Pentium processors.
    send_checksum: bool,

    /// Set when the local APIC detects a checksum error for a message that it received on the APIC bus.
    ///
    /// Used only on P6 family and Pentium processors.
    receive_checksum: bool,

    /// Set when the local APIC detects that a message it sent was not accepted by any APIC on the APIC bus.
    ///
    /// Used only on P6 family and Pentium processors.
    send_accept: bool,

    /// Set when the local APIC detects that the message it received was not accepted by any APIC on the APIC bus,
    /// including itself.
    ///
    /// Used only on P6 family and Pentium processors.
    receive_accept: bool,

    /// Set when the local APIC detects an attempt to send an IPI with the lowest-priority delivery mode and the local
    /// APIC does not support the sending of such IPIs.
    ///
    /// This bit is used on some Intel Core and Intel Xeon processors.
    ///
    /// The ability of a processor to send a lowest-priority IPI is model-specific and should be avoided.
    redirectable_ipi: bool,

    /// Set when the local APIC detects an illegal vector (one in the range 0 to 15) in the message that it is sending.
    ///
    /// This occurs as the result of a write to the ICR (in both xAPIC and x2APIC modes) or to SELF IPI register
    /// (x2APIC mode only) with an illegal vector.
    ///
    /// If the local APIC does not support the sending of lowest-priority IPIs and software writes the ICR to send a
    /// lowest-priority IPI with an illegal vector, the local APIC sets only the `redirectable_ipi` error bit.
    /// The interrupt is not processed and hence the `send_illegal` bit is not set in the ESR.
    send_illegal: bool,

    /// Set when the local APIC detects an illegal vector (one in the range 0 to 15) in an interrupt message it receives
    /// or in an interrupt generated locally from the local vector table or via a self IPI.
    ///
    /// Such interrupts are not delivered to the processor; the local APIC will never set an IRR bit in the range 0 to 15.
    received_illegal: bool,

    /// Set when the local APIC is in xAPIC mode and software attempts to access a register that is reserved in the
    /// processor's local-APIC register-address space.
    ///
    /// Used only on Intel Core, Intel Atom, Pentium 4, Intel Xeon, and P6 family processors.
    ///
    /// In x2APIC mode, software accesses the APIC registers using the RDMSR and WRMSR instructions.
    /// Use of one of these instructions to access a reserved register cause a general-protection exception.
    /// They do not set the `illegal_register` bit in the ESR.
    illegal_register: bool,

    _reserved: u24,

    pub fn read() ErrorStatusRegister {
        writeRegister(.error_status, 0);
        return @bitCast(readRegister(.error_status));
    }
};

/// Indicates the interrupt delivery status.
const DeliveryStatus = enum(u1) {
    /// There is currently no activity for this interrupt source, or the previous interrupt from this source was
    /// delivered to the processor core and accepted.
    idle = 0,

    /// Indicates that an interrupt from this source has been delivered to the processor core but has not yet been
    /// accepted.
    send_pending = 1,
};

/// Specifies the type of interrupt to be sent to the processor.
///
/// Some delivery modes will only operate as intended when used in conjunction with a specific trigger mode.
const DeliveryMode = enum(u3) {
    /// Delivers the interrupt specified in the vector field.
    fixed = 0b000,

    /// Delivers an SMI interrupt to the processor core through the processor’s local SMI signal path.
    ///
    /// When using this delivery mode, the vector field should be set to 00H for future compatibility.
    smi = 0b010,

    /// Delivers an NMI interrupt to the processor.
    ///
    /// The vector information is ignored.
    nmi = 0b100,

    /// Delivers an INIT request to the processor core, which causes the processor to perform an INIT.
    ///
    /// When using this delivery mode, the vector field should be set to 00H for future compatibility.
    ///
    /// Not supported for the LVT CMCI register, the LVT thermal monitor register, or the LVT performance counter
    /// register.
    init = 0b101,

    /// Causes the processor to respond to the interrupt as if the interrupt originated in an externally connected
    /// (8259A-compatible) interrupt controller.
    ///
    /// A special INTA bus cycle corresponding to ExtINT, is routed to the external controller.
    ///
    /// The external controller is expected to supply the vector information.
    ///
    /// The APIC architecture supports only one ExtINT source in a system, usually contained in the compatibility bridge.
    ///
    /// Only one processor in the system should have an LVT entry configured to use the ExtINT delivery mode.
    ///
    /// Not supported for the LVT CMCI register, the LVT thermal monitor register, or the LVT performance counter
    /// register.
    ext_int = 0b111,

    _,
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
