// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const core = @import("core");
const cascade = @import("cascade");
const Task = cascade.Task;
const acpi = cascade.acpi;
const addr = cascade.addr;

/// The Multiple APIC Description Table (MADT), provides OSPM with information necessary for operation on systems with
/// APIC, SAPIC, GIC, or LPIC implementations.
///
/// The ACPI interrupt model describes all interrupts for the entire system in a uniform interrupt model implementation.
///
/// Supported interrupt models include:
///  - the PC-AT-compatible dual 8259 interrupt controller
///  - for Intel processor-based systems: the Intel Advanced Programmable Interrupt Controller (APIC) and Intel
///    Streamlined Advanced Programmable Interrupt
///  - for ARM processor-based systems: the Generic Interrupt Controller (GIC)
///  - for LoongArch processor-based systems: the LoongArch Programmable Interrupt Controller (LPIC)
///
/// The choice of interrupt model(s) to support is up to the platform designer.
///
/// The interrupt model cannot be dynamically changed by system firmware; OSPM will choose which model to use and
/// install support for that model at the time of installation.
///
/// If a platform supports multiple models, an OS will install support for only one of the models and will not mix models.
///
/// Multi-boot capability is a feature in many modern operating systems.
///
/// This means that a system may have multiple operating systems or multiple instances of an OS installed at any one
/// time. Platform designers must allow for this.
///
///
/// ACPI represents all interrupts as "flat" values known as global system interrupts.
///
/// Therefore to support APICs, SAPICs, GICs, or LPICs on an ACPI-enabled system, each used interrupt input must be
/// mapped to the global system interrupt value used by ACPI.
///
/// Additional support is required to handle various multi-processor functions that implementations might support
/// (for example, identifying each processor's local interrupt controller ID).
///
/// All addresses in the MADT are processor-relative physical addresses.
///
/// [ACPI 6.5 Specification Link](https://uefi.org/specs/ACPI/6.5/05_ACPI_Software_Programming_Model.html#multiple-apic-description-table-madt)
pub const MADT = extern struct {
    header: acpi.tables.SharedHeader align(1),

    /// The 32-bit physical address at which each processor can access its local interrupt controller.
    local_interrupt_controller_address: u32 align(1),

    /// Multiple APIC flags.
    flags: MultipleAPICFlags align(1),

    /// Start of the list of interrupt controller structures for this implementation.
    ///
    /// This list will contain all of the structures from Interrupt Controller Structure Types needed to support
    /// this platform.
    ///
    /// Use `iterate` to iterate over the list of interrupt controller structures.
    _interrupt_controller_structures_start: u8,

    pub const SIGNATURE_STRING = "APIC";

    /// [ACPI 6.5 Specification Link](https://uefi.org/specs/ACPI/6.5/05_ACPI_Software_Programming_Model.html#multiple-apic-flags)
    pub const MultipleAPICFlags = packed struct(u32) {
        /// A `true` indicates that the system also has a PC-AT-compatible dual-8259 setup.
        ///
        /// The 8259 vectors must be disabled (that is, masked) when enabling the ACPI APIC operation.
        PCAT_COMPAT: bool,

        _reserved: u31,
    };

    /// Interrupt Controller Structure
    pub const InterruptControllerEntry = extern struct {
        /// Type of the interrupt controller structure.
        entry_type: Type align(1),

        /// Length of the interrupt controller structure.
        length: u8 align(1),

        /// The specific data for this type of interrupt controller structure.
        specific: Specific align(1),

        /// [ACPI 6.5 Specification Link](https://uefi.org/specs/ACPI/6.5/05_ACPI_Software_Programming_Model.html#interrupt-controller-structure-types)
        pub const Type = enum(u8) {
            processor_local_apic = 0x0,
            io_apic = 0x1,
            interrupt_source_override = 0x2,
            non_maskable_interrupt_source = 0x3,
            local_apic_nmi = 0x4,
            local_apic_address_override = 0x5,
            io_sapic = 0x6,
            local_sapic = 0x7,
            platform_interrupt_sources = 0x8,
            processor_local_x2apic = 0x9,
            local_x2apic_nmi = 0xa,
            gic_cpu_interface = 0xb,
            gic_distributor = 0xc,
            gic_msi_frame = 0xd,
            gic_redistributor = 0xe,
            gic_interrupt_translation_service = 0xf,
            multiprocessor_wakeup = 0x10,
            core_programmable_interrupt_controller = 0x11,
            legacy_io_programmable_interrupt_controller = 0x12,
            hypertransport_programmable_interrupt_controller = 0x13,
            extend_io_programmable_interrupt_controller = 0x14,
            msi_programmable_interrupt_controller = 0x15,
            bridge_io_programmable_interrupt_controller = 0x16,
            low_pin_count_programmable_interrupt_controller = 0x17,

            _,
        };

        pub const Specific = extern union {
            processor_local_apic: ProcessorLocalAPIC,
            io_apic: IOAPIC,
            interrupt_source_override: InterruptSourceOverride,
            non_maskable_interrupt_source: NonMaskableInterruptSource,
            local_apic_nmi: LocalAPICNonMaskableInterrupt,
            local_apic_address_override: LocalAPICAddressOverride,
            io_sapic: IOSAPIC,
            local_sapic: LocalSAPIC,
            platform_interrupt_sources: PlatformInterruptSources,
            processor_local_x2apic: ProcessorLocalX2APIC,
            local_x2apic_nmi: LocalX2APICNonMaskableInterrupt,
            gic_cpu_interface: GIC_CPUInterface,
            gic_distributor: GIC_Distributor,
            gic_msi_frame: GIC_MSIFrame,
            gic_redistributor: GIC_Redistributor,
            gic_interrupt_translation_service: GIC_InterruptTranslationService,
            multiprocessor_wakeup: MultiprocessorWakeup,
            core_programmable_interrupt_controller: CoreProgrammableInterruptController,
            legacy_io_programmable_interrupt_controller: LegacyIOProgrammableInterruptController,
            hypertransport_programmable_interrupt_controller: HyperTransportProgrammableInterruptController,
            extend_io_programmable_interrupt_controller: ExtendIOProgrammableInterruptController,
            msi_programmable_interrupt_controller: MSIProgrammableInterruptController,
            bridge_io_programmable_interrupt_controller: BridgeIOProgrammableInterruptController,
            low_pin_count_programmable_interrupt_controller: LowPinCountProgrammableInterruptController,
        };

        /// When using the APIC interrupt model, each processor in the system is required to have a Processor Local
        /// APIC record in the MADT, and a processor device object in the DSDT.
        ///
        /// OSPM does not expect the information provided in this table to be updated if the processor information
        /// changes during the lifespan of an OS boot.
        ///
        /// While in the sleeping state, processors are not allowed to be added, removed, nor can their APIC ID or
        /// Flags change.
        ///
        /// When a processor is not present, the Processor Local APIC information is either not reported or flagged as disabled.
        ///
        /// [ACPI 6.5 Specification Link](https://uefi.org/specs/ACPI/6.5/05_ACPI_Software_Programming_Model.html#processor-local-apic-structure)
        pub const ProcessorLocalAPIC = extern struct {
            /// The OS associates this Local APIC Structure with a processor object in the namespace when the _UID
            /// child object of the processor's device object (or the ProcessorId listed in the Processor declaration
            /// operator) evaluates to a numeric value that matches the numeric value in this field.
            ///
            /// Note that the use of the Processor declaration operator is deprecated.
            acpi_processor_uid: u8,

            /// The processor's local APIC ID.
            apic_id: u8,

            /// Local APIC Flags.
            flags: APICFlags align(1),

            comptime {
                core.testing.expectSize(ProcessorLocalAPIC, .from(6, .byte));
            }
        };

        /// In an APIC implementation, there are one or more I/O APICs.
        ///
        /// Each I/O APIC has a series of interrupt inputs, referred to as INTIn, where the value of n is from 0 to the
        /// number of the last interrupt input on the I/O APIC.
        ///
        /// The I/O APIC structure declares which global system interrupts are uniquely associated with the I/O APIC
        /// interrupt inputs.
        ///
        /// There is one I/O APIC structure for each I/O APIC in the system.
        ///
        /// [ACPI 6.5 Specification Link](https://uefi.org/specs/ACPI/6.5/05_ACPI_Software_Programming_Model.html#i-o-apic-structure)
        pub const IOAPIC = extern struct {
            /// The I/O APIC's ID.
            ioapic_id: u8,

            _reserved: u8,

            /// The 32-bit physical address to access this I/O APIC.
            ///
            /// Each I/O APIC resides at a unique address.
            ioapic_address: u32 align(1),

            /// The global system interrupt number where this I/O APIC's interrupt inputs start.
            ///
            /// The number of interrupt inputs is determined by the I/O APIC's Max Redir Entry register.
            global_system_interrupt_base: u32 align(1),

            comptime {
                core.testing.expectSize(IOAPIC, .from(10, .byte));
            }
        };

        /// Interrupt Source Overrides are necessary to describe variances between the IA-PC standard dual 8259
        /// interrupt definition and the platform's implementation.
        ///
        /// It is assumed that the ISA interrupts will be identity-mapped into the first I/O APIC sources. Most existing
        /// APIC designs, however, will contain at least one exception to this assumption.
        ///
        /// The Interrupt Source Override Structure is provided in order to describe these exceptions.
        ///
        /// It is not necessary to provide an Interrupt Source Override for every ISA interrupt. Only those that are not
        /// identity-mapped onto the APIC interrupt inputs need be described.
        ///
        /// This specification only supports overriding ISA interrupt sources.
        ///
        /// For example, if your machine has the ISA Programmable Interrupt Timer (PIT) connected to ISA IRQ 0, but in
        /// APIC mode, it is connected to I/O APIC interrupt input 2, then you would need an Interrupt Source Override
        /// where the source entry is '0' and the Global System Interrupt is '2'.
        ///
        /// [ACPI 6.5 Specification Link](https://uefi.org/specs/ACPI/6.5/05_ACPI_Software_Programming_Model.html#interrupt-source-override-structure)
        pub const InterruptSourceOverride = extern struct {
            /// 0 Constant, meaning ISA
            bus: u8,

            /// Bus-relative interrupt source (IRQ)
            source: u8,

            /// The Global System Interrupt that this bus-relative interrupt source will signal.
            global_system_interrupt: u32 align(1),

            /// MPS INTI flags
            flags: MPS_INIT_Flags align(1),

            comptime {
                core.testing.expectSize(InterruptSourceOverride, .from(8, .byte));
            }
        };

        /// This structure allows a platform designer to specify which I/O (S)APIC interrupt inputs should be enabled as
        /// non-maskable.
        ///
        /// Any source that is non-maskable will not be available for use by devices.
        ///
        /// [ACPI 6.5 Specification Link](https://uefi.org/specs/ACPI/6.5/05_ACPI_Software_Programming_Model.html#non-maskable-interrupt-nmi-source-structure)
        pub const NonMaskableInterruptSource = extern struct {
            /// MPS INTI flags
            flags: MPS_INIT_Flags align(1),

            /// The Global System Interrupt that this NMI will signal.
            global_system_interrupt: u32 align(1),

            comptime {
                core.testing.expectSize(NonMaskableInterruptSource, .from(6, .byte));
            }
        };

        /// This structure describes the Local APIC interrupt input (LINTn) that NMI is connected to for each of the
        /// processors in the system where such a connection exists.
        ///
        /// This information is needed by OSPM to enable the appropriate local APIC entry.
        ///
        /// Each Local APIC NMI connection requires a separate Local APIC NMI structure.
        ///
        /// For example, if the platform has 4 processors with ID 0-3 and NMI is connected LINT1 for processor 3 and 2,
        /// two Local APIC NMI entries would be needed in the MADT.
        ///
        /// [ACPI 6.5 Specification Link](https://uefi.org/specs/ACPI/6.5/05_ACPI_Software_Programming_Model.html#local-apic-nmi-structure)
        pub const LocalAPICNonMaskableInterrupt = extern struct {
            /// Value corresponding to the _UID listed in the processor's device object, or the Processor ID
            /// corresponding to the ID listed in the processor object.
            ///
            /// A value of 0xFF signifies that this applies to all processors in the machine.
            ///
            /// Note that the use of the Processor declaration operator is deprecated.
            acpi_processor_uid: u8,

            /// MPS INTI flags
            flags: MPS_INIT_Flags align(1),

            /// Local APIC interrupt input LINTn to which NMI is connected.
            local_apic_lintN: u8,

            comptime {
                core.testing.expectSize(LocalAPICNonMaskableInterrupt, .from(4, .byte));
            }
        };

        /// This optional structure supports 64-bit systems by providing an override of the physical address of the
        /// local APIC in the MADT's table header, which is defined as a 32-bit field.
        ///
        /// If defined, OSPM must use the address specified in this structure for all local APICs (and local SAPICs),
        /// rather than the address contained in the MADT's table header. Only one Local APIC Address Override Structure
        /// may be defined.
        ///
        /// [ACPI 6.5 Specification Link](https://uefi.org/specs/ACPI/6.5/05_ACPI_Software_Programming_Model.html#local-apic-address-override-structure)
        pub const LocalAPICAddressOverride = extern struct {
            _reserved: u16 align(1),

            /// Physical address of Local APIC.
            ///
            /// For Itanium™ Processor Family (IPF)-based platforms, this field contains the starting address of the
            /// Processor Interrupt Block.
            ///
            /// See the Intel® ItaniumTM Architecture Software Developer's Manual for more information.
            local_apic_address: addr.Physical align(1),

            comptime {
                core.testing.expectSize(LocalAPICAddressOverride, .from(10, .byte));
            }
        };

        /// The I/O SAPIC structure is very similar to the I/O APIC structure.
        ///
        /// If both I/O APIC and I/O SAPIC structures exist for a specific APIC ID, the information in the I/O SAPIC
        /// structure must be used.
        ///
        /// The I/O SAPIC structure uses the I/O APIC ID field as defined in the I/O APIC table.
        ///
        /// The Global System Interrupt Base field remains unchanged but has been moved.
        ///
        /// The I/O APIC Address field has been deleted. A new address and reserved field have been added.
        ///
        /// [ACPI 6.5 Specification Link](https://uefi.org/specs/ACPI/6.5/05_ACPI_Software_Programming_Model.html#i-o-sapic-structure)
        pub const IOSAPIC = extern struct {
            /// I/O SAPIC ID
            ioapic_id: u8,

            _reserved: u8,

            /// The global system interrupt number where this I/O SAPIC's interrupt inputs start.
            ///
            /// The number of interrupt inputs is determined by the I/O SAPIC's Max Redir Entry register.
            global_system_interrupt_base: u32 align(1),

            /// The 64-bit physical address to access this I/O SAPIC.
            ///
            /// Each I/O SAPIC resides at a unique address.
            iosapic_address: addr.Physical align(1),

            comptime {
                core.testing.expectSize(IOSAPIC, .from(14, .byte));
            }
        };

        /// The Processor local SAPIC structure is very similar to the processor local APIC structure.
        ///
        /// When using the SAPIC interrupt model, each processor in the system is required to have a Processor Local
        /// SAPIC record in the MADT, and a processor device object in the DSDT.
        ///
        /// OSPM does not expect the information provided in this table to be updated if the processor information
        /// changes during the lifespan of an OS boot.
        ///
        /// While in the sleeping state, processors are not allowed to be added, removed, nor can their SAPIC ID or
        /// Flags change.
        ///
        /// When a processor is not present, the Processor Local SAPIC information is either not reported or flagged as disabled.
        ///
        /// [ACPI 6.5 Specification Link](https://uefi.org/specs/ACPI/6.5/05_ACPI_Software_Programming_Model.html#local-sapic-structure)
        pub const LocalSAPIC = extern struct {
            /// OSPM associates the Local SAPIC Structure with a processor object declared in the namespace using the
            /// Processor statement by matching the processor object's ProcessorID value with this field.
            ///
            /// The use of the Processor statement is deprecated.
            acpi_processor_uid: u8,

            /// The processor's local SAPIC ID
            local_sapic_id: u8,

            /// The processor's local SAPIC EID
            local_sapic_eid: u8,

            _reserved: u8,

            /// Local SAPIC flags
            flags: APICFlags align(1),

            /// OSPM associates the Local SAPIC Structure with a processor object declared in the namespace using the
            /// Device statement, when the _UID child object of the processor device evaluates to a numeric value,
            /// by matching the numeric value with this field.
            acpi_processor_uid_value: u32 align(1),

            /// OSPM associates the Local SAPIC Structure with a processor object declared in the namespace using the
            /// Device statement, when the _UID child object of the processor device evaluates to a string, by matching
            /// the string with this field.
            ///
            /// This value is stored as a null-terminated ASCII string.
            _acpi_processor_uid_string_start: u8,

            pub fn acpiProcessorUidString(local_sapic: *const LocalSAPIC) [:0]const u8 {
                const ptr: [*:0]const u8 = @ptrCast(&local_sapic._acpi_processor_uid_string_start);
                return std.mem.sliceTo(ptr, 0);
            }

            comptime {
                core.testing.expectSize(LocalSAPIC, .from(13, .byte));
            }
        };

        /// The Platform Interrupt Source structure is used to communicate which I/O SAPIC interrupt inputs are
        /// connected to the platform interrupt sources.
        ///
        /// Platform Management Interrupts (PMIs) are used to invoke platform firmware to handle various events
        /// (similar to SMI in IA-32).
        ///
        /// The Intel® ItaniumTM architecture permits the I/O SAPIC to send a vector value in the interrupt message of
        /// the PMI type. This value is specified in the I/O SAPIC Vector field of the Platform Interrupt Sources Structure.
        ///
        /// INIT messages cause processors to soft reset.
        ///
        /// If a platform can generate an interrupt after correcting platform errors (e.g., single bit error correction),
        /// the interrupt input line used to signal such corrected errors is specified by the Global System Interrupt
        /// field in the following table.
        ///
        /// Some systems may restrict the retrieval of corrected platform error information to a specific processor.
        ///
        /// In such cases, the firmware indicates the processor that can retrieve the corrected platform error
        /// information through the Processor ID and EID fields in the structure below.
        ///
        /// OSPM is required to program the I/O SAPIC redirection table entries with the Processor ID, EID values
        /// specified by the ACPI system firmware.
        ///
        /// On platforms where the retrieval of corrected platform error information can be performed on any processor,
        /// the firmware indicates this capability by setting the CPEI Processor Override flag in the Platform Interrupt
        ///  Source Flags field of the structure below.
        ///
        /// If the CPEI Processor Override Flag is set, OSPM uses the processor specified by Processor ID, and EID
        /// fields of the structure below only as a target processor hint and the error retrieval can be performed on
        /// any processor in the system. However, firmware is required to specify valid values in Processor ID, EID
        /// fields to ensure backward compatibility.
        ///
        /// If the CPEI Processor Override flag is clear, OSPM may reject a ejection request for the processor that is
        /// targeted for the corrected platform error interrupt.
        ///
        /// If the CPEI Processor Override flag is set, OSPM can retarget the corrected platform error interrupt to a
        /// different processor when the target processor is ejected.
        ///
        /// Note that the _MAT object can return a buffer containing Platform Interrupt Source Structure entries.
        /// It is allowed for such an entry to refer to a Global System Interrupt that is already specified by a
        /// Platform Interrupt Source Structure provided through the static MADT table, provided the value of platform
        /// interrupt source flags are identical.
        ///
        /// Refer to the ItaniumTM Processor Family System Abstraction Layer (SAL) Specification for details on handling
        /// the Corrected Platform Error Interrupt.
        ///
        /// [ACPI 6.5 Specification Link](https://uefi.org/specs/ACPI/6.5/05_ACPI_Software_Programming_Model.html#platform-interrupt-source-structure)
        pub const PlatformInterruptSources = extern struct {
            /// MPS INTI flags
            flags: MPS_INIT_Flags align(1),

            interrupt_type: InterruptType,

            /// Processor ID of destination.
            processor_id: u8,

            /// Processor EID of destination.
            processor_eid: u8,

            /// Value that OSPM must use to program the vector field of the I/O SAPIC redirection table entry for
            /// entries with the PMI interrupt type.
            io_sapic_vector: u8,

            /// The Global System Interrupt that this platform interrupt will signal.
            global_system_interrupt: u32 align(1),

            platform_interrupt_source_flags: PlatformInterruptSource align(1),

            pub const InterruptType = enum(u8) {
                pmi = 1,
                init = 2,
                corrected_platform_error_interrupt = 3,

                _,
            };

            pub const PlatformInterruptSource = packed struct(u32) {
                /// When set, indicates that retrieval of error information is allowed from any processor and OSPM is
                /// to use the information provided by the processor ID, EID fields of the Platform Interrupt Source
                /// Structure as a target processor hint.
                cpei_processor_override: bool,

                _reserved: u31,
            };

            comptime {
                core.testing.expectSize(PlatformInterruptSources, .from(14, .byte));
            }
        };

        /// The Processor X2APIC structure is very similar to the processor local APIC structure.
        ///
        /// When using the X2APIC interrupt model, logical processors are required to have a processor device object in
        /// the DSDT and must convey the processor's APIC information to OSPM using the Processor Local X2APIC structure.
        ///
        /// [Compatibility note] On some legacy OSes, Logical processors with APIC ID values less than 255 (whether in
        /// XAPIC or X2APIC mode) must use the Processor Local APIC structure to convey their APIC information to OSPM,
        /// and those processors must be declared in the DSDT using the Processor() keyword. Logical processors with
        /// APIC ID values 255 and greater must use the Processor Local x2APIC structure and be declared using the
        /// Device() keyword.
        ///
        /// OSPM does not expect the information provided in this table to be updated if the processor information
        /// changes during the lifespan of an OS boot.
        ///
        /// While in the sleeping state, logical processors must not be added or removed, nor can their X2APIC ID or
        /// x2APIC Flags change.
        ///
        /// When a logical processor is not present, the processor local X2APIC information is either not reported or flagged as disabled.
        ///
        /// [ACPI 6.5 Specification Link](https://uefi.org/specs/ACPI/6.5/05_ACPI_Software_Programming_Model.html#processor-local-x2apic-structure)
        pub const ProcessorLocalX2APIC = extern struct {
            _reserved: u16 align(1),

            /// The processor's local x2APIC ID.
            x2apic_id: u32 align(1),

            flags: APICFlags align(1),

            /// OSPM associates the X2APIC Structure with a processor object declared in the namespace using the Device
            /// statement, when the _UID child object of the processor device evaluates to a numeric value, by matching
            /// the numeric value with this field.
            acpi_processor_uid: u32 align(1),

            comptime {
                core.testing.expectSize(ProcessorLocalX2APIC, .from(14, .byte));
            }
        };

        /// The Local APIC NMI and Local x2APIC NMI structures describe the interrupt input (LINTn) that NMI is
        /// connected to for each of the logical processors in the system where such a connection exists.
        ///
        /// Each NMI connection to a processor requires a separate NMI structure.
        ///
        /// This information is needed by OSPM to enable the appropriate APIC entry.
        ///
        /// NMI connection to a logical processor with local x2APIC ID 255 and greater requires an X2APIC NMI structure.
        /// NMI connection to a logical processor with an x2APIC ID less than 255 requires a Local APIC NMI structure.
        ///
        /// For example, if the platform contains 8 logical processors with x2APIC IDs 0-3 and 256-259 and NMI is
        /// connected LINT1 for processor 3, 2, 256 and 257 then two Local APIC NMI entries and two X2APIC NMI entries
        /// must be provided in the MADT.
        ///
        /// The Local APIC NMI structure is used to specify global LINTx for all processors if all logical processors
        /// have x2APIC ID less than 255.
        ///
        /// If the platform contains any logical processors with an x2APIC ID of 255 or greater then the Local X2APIC
        /// NMI structure must be used to specify global LINTx for ALL logical processors.
        ///
        /// [ACPI 6.5 Specification Link](https://uefi.org/specs/ACPI/6.5/05_ACPI_Software_Programming_Model.html#local-x2apic-nmi-structure)
        pub const LocalX2APICNonMaskableInterrupt = extern struct {
            /// MPS INTI flags
            flags: MPS_INIT_Flags align(1),

            /// UID corresponding to the ID listed in the processor Device object.
            ///
            /// A value of 0xFFFFFFFF signifies that this applies to all processors in the machine.
            acpi_processor_uid: u32 align(1),

            /// Local x2APIC interrupt input LINTn to which NMI is connected.
            local_x2apic_lintN: u8,

            _reserved1: u8,
            _reserved2: u16 align(1),

            comptime {
                core.testing.expectSize(LocalX2APICNonMaskableInterrupt, .from(10, .byte));
            }
        };

        /// In the GIC interrupt model, logical processors are required to have a Processor Device object in the DSDT,
        /// and must convey each processor's GIC information to the OS using the GICC structure.
        ///
        /// [ACPI 6.5 Specification Link](https://uefi.org/specs/ACPI/6.5/05_ACPI_Software_Programming_Model.html#gic-cpu-interface-gicc-structure)
        pub const GIC_CPUInterface = extern struct {
            _reserved1: u16 align(1),

            /// GIC's CPU Interface Number.
            ///
            /// In GICv1/v2 implementations, this value matches the bit index of the associated processor in the GIC
            /// distributor's GICD_ITARGETSR register.
            ///
            /// For GICv3/4 implementations this field must be provided by the platform, if compatibility mode is
            /// supported.
            ///
            /// If it is not supported by the implementation, then this field must be zero.
            cpu_interface_number: u32 align(1),

            /// The OS associates this GICC Structure with a processor device object in the namespace when the _UID
            /// child object of the processor device evaluates to a numeric value that matches the numeric value in this
            /// field.
            acpi_processor_uid: u32 align(1),

            flags: GIC_Flags align(1),

            /// Version of the ARM-Processor Parking Protocol implemented.
            ///
            /// See http://uefi.org/acpi, the document link is listed under "Multiprocessor Startup for ARM Platforms"
            ///
            /// For systems that support PSCI exclusively and do not support the parking protocol, this field must be
            /// set to 0.
            parking_protocol_version: u32 align(1),

            /// The GSIV used for Performance Monitoring Interrupts.
            performance_interrupt_gsiv: u32 align(1),

            /// The 64-bit physical address of the processor's Parking Protocol mailbox.
            parked_address: addr.Physical align(1),

            /// On GICv1/v2 systems and GICv3/4 systems in GICv2 compatibility mode, this field holds the 64-bit
            /// physical address at which the processor can access this GIC CPU Interface.
            ///
            /// If provided here, the "Local Interrupt Controller Address" field in the MADT must be ignored by the OSPM.
            physical_base_address: addr.Physical align(1),

            /// Address of the GIC virtual CPU interface registers.
            ///
            /// If the platform is not presenting a GICv2 with virtualization extensions this field can be 0.
            gicv: addr.Physical align(1),

            /// Address of the GIC virtual interface control block registers.
            ///
            /// If the platform is not presenting a GICv2 with virtualization extensions this field can be 0.
            gich: addr.Physical align(1),

            /// GSIV for Virtual GIC maintenance interrupt
            vgic_maintenance_interrupt: u32 align(1),

            /// On systems supporting GICv3 and above, this field holds the 64-bit physical address of the associated
            /// Redistributor.
            ///
            /// If all of the GIC Redistributors are in the always-on power domain, GICR structures should be used to
            /// describe the Redistributors instead, and this field must be set to 0.
            ///
            /// If a GICR structure is present in the MADT then this field must be ignored by the OSPM.
            gicr_base_address: addr.Physical align(1),

            /// This fields follows the MPIDR formatting of ARM architecture.
            ///
            /// If ARMv7 architecture is used then the format must be as follows:
            ///  - Bits [63:24] Must be zero
            ///  - Bits [23:16] Aff2 : Match Aff2 of target processor MPIDR
            ///  - Bits [15:8] Aff1 : Match Aff1 of target processor MPIDR
            ///  - Bits [7:0] Aff0 : Match Aff0 of target processor MPIDR
            ///
            /// For platforms implementing ARMv8 the format must be:
            ///  - Bits [63:40] Must be zero
            ///  - Bits [39:32] Aff3 : Match Aff3 of target processor MPIDR
            ///  - Bits [31:24] Must be zero
            ///  - Bits [23:16] Aff2 : Match Aff2 of target processor MPIDR
            ///  - Bits [15:8] Aff1 : Match Aff1 of target processor MPIDR
            ///  - Bits [7:0] Aff0 : Match Aff0 of target processor MPIDR
            mpidr: u64 align(1),

            /// Describes the relative power efficiency of the associated processor.
            ///
            /// Lower efficiency class numbers are more efficient than higher ones (e.g. efficiency class 0 should be
            /// treated as more efficient than efficiency class 1).
            ///
            /// However, absolute values of this number have no meaning: 2 isn't necessarily half as efficient as 1.
            processor_power_efficency_class: u8,

            _reserved2: u8,

            /// Statistical Profiling Extension buffer overflow GSIV.
            ///
            /// This interrupt is a level triggered PPI.
            ///
            /// Zero if SPE is not supported by this processor.
            spe_overflow_interrupt: u16 align(1),

            /// Trace Buffer Extension interrupt GSIV.
            ///
            /// This interrupt is a level triggered PPI.
            ///
            /// Zero if TRBE feature is not supported by this processor.
            ///
            /// NOTE: This field was introduced in ACPI Specification version 6.5.
            trbe_interrupt: u16 align(1),

            pub const GIC_Flags = packed struct(u32) {
                /// If this bit is set, the processor is ready for use.
                ///
                /// If this bit is clear and the `online_capable` bit is set, the system supports enabling this processor
                /// during OS runtime.
                ///
                /// If this bit is clear and the `online_capable` bit is also clear, this processor is unusable, and the
                /// operating system support will not attempt to use it.
                enabled: bool,

                performance_interrupt_mode: InterruptMode,

                vgic_maintenance_interrupt_mode: InterruptMode,

                /// The information conveyed by this bit depends on the value of the `enabled` bit.
                ///
                /// If the `enabled` bit is set, this bit is reserved and must be zero.
                ///
                /// Otherwise, if this bit is set, the system supports enabling this processor later during OS runtime.
                online_capable: bool,

                _reserved: u28,

                pub const InterruptMode = enum(u1) {
                    level_triggered = 0,
                    edge_triggered = 1,
                };
            };

            comptime {
                core.testing.expectSize(GIC_CPUInterface, .from(80, .byte));
            }
        };

        /// ACPI represents all wired interrupts as "flat" values known as global system interrupts (GSIVs).
        ///
        /// On ARM-based systems the Generic Interrupt Controller (GIC) manages interrupts on the system.
        ///
        /// Each interrupt is identified in the GIC by an interrupt identifier (INTID).
        ///
        /// ACPI GSIVs map one to one to GIC INTIDs for peripheral interrupts, whether shared (SPI) or private (PPI).
        ///
        /// The GIC distributor structure describes the GIC distributor to the OS.
        ///
        /// One, and only one, GIC distributor structure must be present in the MADT for an ARM based system.
        ///
        /// [ACPI 6.5 Specification Link](https://uefi.org/specs/ACPI/6.5/05_ACPI_Software_Programming_Model.html#gic-distributor-gicd-structure)
        pub const GIC_Distributor = extern struct {
            _reserved1: u16 align(1),

            /// This GIC Distributor's hardware ID
            gic_id: u32 align(1),

            /// The 64-bit physical address for this Distributor
            physical_base_address: addr.Physical align(1),

            /// Reserved - Must be zero
            system_vector_base: u32 align(1),

            gic_version: Version,

            _reserved2: u8,
            _reserved3: u16 align(1),

            pub const Version = enum(u8) {
                /// No GIC version is specified, fall back to hardware discovery for GIC version
                unspecified = 0x00,

                /// GICv1
                gicv1 = 0x01,

                /// GICv2
                gicv2 = 0x02,

                /// GICv3
                gicv3 = 0x03,

                /// GICv4
                gicv4 = 0x04,

                _,
            };

            comptime {
                core.testing.expectSize(GIC_Distributor, .from(22, .byte));
            }
        };

        /// Each GICv2m MSI frame consists of a 4k page which includes registers to generate message signaled interrupts
        /// to an associated GIC distributor.
        ///
        /// The frame also includes registers to discover the set of distributor lines which may be signaled by MSIs
        /// from that frame.
        ///
        /// A system may have multiple MSI frames, and separate frames may be defined for secure and non-secure access.
        /// This structure must only be used to describe non-secure MSI frames.
        ///
        /// [ACPI 6.5 Specification Link](https://uefi.org/specs/ACPI/6.5/05_ACPI_Software_Programming_Model.html#gic-msi-frame-structure)
        pub const GIC_MSIFrame = extern struct {
            _reserved1: u16 align(1),

            /// GIC MSI Frame ID.
            ///
            /// In a system with multiple GIC MSI frames, this value must be unique to each one.
            gic_msi_frame_id: u32 align(1),

            /// The 64-bit physical address for this MSI Frame.
            physical_base_address: addr.Physical align(1),

            /// Reserved - Must be zero
            flags: u32 align(1),

            /// SPI Count used by this frame.
            ///
            /// Unless the `flags.spi_count_base_select == .override` this value should match the lower 16 bits of the
            /// MSI_TYPER register in the frame.
            spi_count: u16 align(1),

            /// SPI Base used by this frame.
            ///
            /// Unless the `flags.spi_count_base_select == .override` this value should match the upper 16 bits of the
            /// MSI_TYPER register in the frame.
            spi_base: u16 align(1),

            pub const GIC_MSIFrame_Flags = packed struct(u32) {
                spi_count_base_select: enum(u1) {
                    /// The SPI Count and Base fields should be ignored, and the actual values should be queried from
                    /// the MSI_TYPER register in the associated GIC MSI frame.
                    ignore = 0,

                    /// The SPI Count and Base values override the values specified in the MSI_TYPER register in the
                    /// associated GIC MSI frame.
                    override = 1,
                },

                _reserved: u31,
            };

            comptime {
                core.testing.expectSize(GIC_MSIFrame, .from(22, .byte));
            }
        };

        /// This structure enables the discovery of GIC Redistributor base addresses by providing the Physical Base
        /// Address of a page range containing the GIC Redistributors.
        ///
        /// More than one GICR Structure may be presented in the MADT.
        ///
        /// GICR structures should only be used when describing GIC implementations which conform to version 3 or higher
        ///  of the GIC architecture and which place all Redistributors in the always-on power domain.
        ///
        /// When a GICR structure is presented, the OSPM must ignore the GICR Base Address field of the GICC structures.
        ///
        /// [ACPI 6.5 Specification Link](https://uefi.org/specs/ACPI/6.5/05_ACPI_Software_Programming_Model.html#gic-redistributor-gicr-structure)
        pub const GIC_Redistributor = extern struct {
            _reserved: u16 align(1),

            /// The 64-bit physical address of a page range containing all GIC Redistributors.
            discovery_range_base_address: addr.Physical align(1),

            /// Length of the GIC Redistributor Discovery page range.
            discovery_range_length: u32 align(1),

            comptime {
                core.testing.expectSize(GIC_Redistributor, .from(14, .byte));
            }
        };

        /// The GIC ITS is optionally supported in GICv3/v4 implementations.
        ///
        /// [ACPI 6.5 Specification Link](https://uefi.org/specs/ACPI/6.5/05_ACPI_Software_Programming_Model.html#gic-interrupt-translation-service-its-structure)
        pub const GIC_InterruptTranslationService = extern struct {
            _reserved1: u16 align(1),

            /// GIC ITS ID.
            ///
            /// In a system with multiple GIC ITS units, this value must be unique to each one.
            gic_its_id: u32 align(1),

            /// The 64-bit physical address for the Interrupt Translation Service.
            physical_base_address: addr.Physical align(1),

            _reserved2: u32 align(1),

            comptime {
                core.testing.expectSize(GIC_InterruptTranslationService, .from(18, .byte));
            }
        };

        /// The platform firmware publishes a multiprocessor wakeup structure to let the bootstrap processor wake up
        /// application processors with a mailbox.
        ///
        /// The mailbox is memory that the firmware reserves so that each processor can have the OS send a message to
        /// them.
        ///
        /// During system boot, the firmware puts the application processors in a state to check the mailbox.
        ///
        /// The shared mailbox is a 4K-aligned 4K-size memory block allocated by the firmware in the ACPINvs memory.
        ///
        /// The firmware is not allowed to modify the mailbox location when the firmware transfer the control to an OS
        /// loader.
        ///
        /// The mailbox is broken down into two 2KB sections: an OS section and a firmware section.
        ///
        /// The OS section can only be written by OS and read by the firmware, except the command field.
        /// The application processor need clear the command to Noop(0) as the acknowledgement that the command is
        /// received.
        /// The firmware must cache the content in the mailbox which might be used later before clear the command such
        /// as WakeupVector.
        /// Only after the command is changed to Noop(0), the OS can send the next command.
        /// The firmware section must be considered read-only to the OS and is only to be written to by the firmware.
        /// All data communication between the OS and FW must be in little endian format.
        ///
        /// The OS section contains command, flags, APIC ID, and a wakeup address.
        /// After the OS detects the processor number from the MADT table, the OS may prepare the wakeup routine, fill
        /// the wakeup address field in the mailbox, indicate which processor need to be wakeup in the APID ID field,
        /// and send wakeup command.
        /// Once an application processor detects the wakeup command and its own APIC ID, the application processor will
        /// jump to the OS-provided wakeup address.
        /// The application processor will ignore the command if the APIC ID does not match its own.
        ///
        /// For each application processor, the mailbox can be used only once for the wakeup command.
        /// After the application process takes the action according to the command, this mailbox will no longer be
        /// checked by this application processor. Other processors can continue using the mailbox for the next command.
        ///
        /// [ACPI 6.5 Specification Link](https://uefi.org/specs/ACPI/6.5/05_ACPI_Software_Programming_Model.html#multiprocessor-wakeup-structure)
        pub const MultiprocessorWakeup = extern struct {
            /// Version of the mailbox.
            ///
            /// 0 for this version of the spec.
            mailbox_version: u16 align(1),

            _reserved: u32 align(1),

            /// Physical address of the mailbox.
            ///
            /// It must be in ACPINvs.
            ///
            /// It must also be 4K bytes aligned.
            mailbox_address: addr.Physical align(1),

            comptime {
                core.testing.expectSize(MultiprocessorWakeup, .from(14, .byte));
            }
        };

        /// Each processor in Loongarch system has a Core Programmable Interrupt Controller record in the MADT, and a
        /// processor device object in the DSDT.
        ///
        /// [ACPI 6.5 Specification Link](https://uefi.org/specs/ACPI/6.5/05_ACPI_Software_Programming_Model.html#core-programmable-interrupt-controller-core-pic-structure)
        pub const CoreProgrammableInterruptController = extern struct {
            version: Version,

            /// The OS associates this CORE PIC Structure with a processor device object in the namespace when the
            /// _UID child object of the processor device evaluates to a numeric value that matches the numeric value
            /// in this field.
            acpi_processor_id: u32 align(1),

            /// The processor core physical id.
            ///
            /// 0xFFFFFFFF is invalid value.
            ///
            /// If invalid, this processor is unusable, and OSPM shall ignore Core Interrupt Controller Structure.
            physical_processor_id: u32 align(1),

            flags: CorePICFlags align(1),

            pub const Version = enum(u8) {
                invalid = 0,
                core_pic_v1 = 1,

                _,
            };

            pub const CorePICFlags = packed struct(u32) {
                /// If Physical Processor ID is invalid, OSPM shall ignore this field, and OSPM shall ignore Core
                /// Programmable Interrupt Controller Structure.
                ///
                /// If Physical Processor ID is valid and if this Enabled bit is clear, this processor will be unusable
                /// on booting, and can be online during OS runtime.
                ///
                /// If Physical Processor ID is valid and if this Enabled bit is set, this processor is ready for using.
                enabled: bool,

                _reserved: u31,
            };

            comptime {
                core.testing.expectSize(CoreProgrammableInterruptController, .from(13, .byte));
            }
        };

        /// In early Loongson CPUs, Legacy I/O Programmable Interrupt Controller (LIO PIC) routes interrupts from HT PIC
        /// to CORE PIC.
        ///
        /// [ACPI 6.5 Specification Link](https://uefi.org/specs/ACPI/6.5/05_ACPI_Software_Programming_Model.html#legacy-i-o-programmable-interrupt-controller-lio-pic-structure)
        pub const LegacyIOProgrammableInterruptController = extern struct {
            version: Version,

            /// The base address of LIO PIC registers.
            base_address: addr.Physical align(1),

            /// The register space size of LIO PIC.
            size: u16 align(1),

            /// This field described routed vectors on CORE PIC from LIO PIC vectors.
            cascade_vector: u16 align(1),

            /// This field described the vectors of LIO PIC routed to the related vector of parent specified by Cascade
            /// vector field.
            cascade_vector_mapping: addr.Physical align(1),

            pub const Version = enum(u8) {
                invalid = 0,
                lio_pic_v1 = 1,

                _,
            };

            comptime {
                core.testing.expectSize(LegacyIOProgrammableInterruptController, .from(21, .byte));
            }
        };

        /// In early Loongson CPUs, HT Programmable Interrupt Controller (HT PIC) routes interrupts from BIO PIC and
        /// MSI PIC to LIO PIC.
        ///
        /// [ACPI 6.5 Specification Link](https://uefi.org/specs/ACPI/6.5/05_ACPI_Software_Programming_Model.html#hypertransport-programmable-interrupt-controller-ht-pic-structure)
        pub const HyperTransportProgrammableInterruptController = extern struct {
            version: Version,

            /// The base address of HT PIC registers.
            base_address: addr.Physical align(1),

            /// The register space size of HT PIC.
            size: u16 align(1),

            /// This field described routed vectors on LIO PIC from HT PIC vectors.
            cascade_vector: addr.Physical align(1),

            pub const Version = enum(u8) {
                invalid = 0,
                ht_pic_v1 = 1,

                _,
            };

            comptime {
                core.testing.expectSize(HyperTransportProgrammableInterruptController, .from(19, .byte));
            }
        };

        /// In newer generation Loongson CPUs, Extend I/O Programmable Interrupt Controller (EIO PIC) replaces
        /// the combination of HT PIC and part of LIO PIC, and routes interrupts from BIO PIC and MSI PIC to CORE PIC
        /// directly.
        ///
        /// [ACPI 6.5 Specification Link](https://uefi.org/specs/ACPI/6.5/05_ACPI_Software_Programming_Model.html#extend-i-o-programmable-interrupt-controller-eio-pic-structure)
        pub const ExtendIOProgrammableInterruptController = extern struct {
            version: Version,

            /// This field describes routed vector on CORE PIC from EIO PIC vectors.
            cascade_vector: u8,

            /// The node ID of the node connected to bridge.
            node: u8,

            /// Each bit indicates one node that can receive interrupt routing from the EIO PIC.
            node_map: u64 align(1),

            pub const Version = enum(u8) {
                invalid = 0,
                eio_pic_v1 = 1,

                _,
            };

            comptime {
                core.testing.expectSize(ExtendIOProgrammableInterruptController, .from(11, .byte));
            }
        };

        /// MSI Programmable Interrupt Controller Structure is defined to support MSI of PCI/PCIE devices in system.
        ///
        /// [ACPI 6.5 Specification Link](https://uefi.org/specs/ACPI/6.5/05_ACPI_Software_Programming_Model.html#msi-programmable-interrupt-controller-msi-pic-structure)
        pub const MSIProgrammableInterruptController = extern struct {
            version: Version,

            /// The physical address for MSI.
            message_address: addr.Physical align(1),

            /// The start vector allocated for MSI from global vectors of HT PIC or EIO PIC.
            start: u32 align(1),

            /// The count of allocated vectors for MSI.
            count: u32 align(1),

            pub const Version = enum(u8) {
                invalid = 0,
                msi_pic_v1 = 1,

                _,
            };

            comptime {
                core.testing.expectSize(MSIProgrammableInterruptController, .from(17, .byte));
            }
        };

        /// BIO PIC (Bridge I/O Programmable Interrupt Controller) manages legacy IRQs of chipset devices, and routed them to HT PIC or EIO PIC.
        ///
        /// [ACPI 6.5 Specification Link](https://uefi.org/specs/ACPI/6.5/05_ACPI_Software_Programming_Model.html#bridge-i-o-programmable-interrupt-controller-bio-pic-structure)
        pub const BridgeIOProgrammableInterruptController = extern struct {
            version: Version,

            /// The base address of BIO PIC registers.
            base_address: addr.Physical align(1),

            /// The register space size of BIO PIC.
            size: u16 align(1),

            /// The hardware ID of BIO PIC.
            hardware_id: u16 align(1),

            /// The global system interrupt number from which this BIO PIC’s interrupt inputs start.
            ///
            /// For GSI of each interrupt input, GSI = GSI base + interrupt input vector of BIO PIC.
            gsi_base: u16 align(1),

            pub const Version = enum(u8) {
                invalid = 0,
                bio_pic_v1 = 1,

                _,
            };

            comptime {
                core.testing.expectSize(BridgeIOProgrammableInterruptController, .from(15, .byte));
            }
        };

        /// LPC PIC (Low Pin Count Programmable Interrupt Controller) is responsible for handling ISA IRQs of old legacy
        /// devices such as PS/2 mouse, keyboard and UARTs for Loongarch machines.
        ///
        /// [ACPI 6.5 Specification Link](https://uefi.org/specs/ACPI/6.5/05_ACPI_Software_Programming_Model.html#lpc-programmable-interrupt-controller-lpc-pic-structure)
        pub const LowPinCountProgrammableInterruptController = extern struct {
            version: Version,

            /// The base address of LPC PIC registers.
            base_address: addr.Physical align(1),

            /// The register space size of LPC PIC.
            size: u16 align(1),

            /// This field described routed vector on BIO PIC from LPC PIC vectors.
            cascade_vector: u16 align(1),

            pub const Version = enum(u8) {
                invalid = 0,
                lpc_pic_v1 = 1,

                _,
            };

            comptime {
                core.testing.expectSize(LowPinCountProgrammableInterruptController, .from(13, .byte));
            }
        };

        pub const APICFlags = packed struct(u32) {
            /// If this bit is set the processor is ready for use.
            ///
            /// If this bit is clear and the `online_capable` bit is set, system hardware supports enabling this
            /// processor during OS runtime.
            ///
            /// If this bit is clear and the `online_capable` bit is also clear, this processor is unusable, and OSPM
            /// shall ignore the contents of the Processor Local APIC Structure.
            enabled: bool,

            /// The information conveyed by this bit depends on the value of the `enabled` bit.
            ///
            /// If the `enabled` bit is set, this bit is reserved and must be zero.
            ///
            /// Otherwise, if this this bit is set, system hardware supports enabling this processor during OS runtime.
            online_capable: bool,

            _reserved: u30,
        };

        pub const MPS_INIT_Flags = packed struct(u16) {
            /// Polarity of the APIC I/O input signals.
            polarity: Polarity,

            /// Trigger mode of the APIC I/O Input signals.
            trigger_mode: TriggerMode,

            _reserved: u12,

            pub const Polarity = enum(u2) {
                /// Conforms to the specifications of the bus (for example, EISA is active-low for level-triggered interrupts).
                conforms = 0b00,

                /// Active high
                active_high = 0b01,

                /// Active Low
                active_low = 0b11,

                _,
            };

            pub const TriggerMode = enum(u2) {
                /// Conforms to specifications of the bus (For example, ISA is edge-triggered)
                conforms = 0b00,

                /// Edge-triggered
                edge_triggered = 0b01,

                /// Level-triggered
                level_triggered = 0b11,

                _,
            };
        };
    };

    pub fn iterate(madt: *const MADT) MADTIterator {
        return MADTIterator.init(madt);
    }

    pub const MADTIterator = struct {
        current_ptr: [*]const u8,
        end_ptr: [*]const u8,

        pub fn init(madt: *const MADT) MADTIterator {
            const start_ptr: [*]const u8 = @ptrCast(&madt._interrupt_controller_structures_start);
            const base_ptr: [*]const u8 = @ptrCast(madt);
            const end_ptr: [*]const u8 = base_ptr + madt.header.length;

            return .{
                .current_ptr = start_ptr,
                .end_ptr = end_ptr,
            };
        }

        pub fn next(madt_iterator: *MADTIterator) ?*const InterruptControllerEntry {
            if (@intFromPtr(madt_iterator.current_ptr) >= @intFromPtr(madt_iterator.end_ptr)) return null;

            const entry: *const InterruptControllerEntry = @ptrCast(madt_iterator.current_ptr);

            madt_iterator.current_ptr += entry.length;

            return entry;
        }
    };

    comptime {
        core.testing.expectSize(
            MADT,
            core.Size.of(acpi.tables.SharedHeader)
                .add(.of(MultipleAPICFlags))
                .add(.of(u32))
                .add(.from(1, .byte)),
        );
    }
};
