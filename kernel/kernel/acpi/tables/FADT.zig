// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

/// The Fixed ACPI Description Table (FADT) defines various fixed hardware ACPI information vital to an ACPI-compatible
/// OS, such as the base address for the following hardware registers blocks:
///  - PM1a_EVT_BLK
///  - PM1b_EVT_BLK
///  - PM1a_CNT_BLK
///  - PM1b_CNT_BLK
///  - PM2_CNT_BLK
///  - PM_TMR_BLK
///  - GPE0_BLK
///  - GPE1_BLK.
///
/// The FADT also has a pointer to the DSDT that contains the Differentiated Definition Block, which in turn provides
/// variable information to an ACPI-compatible OS concerning the base system design.
///
/// All fields in the FADT that provide hardware addresses provide processor-relative physical addresses.
///
/// [ACPI 6.5 Specification Link](https://uefi.org/specs/ACPI/6.5/05_ACPI_Software_Programming_Model.html#fixed-acpi-description-table-fadt)
pub const FADT = extern struct {
    header: acpi.tables.SharedHeader align(1),

    /// Physical memory address of the FACS, where OSPM and Firmware exchange control information.
    ///
    /// If the `X_FIRMWARE_CTRL` field contains a non zero value which can be used by the OSPM, then this field must be
    /// ignored by the OSPM.
    ///
    /// If the `hardware_reduced_acpi` flag is set, and both this field and the `X_FIRMWARE_CTRL` field are zero, there
    /// is no FACS available.
    FIRMWARE_CTRL: u32 align(1),

    /// Physical memory address of the DSDT.
    ///
    /// If the `X_DSDT` field contains a non-zero value which can be used by the OSPM, then this field must be ignored
    /// by the OSPM.
    ///
    /// Use `getDSDT` to get the DSDT.
    _DSDT: u32 align(1),

    /// ACPI 1.0 defined this offset as a field named `int_model`, which was eliminated in ACPI 2.0.
    ///
    /// Platforms should set this field to zero but field values of one are also allowed to maintain compatibility with
    /// ACPI 1.0.
    _reserved1: u8,

    /// This field is set by the OEM to convey the preferred power management profile to OSPM.
    ///
    /// OSPM can use this field to set default power management policy parameters during OS installation.
    preferred_pm_profile: PowerManagementProfile,

    /// System vector the SCI interrupt is wired to in 8259 mode.
    ///
    /// On systems that do not contain the 8259, this field contains the Global System interrupt number of the SCI
    /// interrupt.
    ///
    /// OSPM is required to treat the ACPI SCI interrupt as a shareable, level, active low interrupt
    SCI_INT: u16 align(1),

    /// System port address of the SMI Command Port.
    ///
    /// During ACPI OS initialization, OSPM can determine that the ACPI hardware registers are owned by SMI
    /// (by way of the `sci_en` bit), in which case the ACPI OS issues the `ACPI_ENABLE` command to the `SMI_CMD` port.
    ///
    /// The `sci_en` bit effectively tracks the ownership of the ACPI hardware registers.
    ///
    /// OSPM issues commands to the `SMI_CMD` port synchronously from the boot processor.
    ///
    /// This field is reserved and must be zero on system that does not support System Management mode.
    SMI_CMD: u32 align(1),

    /// The value to write to `SMI_CMD` to disable SMI ownership of the ACPI hardware registers.
    ///
    /// The last action SMI does to relinquish ownership is to set the `sci_en` bit.
    ///
    /// During the OS initialization process, OSPM will synchronously wait for the transfer of SMI ownership to
    /// complete, so the ACPI system releases SMI ownership as quickly as possible.
    ///
    /// This field is reserved and must be zero on systems that do not support Legacy Mode.
    ACPI_ENABLE: u8,

    /// The value to write to `SMI_CMD` to re-enable SMI ownership of the ACPI hardware registers.
    ///
    /// This can only be done when ownership was originally acquired from SMI by OSPM using `ACPI_ENABLE`.
    ///
    /// An OS can hand ownership back to SMI by relinquishing use to the ACPI hardware registers, masking off all SCI
    /// interrupts, clearing the `sci_en` bit and then writing `ACPI_DISABLE` to the `SMI_CMD` port from the boot
    /// processor.
    ///
    /// This field is reserved and must be zero on systems that do not support Legacy Mode.
    ACPI_DISABLE: u8,

    /// The value to write to `SMI_CMD` to enter the S4BIOS state.
    ///
    /// The S4BIOS state provides an alternate way to enter the S4 state where the firmware saves and restores the
    /// memory context.
    ///
    /// A value of zero in `FACS.flags.S4BIOS_F` indicates `S4BIOS_REQ` is not supported.
    S4BIOS_REQ: u8,

    /// If non-zero, this field contains the value OSPM writes to the `SMI_CMD` register to assume processor performance
    /// state control responsibility.
    PSTATE_CNT: u8,

    /// System port address of the PM1a Event Register Block.
    ///
    /// This is a required field.
    ///
    /// If the `X_PM1a_EVT_BLK` field contains a non zero value which can be used by the OSPM, then this field must be
    /// ignored by the OSPM.
    PM1a_EVT_BLK: u32 align(1),

    /// System port address of the PM1b Event Register Block.
    ///
    /// This field is optional; if this register block is not supported, this field contains zero.
    ///
    /// If the `X_PM1b_EVT_BLK` field contains a non zero value which can be used by the OSPM, then this field must be
    /// ignored by the OSPM.
    PM1b_EVT_BLK: u32 align(1),

    /// System port address of the PM1a Control Register Block.
    ///
    /// This is a required field.
    ///
    /// If the `X_PM1a_CNT_BLK` field contains a non zero value which can be used by the OSPM, then this field must be
    /// ignored by the OSPM.
    ///
    /// Use `getPM1a_CNT` to get the PM1a_CNT.
    _PM1a_CNT_BLK: u32 align(1),

    /// System port address of the PM1b Control Register Block.
    ///
    /// This field is optional; if this register block is not supported, this field contains zero.
    ///
    /// If the `X_PM1b_CNT_BLK` field contains a non zero value which can be used by the OSPM, then this field must be
    /// ignored by the OSPM.
    ///
    /// Use `getPM1b_CNT` to get the PM1b_CNT.
    _PM1b_CNT_BLK: u32 align(1),

    /// System port address of the PM2 Control Register Block.
    ///
    /// This field is optional; if this register block is not supported, this field contains zero.
    ///
    /// If the `X_PM2_CNT_BLK` field contains a non zero value which can be used by the OSPM, then this field must be
    /// ignored by the OSPM.
    PM2_CNT_BLK: u32 align(1),

    /// System port address of the Power Management Timer Control Register Block.
    ///
    /// This is an optional field; if this register block is not supported, this field contains zero.
    ///
    /// If the `X_PM_TMR_BLK` field contains a non zero value which can be used by the OSPM, then this field must be
    /// ignored by the OSPM.
    PM_TMR_BLK: u32 align(1),

    /// System port address of General-Purpose Event 0 Register Block.
    ///
    /// If this register block is not supported, this field contains zero.
    ///
    /// If the `X_GPE0_BLK` field contains a non zero value which can be used by the OSPM, then this field must be
    /// ignored by the OSPM.
    GPE0_BLK: u32 align(1),

    /// System port address of General-Purpose Event 1 Register Block.
    ///
    /// This is an optional field; if this register block is not supported, this field contains zero.
    ///
    /// If the `X_GPE1_BLK` field contains a non zero value which can be used by the OSPM, then this field must be
    /// ignored by the OSPM.
    GPE1_BLK: u32 align(1),

    /// Number of bytes decoded by PM1a_EVT_BLK and, if supported, PM1b_EVT_BLK.
    ///
    /// This value is >= 4.
    PM1_EVT_LEN: u8,

    /// Number of bytes decoded by PM1a_CNT_BLK and, if supported, PM1b_CNT_BLK.
    ///
    /// This value is >= 2.
    PM1_CNT_LEN: u8,

    /// Number of bytes decoded by PM2_CNT_BLK.
    ///
    /// Support for the PM2 register block is optional.
    ///
    /// If supported, this value is >= 1.
    ///
    /// If not supported, this field contains zero.
    PM2_CNT_LEN: u8,

    /// Number of bytes decoded by PM_TMR_BLK.
    ///
    /// If the PM Timer is supported, this field’s value must be 4.
    ///
    /// If not supported, this field contains zero.
    PM_TMR_LEN: u8,

    /// The length of the register whose address is given by `X_GPE0_BLK` (if nonzero) or by `GPE0_BLK` (otherwise) in
    /// bytes.
    ///
    /// The value is a non-negative multiple of 2.
    GPE0_BLK_LEN: u8,

    /// The length of the register whose address is given by `X_GPE1_BLK` (if nonzero) or by `GPE1_BLK` (otherwise) in
    /// bytes.
    ///
    /// The value is a non-negative multiple of 2.
    GPE1_BLK_LEN: u8,

    /// Offset within the ACPI general-purpose event model where GPE1 based events start.
    GPE1_BASE: u8,

    /// If non-zero, this field contains the value OSPM writes to the `SMI_CMD` register to indicate OS support for the
    /// _CST object and C States Changed notification.
    CST_CNT: u8,

    /// The worst-case hardware latency, in microseconds, to enter and exit a C2 state.
    ///
    /// A value > 100 indicates the system does not support a C2 state.
    P_LVL2_LAT: u16 align(1),

    /// The worst-case hardware latency, in microseconds, to enter and exit a C3 state.
    ///
    /// A value > 1000 indicates the system does not support a C3 state.
    P_LVL3_LAT: u16 align(1),

    /// If `WBINVD`=0, the value of this field is the number of flush strides that need to be read
    /// (using cacheable addresses) to completely flush dirty lines from any processor’s memory caches.
    ///
    /// Notice that the value in `FLUSH_STRIDE` is typically the smallest cache line width on any of the processor’s
    /// caches (for more information, see the `FLUSH_STRIDE` field definition).
    ///
    /// If the system does not support a method for flushing the processor’s caches, then `FLUSH_SIZE` and `WBINVD` are
    /// set to zero.
    ///
    /// Notice that this method of flushing the processor caches has limitations, and `WBINVD`=1 is the preferred way
    /// to flush the processors caches.
    ///
    /// This value is typically at least 2 times the cache size.
    ///
    /// The maximum allowed value for `FLUSH_SIZE` multiplied by `FLUSH_STRIDE` is 2 MB for a typical
    /// maximum supported cache size of 1 MB. Larger cache sizes are supported using `WBINVD`=1.
    ///
    /// This value is ignored if `WBINVD`=1.
    ///
    /// This field is maintained for ACPI 1.0 processor compatibility on existing systems.
    ///
    /// Processors in new ACPI-compatible systems are required to support the WBINVD function and indicate this to OSPM
    /// by setting the `WBINVD` field = 1.
    FLUSH_SIZE: u16 align(1),

    /// If `WBINVD`=0, the value of this field is the cache line width, in bytes, of the processor’s memory caches.
    ///
    /// This value is typically the smallest cache line width on any of the processor’s caches.
    ///
    /// For more information, see the description of the `FLUSH_SIZE` field.
    ///
    /// This value is ignored if `WBINVD`=1.
    ///
    /// This field is maintained for ACPI 1.0 processor compatibility on existing systems.
    ///
    /// Processors in new ACPI-compatible systems are required to support the WBINVD function and indicate this to OSPM
    /// by setting the `WBINVD` field = 1.
    FLUSH_STRIDE: u16 align(1),

    /// The zero-based index of where the processor’s duty cycle setting is within the processor’s P_CNT register.
    DUTY_OFFSET: u8,

    /// The bit width of the processor’s duty cycle setting value in the P_CNT register.
    ///
    /// Each processor’s duty cycle setting allows the software to select a nominal processor frequency below its
    /// absolute frequency as defined by:
    ///
    /// `THTL_EN = 1 BF * DC/(2DUTY_WIDTH)`
    ///
    /// Where:
    ///  - BF: Base frequency
    ///  - DC: Duty cycle setting
    ///
    /// When THTL_EN is 0, the processor runs at its absolute BF.
    ///
    /// A `DUTY_WIDTH` value of 0 indicates that processor duty cycle is not supported and the processor continuously
    /// runs at its base frequency.
    DUTY_WIDTH: u8,

    /// The RTC CMOS RAM index to the day-of-month alarm value.
    ///
    /// If this field contains a zero, then the RTC day of the month alarm feature is not supported.
    ///
    /// If this field has a non-zero value, then this field contains an index into RTC RAM space that OSPM can use to
    /// program the day of the month alarm.
    DAY_ALRM: u8,

    /// The RTC CMOS RAM index to the month of year alarm value.
    ///
    /// If this field contains a zero, then the RTC month of the year alarm feature is not supported.
    ///
    /// If this field has a non-zero value, then this field contains an index into RTC RAM space that OSPM can use to
    /// program the month of the year alarm.
    ///
    /// If this feature is supported, then the DAY_ALRM feature must be supported also.
    MON_ALRM: u8,

    /// The RTC CMOS RAM index to the century of data value (hundred and thousand year decimals).
    ///
    /// If this field contains a zero, then the RTC centenary feature is not supported.
    ///
    /// If this field has a non-zero value, then this field contains an index into RTC RAM space that OSPM can use to
    /// program the centenary field.
    CENTURY: u8,

    /// IA-PC Boot Architecture Flags.
    ///
    /// This set of flags is used by an OS to guide the assumptions it can make in initializing hardware on IA-PC
    /// platforms.
    ///
    /// These flags are used by an OS at boot time (before the OS is capable of providing an operating environment
    /// suitable for parsing the ACPI namespace) to determine the code paths to take during boot.
    ///
    /// In IA-PC platforms with reduced legacy hardware, the OS can skip code paths for legacy devices if none are
    /// present.
    ///
    /// For example, if there are no ISA devices, an OS could skip code that assumes the presence of these devices and
    /// their associated resources.
    ///
    /// These flags are used independently of the ACPI namespace.
    ///
    /// The presence of other devices must be described in the ACPI namespace.
    ///
    /// These flags pertain only to IA-PC platforms. On other system architectures, the entire field should be set to 0.
    IA_PC_BOOT_ARCH: IA_PC_ARCHITECHTURE_FLAGS align(1),

    _reserved2: u8,

    /// Fixed feature flags.
    fixed_feature_flags: FixedFeatureFlags align(1),

    /// The address of the reset register.
    ///
    /// Note: Only System I/O space, System Memory space and PCI Configuration space (bus #0) are valid for values for
    /// `address_space`.
    ///
    /// Also, `register_bit_width` must be 8 and `register_bit_offset` must be 0
    RESET_REG: acpi.Address align(1),

    /// Indicates the value to write to the `RESET_REG` port to reset the system.
    RESET_VALUE: u8,

    /// ARM Boot Architecture Flags.
    ARM_BOOT_ARCH: ARM_ARCHITECHTURE_FLAGS align(1),

    /// Minor Version of this FADT structure, in "Major.Minor" form, where 'Major' is the value in the
    /// `header.version` field.
    ///
    /// Bits 0-3 - The low order bits correspond to the minor version of the specification version.
    ///
    /// For instance, ACPI 6.3 has a major version of 6, and a minor version of 3.
    ///
    /// Bits 4-7 - The high order bits correspond to the version of the ACPI Specification errata this table complies
    /// with.
    ///
    /// A value of 0 means that it complies with the base version of the current specification.
    ///
    /// A value of 1 means this is compatible with Errata A, 2 would be compatible with Errata B, and so on.
    FADT_minor_version: u8,

    /// Extended physical address of the FACS.
    ///
    /// If this field contains a nonzero value which can be used by the OSPM, then the `FIRMWARE_CTRL` field must be
    /// ignored by the OSPM.
    ///
    /// If `fixed_feature_flags.HARDWARE_REDUCED_ACPI` flag is set, and both this field and the `FIRMWARE_CTRL` field
    /// are zero, there is no FACS available
    X_FIRMWARE_CTRL: core.PhysicalAddress align(1),

    /// Extended physical address of the DSDT.
    ///
    /// If this field contains a nonzero value which can be used by the OSPM, then the `DSDT` field must be ignored
    /// by the OSPM.
    ///
    /// Use `getDSDT` to get the DSDT.
    _X_DSDT: core.PhysicalAddress align(1),

    /// Extended address of the PM1a Event Register Block.
    ///
    /// This is a required field
    ///
    /// If this field contains a nonzero value which can be used by the OSPM, then the `PM1a_EVT_BLK` field must be
    /// ignored by the OSPM.
    X_PM1a_EVT_BLK: acpi.Address align(1),

    /// Extended address of the PM1b Event Register Block.
    ///
    /// This field is optional; if this register block is not supported, this field contains zero.
    ///
    /// If this field contains a nonzero value which can be used by the OSPM, then the `PM1b_EVT_BLK` field must be
    /// ignored by the OSPM
    X_PM1b_EVT_BLK: acpi.Address align(1),

    /// Extended address of the PM1a Control Register Block.
    ///
    /// This is a required field.
    ///
    /// If this field contains a nonzero value which can be used by the OSPM, then the `PM1a_CNT_BLK` field must be
    /// ignored by the OSPM.
    ///
    /// Use `getPM1a_CNT` to get the PM1a_CNT.
    _X_PM1a_CNT_BLK: acpi.Address align(1),

    /// Extended address of the PM1b Control Register Block.
    ///
    /// This field is optional; if this register block is not supported, this field contains zero.
    ///
    /// If this field contains a nonzero value which can be used by the OSPM, then the `PM1b_CNT_BLK` field must be
    /// ignored by the OSPM.
    ///
    /// Use `getPM1b_CNT` to get the PM1b_CNT.
    _X_PM1b_CNT_BLK: acpi.Address align(1),

    /// Extended address of the PM2 Control Register Block.
    ///
    /// This field is optional; if this register block is not supported, this field contains zero.
    ///
    /// If this field contains a nonzero value which can be used by the OSPM, then the `PM2_CNT_BLK` field must be
    /// ignored by the OSPM.
    X_PM2_CNT_BLK: acpi.Address align(1),

    /// Extended address of the Power Management Timer Control Register Block.
    ///
    /// This field is optional; if this register block is not supported, this field contains zero.
    ///
    /// If this field contains a nonzero value which can be used by the OSPM, then the `PM_TMR_BLK` field must be
    /// ignored by the OSPM.
    X_PM_TMR_BLK: acpi.Address align(1),

    /// Extended address of the General-Purpose Event 0 Register Block.
    ///
    /// This field is optional; if this register block is not supported, this field contains zero.
    ///
    /// If this field contains a nonzero value which can be used by the OSPM, then the `GPE0_BLK` field must be
    /// ignored by the OSPM.
    ///
    /// Note: Only System I/O space and System Memory space are valid for `address_space` values, and the OSPM ignores
    /// `register_bit_width`, `register_bit_offset` and `access_size`.
    X_GPE0_BLK: acpi.Address align(1),

    /// Extended address of the General-Purpose Event 1 Register Block.
    ///
    /// This field is optional; if this register block is not supported, this field contains zero.
    ///
    /// If this field contains a nonzero value which can be used by the OSPM, then the `GPE1_BLK` field must be
    /// ignored by the OSPM.
    ///
    /// Note: Only System I/O space and System Memory space are valid for `address_space` values, and the OSPM ignores
    /// `register_bit_width`, `register_bit_offset` and `access_size`.
    X_GPE1_BLK: acpi.Address align(1),

    /// The address of the Sleep register.
    ///
    /// Note: Only System I/O space, System Memory space and PCI Configuration space (bus #0) are valid for values for
    /// `address_space`.
    ///
    /// Also, `register_bit_width` must be 8 and `register_bit_offset` must be 0.
    SLEEP_CONTROL_REG: acpi.Address align(1),

    /// The address of the Sleep status register.
    ///
    /// Note: Only System I/O space, System Memory space and PCI Configuration space (bus #0) are valid for values for
    /// `address_space`.
    ///
    /// Also, `register_bit_width` must be 8 and `register_bit_offset` must be 0.
    SLEEP_STATUS_REG: acpi.Address align(1),

    /// 64-bit identifier of hypervisor vendor.
    ///
    /// All bytes in this field are considered part of the vendor identity.
    ///
    /// These identifiers are defined independently by the vendors themselves, usually following the name of the
    /// hypervisor product.
    ///
    /// Version information should NOT be included in this field - this shall simply denote the vendor's name or
    /// identifier.
    ///
    /// Version information can be communicated through a supplemental vendor-specific hypervisor API.
    ///
    /// Firmware implementers would place zero bytes into this field, denoting that no hypervisor is present in the
    /// actual firmware.
    hypervisor_vedor_identity: u64 align(1),

    pub const SIGNATURE_STRING = "FACP";

    /// Physical address of the DSDT.
    pub fn getDSDT(fadt: *const FADT) core.PhysicalAddress {
        return if (fadt._X_DSDT.value != 0) fadt._X_DSDT else core.PhysicalAddress.fromInt(fadt._DSDT);
    }

    /// Address of the PM1a Control Register Block.
    pub fn getPM1a_CNT(fadt: *const FADT) acpi.Address {
        return if (fadt._X_PM1a_CNT_BLK.address != 0)
            fadt._X_PM1a_CNT_BLK
        else
            .{ // FIXME: non-x86?
                .address_space = .io,
                .address = @intCast(fadt._PM1a_CNT_BLK),
                .register_bit_width = 16,
                .register_bit_offset = 0,
                .access_size = .undefined,
            };
    }

    /// Address of the PM1b Control Register Block.
    pub fn getPM1b_CNT(fadt: *const FADT) ?acpi.Address {
        return if (fadt._X_PM1b_CNT_BLK.address != 0)
            fadt._X_PM1b_CNT_BLK
        else if (fadt._PM1b_CNT_BLK != 0)
            .{ // FIXME: non-x86?
                .address_space = .io,
                .address = @intCast(fadt._PM1b_CNT_BLK),
                .register_bit_width = 16,
                .register_bit_offset = 0,
                .access_size = .undefined,
            }
        else
            null;
    }

    pub const PowerManagementProfile = enum(u8) {
        unspecified = 0,

        /// A single user, full featured, stationary computing device that resides on or near an individual’s work area.
        ///
        /// Most often contains one processor.
        ///
        /// Must be connected to AC power to function.
        ///
        /// This device is used to perform work that is considered mainstream corporate or home computing
        /// (for example, word processing, Internet browsing, spreadsheets, and so on).
        desktop = 1,

        /// A single-user, full-featured, portable computing device that is capable of running on batteries or other
        /// power storage devices to perform its normal functions.
        ///
        /// Most often contains one processor.
        ///
        /// This device performs the same task set as a desktop. However it may have limitations dues to its size,
        /// thermal requirements, and/or power source life.
        mobile = 2,

        /// A single-user, full-featured, stationary computing device that resides on or near an individual's work area.
        ///
        /// Often contains more than one processor.
        ///
        /// Must be connected to AC power to function.
        ///
        /// This device is used to perform large quantities of computations in support of such work as CAD/CAM and
        /// other graphics-intensive applications.
        workstation = 3,

        /// A multi-user, stationary computing device that frequently resides in a separate, often specially designed, room.
        ///
        /// Will almost always contain more than one processor.
        ///
        /// Must be connected to AC power to function.
        ///
        /// This device is used to support large-scale networking, database, communications, or financial
        /// operations within a corporation or government.
        enterprise_server = 4,

        /// A multi-user, stationary computing device that frequently resides in a separate area or room in a small or
        /// home office.
        ///
        /// May contain more than one processor.
        ///
        /// Must be connected to AC power to function.
        ///
        /// This device is generally used to support all of the networking, database, communications, and financial
        /// operations of a small office or home office.
        soho_server = 5,

        /// A device specifically designed to operate in a low-noise, high-availability environment such as a
        /// consumer's living rooms or family room.
        ///
        /// Most often contains one processor.
        ///
        /// This category also includes home Internet gateways, Web pads, set top boxes and other devices that support ACPI.
        ///
        /// Must be connected to AC power to function.
        ///
        /// Normally they are sealed case style and may only perform a subset of the tasks normally associated with
        /// today's personal computers
        appliance_pc = 6,

        /// A multi-user stationary computing device that frequently resides in a separate, often specially designed room.
        ///
        /// Will often contain more than one processor.
        ///
        /// Must be connected to AC power to function.
        ///
        /// This device is used in an environment where power savings features are willing to be sacrificed for
        /// better performance and quicker responsiveness
        performance_server = 7,

        /// A full-featured, highly mobile computing device which resembles writing tablets and which users interact
        /// with primarily through a touch interface.
        ///
        /// The touch digitizer is the primary user input device, although a keyboard and/or mouse may be present.
        ///
        /// Tablet devices typically run on battery power and are generally only plugged into AC power in order to charge.
        ///
        /// This device performs many of the same tasks as Mobile; however battery life expectations of Tablet devices
        /// generally require more aggressive power savings especially for managing display and touch components.
        tablet = 8,

        _,
    };

    pub const FixedFeatureFlags = packed struct(u32) {
        /// Processor properly implements a functional equivalent to the WBINVD IA-32 instruction.
        ///
        /// If set, signifies that the WBINVD instruction correctly flushes the processor caches, maintains memory
        /// coherency, and upon completion of the instruction, all caches for the current processor contain no
        /// cached data other than what OSPM references and allows to be cached.
        ///
        /// If this flag is not set, the ACPI OS is responsible for disabling all ACPI features that need this function.
        ///
        /// This field is maintained for ACPI 1.0 processor compatibility on existing systems.
        ///
        /// Processors in new ACPI-compatible systems are required to support this function and indicate this to OSPM
        /// by setting this field.
        WBINVD: bool,

        /// If set, indicates that the hardware flushes all caches on the WBINVD instruction and maintains memory
        /// coherency, but does not guarantee the caches are invalidated.
        ///
        /// This provides the complete semantics of the WBINVD instruction, and provides enough to support the
        /// system sleeping states.
        ///
        /// If neither of the WBINVD flags is set, the system will require FLUSH_SIZE and FLUSH_STRIDE to support
        /// sleeping states.
        ///
        /// If the FLUSH parameters are also not supported, the machine cannot support sleeping states S1, S2, or S3.
        WBINVD_FLUSH: bool,

        /// `true` indicates that the C1 power state is supported on all processors.
        PROC_C1: bool,

        /// A `false` indicates that the C2 power state is configured to only work on a uniprocessor (UP) system.
        ///
        /// A one indicates that the C2 power state is configured to work on a UP or multiprocessor (MP) system.
        P_LVL2_UP: bool,

        /// A `false` indicates the power button is handled as a fixed feature programming model; a `true` indicates
        /// the power button is handled as a control method device.
        ///
        /// If the system does not have a power button, this value would be `true` and no power button device would
        /// be present.
        ///
        /// Independent of the value of this field, the presence of a power button device in the namespace indicates
        /// to OSPM that the power button is handled as a control method device.
        PWR_BUTTON: bool,

        /// A `false` indicates the sleep button is handled as a fixed feature programming model; a `true` indicates
        /// the sleep button is handled as a control method device.
        ///
        /// If the system does not have a sleep button, this value would be `true` and no sleep button device would
        /// be present.
        ///
        /// Independent of the value of this field, the presence of a sleep button device in the namespace indicates
        /// to OSPM that the sleep button is handled as a control method device.
        SLP_BUTTON: bool,

        /// A `false` indicates the RTC wake status is supported in fixed register space; a `true` indicates the RTC
        /// wake status is not supported in fixed register space.
        FIX_RTC: bool,

        /// Indicates whether the RTC alarm function can wake the system from the S4 state.
        ///
        /// The RTC must be able to wake the system from an S1, S2, or S3 sleep state.
        ///
        /// The RTC alarm can optionally support waking the system from the S4 state, as indicated by this value.
        RTC_S4: bool,

        /// A `false` indicates TMR_VAL is implemented as a 24-bit value.
        ///
        /// A `true` indicates TMR_VAL is implemented as a 32-bit value.
        ///
        /// The TMR_STS bit is set when the most significant bit of the TMR_VAL toggles
        TMR_VAL_EXT: bool,

        /// A `false` indicates that the system cannot support docking.
        ///
        /// A `true` indicates that the system can support docking.
        ///
        /// Notice that this flag does not indicate whether or not a docking station is currently present;
        /// it only indicates that the system is capable of docking.
        DCK_CAP: bool,

        /// If set, indicates the system supports system reset via the FADT RESET_REG.
        RESET_REG_SUP: bool,

        /// System Type Attribute.
        ///
        /// If set indicates that the system has no internal expansion capabilities and the case is sealed.
        SEALED_CASE: bool,

        /// System Type Attribute.
        ///
        /// If set indicates the system cannot detect the monitor or keyboard / mouse devices.
        HEADLESS: bool,

        /// If set, indicates to OSPM that a processor native instruction must be executed after writing
        /// the SLP_TYPx register.
        CPU_SW_SLP: bool,

        /// If set, indicates the platform supports the PCI-EXP_WAKE_STS bit in the PM1 Status register and the
        /// PCIEXP_WAKE_EN bit in the PM1 Enable register.
        ///
        /// This bit must be set on platforms containing chipsets that implement PCI Express and supports PM1 PCIEXP_WAK bits.
        PCI_EXP_WAK: bool,

        /// A value of `true` indicates that OSPM should use a platform provided timer to drive any monotonically
        /// non-decreasing counters, such as OSPM performance counter services.
        ///
        /// Which particular platform timer will be used is OSPM specific, however, it is recommended that the timer
        /// used is based on the following algorithm: If the HPET is exposed to OSPM, OSPM should use the HPET.
        /// Otherwise, OSPM will use the ACPI power management timer.
        ///
        /// A value of `true` indicates that the platform is known to have a correctly implemented ACPI power management
        /// timer.
        ///
        /// A platform may choose to set this flag if a internal processor clock (or clocks in a multi-processor
        /// configuration) cannot provide consistent monotonically non-decreasing counters.
        ///
        /// Note: If a value of `false` is present, OSPM may arbitrarily choose to use an internal processor clock or a
        /// platform timer clock for these operations. That is, a `false` does not imply that OSPM will necessarily use
        /// the internal processor clock to generate a monotonically non-decreasing counter to the system.
        USE_PLATFORM_CLOCK: bool,

        /// A `true` indicates that the contents of the RTC_STS flag is valid when waking the system from S4.
        ///
        /// Some existing systems do not reliably set this input today, and this bit allows OSPM to differentiate
        /// correctly functioning platforms from platforms with this errata.
        S4_RTC_STS_VALID: bool,

        /// A `true` indicates that the platform is compatible with remote power-on.
        ///
        /// That is, the platform supports OSPM leaving GPE wake events armed prior to an S5 transition.
        ///
        /// Some existing platforms do not reliably transition to S5 with wake events enabled (for example, the
        /// platform may immediately generate a spurious wake event after completing the S5 transition).
        ///
        /// This flag allows OSPM to differentiate correctly functioning platforms from platforms with this type of errata.
        REMOTE_POWER_ON_CAPABLE: bool,

        /// A `true` indicates that all local APICs must be configured for the cluster destination model when delivering
        /// interrupts in logical mode.
        ///
        /// If this bit is set, then logical mode interrupt delivery operation may be undefined until OSPM has moved all
        /// local APICs to the cluster model.
        ///
        /// Note that the cluster destination model doesn’t apply to Itanium Processor Family (IPF) local SAPICs.
        ///
        /// This bit is intended for xAPIC based machines that require the cluster destination model even when 8 or
        /// fewer local APICs are present in the machine.
        FORCE_APIC_CLUSTER_MODEL: bool,

        /// A `true` indicates that all local xAPICs must be configured for physical destination mode.
        ///
        /// If this bit is set, interrupt delivery operation in logical destination mode is undefined.
        ///
        /// On machines that contain fewer than 8 local xAPICs or that do not use the xAPIC architecture, this bit is ignored.
        FORCE_APIC_PHYSICAL_DESTINATION_MODE: bool,

        /// A one indicates that the Hardware-Reduced ACPI is implemented, therefore software-only alternatives are used
        /// for supported fixed-features.
        HW_REDUCED_ACPI: bool,

        /// A `true` informs OSPM that the platform is able to achieve power savings in S0 similar to or better than
        /// those typically achieved in S3.
        ///
        /// In effect, when this bit is set it indicates that the system will achieve no power benefit by making a sleep
        /// transition to S3.
        LOW_POWER_S0_IDLE_CAPABLE: bool,

        /// Described whether cpu caches and any other caches that are coherent with them, are considered by the
        /// platform to be persistent.
        ///
        /// The platform evaluates the configuration present at system startup to determine this value.
        ///
        /// System configuration changes after system startup may invalidate this.
        PERSISTENT_CPU_CACHES: PersistentCpuCaches,

        _reserved: u8,

        pub const PersistentCpuCaches = enum(u2) {
            /// Not reported by the platform.
            ///
            /// Software should reference the NFIT Platform Capabilities.
            not_supported = 0b00,

            /// Cpu caches and any other caches that are coherent with them, are not persistent.
            ///
            /// Software is responsible for flushing data from cpu caches to make stores persistent.
            ///
            /// Supersedes NFIT Platform Capabilities.
            not_persistent = 0b01,

            /// Cpu caches and any other caches that are coherent with them, are persistent.
            ///
            /// Supersedes NFIT Platform Capabilities.
            ///
            /// When reporting this state, the platform shall provide enough stored energy for ALL of the following:
            ///  - Time to flush cpu caches and any other caches that are coherent with them
            ///  - Time of all targets of those flushes to complete flushing stored data
            ///  - If supporting hot plug, the worst case CXL device topology that can be hotplugged
            persistent = 0b10,

            reserved = 0b11,
        };
    };

    pub const IA_PC_ARCHITECHTURE_FLAGS = packed struct(u16) {
        /// If set, indicates that the motherboard supports user-visible devices on the LPC or ISA bus.
        ///
        /// User-visible devices are devices that have end-user accessible connectors (for example, LPT port), or
        /// devices for which the OS must load a device driver so that an end-user application can use a device.
        ///
        /// If clear, the OS may assume there are no such devices and that all devices in the system can be detected
        /// exclusively via industry standard device enumeration mechanisms (including the ACPI namespace).
        LEGACY_DEVICES: bool,

        /// If set, indicates that the motherboard contains support for a port 60 and 64 based keyboard controller,
        /// usually implemented as an 8042 or equivalent micro-controller.
        @"8042": bool,

        /// If set, indicates to OSPM that it must not blindly probe the VGA hardware
        /// (that responds to MMIO addresses A0000h-BFFFFh and IO ports 3B0h-3BBh and 3C0h-3DFh) that may cause machine
        /// check on this system.
        ///
        /// If clear, indicates to OSPM that it is safe to probe the VGA hardware
        vga_not_present: bool,

        /// If set, indicates to OSPM that it must not enable Message Signaled Interrupts (MSI) on this platform.
        msi_not_supported: bool,

        /// If set, indicates to OSPM that it must not enable OSPM ASPM control on this platform.
        pcie_aspm_controls: bool,

        /// If set, indicates that the CMOS RTC is either not implemented, or does not exist at the legacy addresses.
        ///
        /// OSPM uses the Control Method Time and Alarm Namespace device instead.
        cmos_rtc_not_present: bool,

        _reserved: u10,
    };

    pub const ARM_ARCHITECHTURE_FLAGS = packed struct(u16) {
        /// `true` if PSCI is implemented.
        PSCI_COMPLIANT: bool,

        /// `true` if HVC must be used as the PSCI conduit, instead of SMC.
        PSCI_USE_HVC: bool,

        _reserved: u14,
    };

    comptime {
        core.testing.expectSize(FADT, 276);
    }
};

const core = @import("core");
const std = @import("std");
const kernel = @import("kernel");
const acpi = kernel.acpi;
