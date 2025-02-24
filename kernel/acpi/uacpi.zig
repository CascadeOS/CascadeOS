// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>
// SPDX-FileCopyrightText: 2022-2025 Daniil Tatianin (https://github.com/UltraOS/uACPI/blob/4ab3a78006a930e2cda5a92f33fc84e1ec6b4a3d/LICENSE)

//! Provides a nice zig API wrapping uACPI 2.0.0 (4ab3a78006a930e2cda5a92f33fc84e1ec6b4a3d).
//!
//! Most APIs are exposed with no loss of functionality, except for the following:
//! - `Node.eval*`/`Node.execute*` have a non-null `parent_node` parameter meaning root relative requires passing the
//!    root node.
//!

/// Set up early access to the table subsystem. What this means is:
/// - uacpi_table_find() and similar API becomes usable before the call to
///   uacpi_initialize().
/// - No kernel API besides logging and map/unmap will be invoked at this stage,
///   allowing for heap and scheduling to still be fully offline.
/// - The provided 'temporary_buffer' will be used as a temporary storage for the
///   internal metadata about the tables (list, reference count, addresses,
///   sizes, etc).
/// - The 'temporary_buffer' is replaced with a normal heap buffer allocated via
///   uacpi_kernel_alloc() after the call to uacpi_initialize() and can therefore
///   be reclaimed by the kernel.
///
/// The approximate overhead per table is 56 bytes, so a buffer of 4096 bytes
/// yields about 73 tables in terms of capacity. uACPI also has an internal
/// static buffer for tables, "UACPI_STATIC_TABLE_ARRAY_LEN", which is configured
/// as 16 descriptors in length by default.
pub fn setupEarlyTableAccess(temporary_buffer: []u8) !void {
    const ret: Status = @enumFromInt(c_uacpi.uacpi_setup_early_table_access(
        temporary_buffer.ptr,
        temporary_buffer.len,
    ));
    try ret.toError();
}

pub const InitalizeOptions = packed struct(u64) {
    /// Bad table checksum should be considered a fatal error (table load is fully aborted in this case)
    bad_checksum_fatal: bool = false,

    /// Unexpected table signature should be considered a fatal error (table load is fully aborted in this case)
    bad_table_signature_fatal: bool = false,

    /// Force uACPI to use RSDT even for later revisions
    bad_xsdt: bool = false,

    /// If this is set, ACPI mode is not entered during the call to `initialize`.
    ///
    /// The caller is expected to enter it later at their own discretion by using `enterAcpiMode`.
    no_acpi: bool = false,

    /// Don't create the \_OSI method when building the namespace.
    ///
    /// Only enable this if you're certain that having this method breaks your AML blob.
    no_osi: bool = false,

    /// Validate table checksums at installation time instead of first use.
    ///
    /// Note that this makes uACPI map the entire table at once, which not all hosts are able to handle at early init.
    proactive_table_checksum: bool = false,

    _reserved: u58 = 0,
};

/// Initializes the uACPI subsystem, iterates & records all relevant RSDT/XSDT tables.
///
/// Enters ACPI mode.
pub fn initialize(options: InitalizeOptions) !void {
    const ret: Status = @enumFromInt(c_uacpi.uacpi_initialize(
        @bitCast(options),
    ));
    try ret.toError();
}

/// Parses & executes all of the DSDT/SSDT tables.
///
/// Initializes the event subsystem.
pub fn namespaceLoad() !void {
    const ret: Status = @enumFromInt(c_uacpi.uacpi_namespace_load());
    try ret.toError();
}

/// Initializes all the necessary objects in the namespaces by calling _STA/_INI etc.
pub fn namespaceInitialize() !void {
    const ret: Status = @enumFromInt(c_uacpi.uacpi_namespace_initialize());
    try ret.toError();
}

pub const InitLevel = enum(c_uacpi.uacpi_init_level) {
    /// Reboot state, nothing is available
    early = c_uacpi.UACPI_INIT_LEVEL_EARLY,

    /// State after a successfull call to `initialize`.
    ///
    /// Table API and other helpers that don't depend on the ACPI namespace may be used.
    subsystem_initialized = c_uacpi.UACPI_INIT_LEVEL_SUBSYSTEM_INITIALIZED,

    /// State after a successfull call to `namespaceLoad`.
    ///
    /// Most API may be used, namespace can be iterated, etc.
    namespace_loaded = c_uacpi.UACPI_INIT_LEVEL_NAMESPACE_LOADED,

    /// The final initialization stage, this is entered after the call to `namespaceInitialize`.
    ///
    /// All API is available to use.
    namespace_initialized = c_uacpi.UACPI_INIT_LEVEL_NAMESPACE_INITIALIZED,
};

/// Returns the current subsystem initialization level
pub fn currentInitLevel() InitLevel {
    return @enumFromInt(c_uacpi.uacpi_get_current_init_level());
}

pub const Bitness = enum(u8) {
    @"32" = 32,
    @"64" = 64,
};

/// Get the bitness of the currently loaded AML code according to the DSDT.
pub fn getAmlBitness() !Bitness {
    var value: Bitness = undefined;
    const ret: Status = @enumFromInt(c_uacpi.uacpi_get_aml_bitness(
        @ptrCast(&value),
    ));
    try ret.toError();
    return value;
}

/// Helper for entering ACPI mode.
///
/// Note that ACPI mode is entered automatically during the call to `initialize`.
pub fn enterAcpiMode() !void {
    const ret: Status = @enumFromInt(c_uacpi.uacpi_enter_acpi_mode());
    try ret.toError();
}

/// Helper for leaving ACPI mode.
pub fn leaveAcpiMode() !void {
    const ret: Status = @enumFromInt(c_uacpi.uacpi_leave_acpi_mode());
    try ret.toError();
}

/// Attempt to acquire the global lock for 'timeout' milliseconds.
///
/// On success, the return value is a unique sequence number for the current acquire transaction.
///
/// This number is used for validation during release.
pub fn acquireGlobalLock(timeout: Timeout) !u32 {
    var seq: u32 = undefined;
    const ret: Status = @enumFromInt(c_uacpi.uacpi_acquire_global_lock(
        @intFromEnum(timeout),
        &seq,
    ));
    try ret.toError();
    return seq;
}

pub fn releaseGlobalLock(seq: u32) !void {
    const ret: Status = @enumFromInt(c_uacpi.uacpi_release_global_lock(seq));
    try ret.toError();
}

/// Reset the global uACPI state by freeing all internally allocated data structures & resetting any global variables.
///
/// After this call, uACPI must be re-initialized from scratch to be used again.
///
/// This is called by uACPI automatically if a fatal error occurs during a call to `initialize`/`namespaceLoad` etc.
/// in order to prevent accidental use of partially uninitialized subsystems.
pub fn acpiStateReset() void {
    c_uacpi.uacpi_state_reset();
}

pub const InterruptModel = enum(c_uacpi.uacpi_interrupt_model) {
    pic = c_uacpi.UACPI_INTERRUPT_MODEL_PIC,
    ioapic = c_uacpi.UACPI_INTERRUPT_MODEL_IOAPIC,
    iosapic = c_uacpi.UACPI_INTERRUPT_MODEL_IOSAPIC,
};

pub fn setInterruptModel(model: InterruptModel) !void {
    const ret: Status = @enumFromInt(c_uacpi.uacpi_set_interrupt_model(@intFromEnum(model)));
    try ret.toError();
}

/// Finalize GPE initialization by enabling all GPEs not configured for wake and having a matching AML handler detected.
///
/// This should be called after the kernel power managment subsystem has enumerated all of the devices, executing their
/// _PRW methods etc., and marking those it wishes to use for wake by calling `Node.setupGPEForWake` and
/// `Node.enableGPEForWake`
pub fn finializeGpeInitialization() !void {
    const ret: Status = @enumFromInt(c_uacpi.uacpi_finalize_gpe_initialization());
    try ret.toError();
}

/// Disable all GPEs currently set up on the system.
pub fn disableAllGPEs() !void {
    const ret: Status = @enumFromInt(c_uacpi.uacpi_disable_all_gpes());
    try ret.toError();
}

/// Enable all GPEs not marked as wake.
///
/// This is only needed after the system wakes from a shallow sleep state and is called automatically by wake code.
pub fn enableAllRuntimeGPEs() !void {
    const ret: Status = @enumFromInt(c_uacpi.uacpi_enable_all_runtime_gpes());
    try ret.toError();
}

/// Enable all GPEs marked as wake.
///
/// This is only needed before the system goes to sleep is called automatically by sleep code.
pub fn enableAllWakeGPEs() !void {
    const ret: Status = @enumFromInt(c_uacpi.uacpi_enable_all_wake_gpes());
    try ret.toError();
}

pub const InterfaceKind = enum(c_uacpi.uacpi_interface_kind) {
    vendor = c_uacpi.UACPI_INTERFACE_KIND_VENDOR,
    feature = c_uacpi.UACPI_INTERFACE_KIND_FEATURE,
    all = c_uacpi.UACPI_INTERFACE_KIND_ALL,
};

/// Install or uninstall an interface.
///
/// The interface kind is used for matching during interface enumeration in `bulkConfigureInterfaces`.
///
/// After installing an interface, all _OSI queries report it as supported.
pub fn installInterface(name: [:0]const u8, kind: InterfaceKind) !void {
    const ret: Status = @enumFromInt(c_uacpi.uacpi_install_interface(
        name.ptr,
        @intFromEnum(kind),
    ));
    try ret.toError();
}

pub fn uninstallInterface(name: [:0]const u8) !void {
    const ret: Status = @enumFromInt(c_uacpi.uacpi_uninstall_interface(
        name.ptr,
    ));
    try ret.toError();
}

/// Set a custom interface query (_OSI) handler.
///
/// This callback will be invoked for each _OSI query with the value passed in the _OSI, as well as whether the
/// interface was detected as supported.
///
/// The callback is able to override the return value dynamically or leave it untouched if desired (e.g. if it
/// simply wants to log something or do internal bookkeeping of some kind).
pub fn setInterfaceQueryHandler(handler: InterfaceHandler) !void {
    const ret: Status = @enumFromInt(c_uacpi.uacpi_set_interface_query_handler(
        makeInterfaceHandlerWrapper(handler),
    ));
    try ret.toError();
}

/// Set the firmware waking vector in FACS.
///
/// - 'addr32' is the real mode entry-point address
/// - 'addr64' is the protected mode entry-point address
pub fn setWakingVector(addr32: core.PhysicalAddress, addr64: core.PhysicalAddress) !void {
    const ret: Status = @enumFromInt(c_uacpi.uacpi_set_waking_vector(
        @bitCast(addr32),
        @bitCast(addr64),
    ));
    try ret.toError();
}

pub const SleepState = enum(c_uacpi.uacpi_sleep_state) {
    S0 = c_uacpi.UACPI_SLEEP_STATE_S0,
    S1 = c_uacpi.UACPI_SLEEP_STATE_S1,
    S2 = c_uacpi.UACPI_SLEEP_STATE_S2,
    S3 = c_uacpi.UACPI_SLEEP_STATE_S3,
    S4 = c_uacpi.UACPI_SLEEP_STATE_S4,
    S5 = c_uacpi.UACPI_SLEEP_STATE_S5,
};

/// Prepare for a given sleep state.
///
/// Must be caled with interrupts ENABLED.
pub fn prepareForSleep(state: SleepState) !void {
    const ret: Status = @enumFromInt(c_uacpi.uacpi_prepare_for_sleep_state(
        @intFromEnum(state),
    ));
    try ret.toError();
}

/// Enter the given sleep state after preparation.
///
/// Must be called with interrupts DISABLED.
pub fn sleep(state: SleepState) !void {
    const ret: Status = @enumFromInt(c_uacpi.uacpi_enter_sleep_state(
        @intFromEnum(state),
    ));
    try ret.toError();
}

/// Prepare to leave the given sleep state.
///
/// Must be called with interrupts DISABLED.
pub fn prepareForWake(state: SleepState) !void {
    const ret: Status = @enumFromInt(c_uacpi.uacpi_prepare_for_wake_from_sleep_state(
        @intFromEnum(state),
    ));
    try ret.toError();
}

/// Wake from the given sleep state.
///
/// Must be called with interrupts ENABLED.
pub fn wake(state: SleepState) !void {
    const ret: Status = @enumFromInt(c_uacpi.uacpi_wake_from_sleep_state(
        @intFromEnum(state),
    ));
    try ret.toError();
}

/// Attempt reset via the FADT reset register.
pub fn reboot() !void {
    const ret: Status = @enumFromInt(c_uacpi.uacpi_reboot());
    try ret.toError();
}

/// Read a GAS.
///
/// Prefer `mapGas` + `MappedGas.read`.
pub fn readGas(gas: *const acpi.Address) !u64 {
    var value: u64 = undefined;

    const ret: Status = @enumFromInt(c_uacpi.uacpi_gas_read(
        @ptrCast(gas),
        @ptrCast(&value),
    ));
    try ret.toError();

    return value;
}

/// Write a GAS.
///
/// Prefer `mapGas` + `MappedGas.write`.
pub fn writeGas(gas: *const acpi.Address, value: u64) !void {
    const ret: Status = @enumFromInt(c_uacpi.uacpi_gas_write(
        @ptrCast(gas),
        value,
    ));
    try ret.toError();
}

pub const MappedGas = opaque {
    /// Same as `readGas` but operates on a pre-mapped handle for faster access and/or ability to use in critical
    /// sections/irq contexts.
    pub fn read(self: *const MappedGas) !u64 {
        var value: u64 = undefined;

        const ret: Status = @enumFromInt(c_uacpi.uacpi_gas_read(
            @ptrCast(self),
            @ptrCast(&value),
        ));
        try ret.toError();

        return value;
    }

    /// Same as `writeGas` but operates on a pre-mapped handle for faster access and/or ability to use in critical
    /// sections/irq contexts.
    pub fn write(self: *const MappedGas, value: u64) !void {
        const ret: Status = @enumFromInt(c_uacpi.uacpi_gas_write(
            @ptrCast(self),
            value,
        ));
        try ret.toError();
    }

    pub fn unmap(self: *MappedGas) void {
        c_uacpi.uacpi_unmap_gas(@ptrCast(self));
    }
};

/// Map a GAS for faster access in the future.
///
/// The handle returned must be freed & unmapped using `MappedGas.unmap` when no longer needed.
pub fn mapGas(gas: *const acpi.Address) !*MappedGas {
    var mapped_gas: *MappedGas = undefined;

    const ret: Status = @enumFromInt(c_uacpi.uacpi_map_gas(
        @ptrCast(gas),
        @ptrCast(&mapped_gas),
    ));
    try ret.toError();

    return mapped_gas;
}

pub const InterfaceAction = enum(c_uacpi.uacpi_interface_action) {
    disable = c_uacpi.UACPI_INTERFACE_ACTION_DISABLE,
    enable = c_uacpi.UACPI_INTERFACE_ACTION_ENABLE,
};

/// Bulk interface configuration, used to disable or enable all interfaces that match 'kind'.
///
/// This is generally only needed to work around buggy hardware, for example if requested from the kernel command
/// line.
///
/// By default, all vendor strings (like "Windows 2000") are enabled, and all host features
/// (like "3.0 Thermal Model") are disabled.
pub fn bulkConfigureInterfaces(kind: InterfaceKind, action: InterfaceAction) !void {
    const ret: Status = @enumFromInt(c_uacpi.uacpi_bulk_configure_interfaces(
        @intFromEnum(action),
        @intFromEnum(kind),
    ));
    try ret.toError();
}

pub const VendorInterface = enum(c_uacpi.uacpi_vendor_interface) {
    none = c_uacpi.UACPI_VENDOR_INTERFACE_NONE,
    windows_2000 = c_uacpi.UACPI_VENDOR_INTERFACE_WINDOWS_2000,
    windows_xp = c_uacpi.UACPI_VENDOR_INTERFACE_WINDOWS_XP,
    windows_xp_sp1 = c_uacpi.UACPI_VENDOR_INTERFACE_WINDOWS_XP_SP1,
    windows_server_2003 = c_uacpi.UACPI_VENDOR_INTERFACE_WINDOWS_SERVER_2003,
    windows_xp_sp2 = c_uacpi.UACPI_VENDOR_INTERFACE_WINDOWS_XP_SP2,
    windows_server_2003_sp1 = c_uacpi.UACPI_VENDOR_INTERFACE_WINDOWS_SERVER_2003_SP1,
    windows_vista = c_uacpi.UACPI_VENDOR_INTERFACE_WINDOWS_VISTA,
    windows_server_2008 = c_uacpi.UACPI_VENDOR_INTERFACE_WINDOWS_SERVER_2008,
    windows_vista_sp1 = c_uacpi.UACPI_VENDOR_INTERFACE_WINDOWS_VISTA_SP1,
    windows_vista_sp2 = c_uacpi.UACPI_VENDOR_INTERFACE_WINDOWS_VISTA_SP2,
    windows_7 = c_uacpi.UACPI_VENDOR_INTERFACE_WINDOWS_7,
    windows_8 = c_uacpi.UACPI_VENDOR_INTERFACE_WINDOWS_8,
    windows_8_1 = c_uacpi.UACPI_VENDOR_INTERFACE_WINDOWS_8_1,
    windows_10 = c_uacpi.UACPI_VENDOR_INTERFACE_WINDOWS_10,
    windows_10_rs1 = c_uacpi.UACPI_VENDOR_INTERFACE_WINDOWS_10_RS1,
    windows_10_rs2 = c_uacpi.UACPI_VENDOR_INTERFACE_WINDOWS_10_RS2,
    windows_10_rs3 = c_uacpi.UACPI_VENDOR_INTERFACE_WINDOWS_10_RS3,
    windows_10_rs4 = c_uacpi.UACPI_VENDOR_INTERFACE_WINDOWS_10_RS4,
    windows_10_rs5 = c_uacpi.UACPI_VENDOR_INTERFACE_WINDOWS_10_RS5,
    windows_10_19h1 = c_uacpi.UACPI_VENDOR_INTERFACE_WINDOWS_10_19H1,
    windows_10_20h1 = c_uacpi.UACPI_VENDOR_INTERFACE_WINDOWS_10_20H1,
    windows_11 = c_uacpi.UACPI_VENDOR_INTERFACE_WINDOWS_11,
    windows_11_22h2 = c_uacpi.UACPI_VENDOR_INTERFACE_WINDOWS_11_22H2,
};

/// Returns the "latest" AML-queried _OSI vendor interface.
///
/// E.g. for the following AML code:
/// ```
///     _OSI("Windows 2021")
///     _OSI("Windows 2000")
/// ```
///
/// This function will return `VendorInterface.windows_11`, since this is the latest version of the interface the
/// code queried, even though the "Windows 2000" query came after "Windows 2021".
pub fn latestQueriedVendorInterface() VendorInterface {
    return @enumFromInt(c_uacpi.uacpi_latest_queried_vendor_interface());
}

pub const Register = enum(c_uacpi.uacpi_register) {
    pm1_sts = c_uacpi.UACPI_REGISTER_PM1_STS,
    pm1_en = c_uacpi.UACPI_REGISTER_PM1_EN,
    pm1_cnt = c_uacpi.UACPI_REGISTER_PM1_CNT,
    pm_tmr = c_uacpi.UACPI_REGISTER_PM_TMR,
    pm2_cnt = c_uacpi.UACPI_REGISTER_PM2_CNT,
    slp_cnt = c_uacpi.UACPI_REGISTER_SLP_CNT,
    spl_sts = c_uacpi.UACPI_REGISTER_SLP_STS,
    reset = c_uacpi.UACPI_REGISTER_RESET,
    smi_cmd = c_uacpi.UACPI_REGISTER_SMI_CMD,

    /// Read a register from FADT
    ///
    /// NOTE: write-only bits (if any) are cleared automatically
    pub fn read(self: Register) !u64 {
        var value: u64 = undefined;
        const ret: Status = @enumFromInt(c_uacpi.uacpi_read_register(
            @intFromEnum(self),
            @ptrCast(&value),
        ));
        try ret.toError();
        return value;
    }

    /// Write a register from FADT
    ///
    /// NOTE:
    /// - Preserved bits (if any) are preserved automatically
    /// - If a register is made up of two (e.g. PM1a and PM1b) parts, the input is written to both at the same time
    pub fn write(self: Register, value: u64) !void {
        const ret: Status = @enumFromInt(c_uacpi.uacpi_write_register(
            @intFromEnum(self),
            value,
        ));
        try ret.toError();
    }

    /// Write a register from FADT
    ///
    /// NOTE:
    /// - Preserved bits (if any) are preserved automatically
    /// - If a register is made up of two (e.g. PM1a and PM1b) parts, the input is written to both at the same time
    pub fn writeRegisters(self: Register, value1: u64, value2: u64) !void {
        const ret: Status = @enumFromInt(c_uacpi.uacpi_write_registers(
            @intFromEnum(self),
            value1,
            value2,
        ));
        try ret.toError();
    }
};

pub const RegisterField = enum(c_uacpi.uacpi_register_field) {
    tmr_sts = c_uacpi.UACPI_REGISTER_FIELD_TMR_STS,
    bm_sts = c_uacpi.UACPI_REGISTER_FIELD_BM_STS,
    gbl_sts = c_uacpi.UACPI_REGISTER_FIELD_GBL_STS,
    pwrbtn_sts = c_uacpi.UACPI_REGISTER_FIELD_PWRBTN_STS,
    slpbtn_sts = c_uacpi.UACPI_REGISTER_FIELD_SLPBTN_STS,
    rtc_sts = c_uacpi.UACPI_REGISTER_FIELD_RTC_STS,
    pciex_wake_sts = c_uacpi.UACPI_REGISTER_FIELD_PCIEX_WAKE_STS,
    hwr_wak_sts = c_uacpi.UACPI_REGISTER_FIELD_HWR_WAK_STS,
    wak_sts = c_uacpi.UACPI_REGISTER_FIELD_WAK_STS,
    tmr_en = c_uacpi.UACPI_REGISTER_FIELD_TMR_EN,
    gbl_en = c_uacpi.UACPI_REGISTER_FIELD_GBL_EN,
    pwrbtn_en = c_uacpi.UACPI_REGISTER_FIELD_PWRBTN_EN,
    slpbtn_en = c_uacpi.UACPI_REGISTER_FIELD_SLPBTN_EN,
    rtc_en = c_uacpi.UACPI_REGISTER_FIELD_RTC_EN,
    pciexp_wake_dis = c_uacpi.UACPI_REGISTER_FIELD_PCIEXP_WAKE_DIS,
    sci_en = c_uacpi.UACPI_REGISTER_FIELD_SCI_EN,
    bm_rld = c_uacpi.UACPI_REGISTER_FIELD_BM_RLD,
    gbl_rls = c_uacpi.UACPI_REGISTER_FIELD_GBL_RLS,
    slp_typ = c_uacpi.UACPI_REGISTER_FIELD_SLP_TYP,
    hwr_slp_typ = c_uacpi.UACPI_REGISTER_FIELD_HWR_SLP_TYP,
    slp_en = c_uacpi.UACPI_REGISTER_FIELD_SLP_EN,
    hwr_slp_en = c_uacpi.UACPI_REGISTER_FIELD_HWR_SLP_EN,
    arb_dis = c_uacpi.UACPI_REGISTER_FIELD_ARB_DIS,

    /// Read a field from a FADT register
    ///
    /// NOTE: The value is automatically masked and shifted down as appropriate,the client code doesn't have to do any
    /// bit manipulation. E.g. for a field at 0b???XX??? the returned value will contain just the 0bXX
    pub fn read(self: RegisterField) !u64 {
        var value: u64 = undefined;
        const ret: Status = @enumFromInt(c_uacpi.uacpi_read_register_field(
            @intFromEnum(self),
            @ptrCast(&value),
        ));
        try ret.toError();
        return value;
    }

    /// Write to a field of a FADT register
    ///
    /// NOTE: The value is automatically masked and shifted up as appropriate, the client code doesn't have to do any
    /// bit manipulation. E.g. for a field at 0b???XX??? the passed value should be just 0bXX
    pub fn write(self: RegisterField, value: u64) !void {
        const ret: Status = @enumFromInt(c_uacpi.uacpi_write_register_field(
            @intFromEnum(self),
            value,
        ));
        try ret.toError();
    }
};

pub const HostInterface = enum(c_uacpi.uacpi_host_interface) {
    module_device = c_uacpi.UACPI_HOST_INTERFACE_MODULE_DEVICE,
    processor_device = c_uacpi.UACPI_HOST_INTERFACE_PROCESSOR_DEVICE,
    @"3_0_thermal_model" = c_uacpi.UACPI_HOST_INTERFACE_3_0_THERMAL_MODEL,
    @"3_0_scp_extensions" = c_uacpi.UACPI_HOST_INTERFACE_3_0_SCP_EXTENSIONS,
    processor_aggregator_device = c_uacpi.UACPI_HOST_INTERFACE_PROCESSOR_AGGREGATOR_DEVICE,

    /// Same as install/uninstall interface, but comes with an enum of known interfaces defined by the ACPI
    /// specification.
    ///
    /// These are disabled by default as they depend on the host kernel support.
    pub fn enable(interface: HostInterface) !void {
        const ret: Status = @enumFromInt(c_uacpi.uacpi_enable_host_interface(
            @intFromEnum(interface),
        ));
        try ret.toError();
    }

    pub fn disable(interface: HostInterface) !void {
        const ret: Status = @enumFromInt(c_uacpi.uacpi_disable_host_interface(
            @intFromEnum(interface),
        ));
        try ret.toError();
    }
};

pub const FixedEvent = enum(c_uacpi.uacpi_fixed_event) {
    timer_status = c_uacpi.UACPI_FIXED_EVENT_TIMER_STATUS,
    power_button = c_uacpi.UACPI_FIXED_EVENT_POWER_BUTTON,
    sleep_button = c_uacpi.UACPI_FIXED_EVENT_SLEEP_BUTTON,
    rtc = c_uacpi.UACPI_FIXED_EVENT_RTC,

    pub fn installHandler(
        event: FixedEvent,
        comptime UserContextT: type,
        handler: InterruptHandler(UserContextT),
        user_context: ?*UserContextT,
    ) !void {
        const ret: Status = @enumFromInt(c_uacpi.uacpi_install_fixed_event_handler(
            @intFromEnum(event),
            makeInterruptHandlerWrapper(UserContextT, handler),
            @ptrCast(user_context),
        ));
        try ret.toError();
    }

    pub fn uninstallHandler(event: FixedEvent) !void {
        const ret: Status = @enumFromInt(c_uacpi.uacpi_uninstall_fixed_event_handler(
            @intFromEnum(event),
        ));
        try ret.toError();
    }

    pub fn enable(event: FixedEvent) !void {
        const ret: Status = @enumFromInt(c_uacpi.uacpi_enable_fixed_event(
            @intFromEnum(event),
        ));
        try ret.toError();
    }

    pub fn disable(event: FixedEvent) !void {
        const ret: Status = @enumFromInt(c_uacpi.uacpi_disable_fixed_event(
            @intFromEnum(event),
        ));
        try ret.toError();
    }

    pub fn clear(event: FixedEvent) !void {
        const ret: Status = @enumFromInt(c_uacpi.uacpi_clear_fixed_event(
            @intFromEnum(event),
        ));
        try ret.toError();
    }

    pub fn info(event: FixedEvent) !EventInfo {
        var info_data: EventInfo = undefined;
        const ret: Status = @enumFromInt(c_uacpi.uacpi_fixed_event_info(
            @intFromEnum(event),
            @ptrCast(&info_data),
        ));
        try ret.toError();
        return info_data;
    }
};

pub const Node = opaque {
    pub fn root() *Node {
        return @ptrCast(c_uacpi.uacpi_namespace_root());
    }

    pub const PredefinedNamespace = enum(c_uacpi.uacpi_predefined_namespace) {
        root = c_uacpi.UACPI_PREDEFINED_NAMESPACE_ROOT,
        gpe = c_uacpi.UACPI_PREDEFINED_NAMESPACE_GPE,
        pr = c_uacpi.UACPI_PREDEFINED_NAMESPACE_PR,
        sb = c_uacpi.UACPI_PREDEFINED_NAMESPACE_SB,
        si = c_uacpi.UACPI_PREDEFINED_NAMESPACE_SI,
        tz = c_uacpi.UACPI_PREDEFINED_NAMESPACE_TZ,
        gl = c_uacpi.UACPI_PREDEFINED_NAMESPACE_GL,
        os = c_uacpi.UACPI_PREDEFINED_NAMESPACE_OS,
        osi = c_uacpi.UACPI_PREDEFINED_NAMESPACE_OSI,
        rev = c_uacpi.UACPI_PREDEFINED_NAMESPACE_REV,
    };

    pub fn getPredefined(predefined_namespace: PredefinedNamespace) *Node {
        return @ptrCast(c_uacpi.uacpi_namespace_get_predefined(
            @intFromEnum(predefined_namespace),
        ));
    }

    /// Returns `true` if the node is an alias.
    pub fn isAlias(self: *const Node) bool {
        return c_uacpi.uacpi_namespace_node_is_alias(@ptrCast(@constCast(self)));
    }

    pub fn name(self: *const Node) Object.Name {
        return @bitCast(c_uacpi.uacpi_namespace_node_name(@ptrCast(self)));
    }

    /// Returns the type of object stored at the namespace node.
    ///
    /// NOTE: due to the existance of the CopyObject operator in AML, the return value of this function is subject
    /// to TOCTOU bugs.
    pub fn objectType(self: *const Node) !Object.Type {
        var object_type: Object.Type = undefined;

        const ret: Status = @enumFromInt(c_uacpi.uacpi_namespace_node_type(
            @ptrCast(self),
            @ptrCast(&object_type),
        ));
        try ret.toError();

        return object_type;
    }

    /// Returns `true` if the type of the object stored at the namespace node matches the provided value.
    ///
    /// NOTE: due to the existance of the CopyObject operator in AML, the return value of this function is subject
    /// to TOCTOU bugs.
    pub fn is(self: *const Node, object_type: Object.Type) !bool {
        var out: bool = undefined;

        const ret: Status = @enumFromInt(c_uacpi.uacpi_namespace_node_is(
            @ptrCast(self),
            @intFromEnum(object_type),
            @ptrCast(&out),
        ));
        try ret.toError();

        return out;
    }

    /// Returns `true` if the type of the object stored at the namespace node matches any of the type bits in the
    /// provided value.
    ///
    /// NOTE: due to the existance of the CopyObject operator in AML, the return value of this function is subject
    /// to TOCTOU bugs.
    pub fn isOneOf(self: *const Node, object_type_bits: Object.TypeBits) !bool {
        var out: bool = undefined;

        const ret: Status = @enumFromInt(c_uacpi.uacpi_namespace_node_is_one_of(
            @ptrCast(self),
            @bitCast(object_type_bits),
            @ptrCast(&out),
        ));
        try ret.toError();

        return out;
    }

    pub fn depth(self: *const Node) usize {
        return c_uacpi.uacpi_namespace_node_depth(@ptrCast(self));
    }

    pub fn parent(self: *const Node) *Node {
        return @ptrCast(c_uacpi.uacpi_namespace_node_parent(@ptrCast(@constCast(self))));
    }

    pub fn find(parent_node: *const Node, path: [:0]const u8) !?*Node {
        var node: ?*Node = undefined;

        const ret: Status = @enumFromInt(c_uacpi.uacpi_namespace_node_find(
            @ptrCast(@constCast(parent_node)),
            path.ptr,
            @ptrCast(&node),
        ));
        if (ret == .not_found) return null;
        try ret.toError();

        return node;
    }

    /// Same as `find`, except the search recurses upwards when the namepath consists of only a single nameseg.
    ///
    /// Usually, this behavior is only desired if resolving a namepath specified in an aml-provided object, such as
    /// a package element.
    pub fn resolveFromAmlNamepath(scope_node: *const Node, path: [:0]const u8) !?*Node {
        var node: ?*Node = undefined;

        const ret: Status = @enumFromInt(c_uacpi.uacpi_namespace_node_resolve_from_aml_namepath(
            @ptrCast(@constCast(scope_node)),
            path.ptr,
            @ptrCast(&node),
        ));
        if (ret == .not_found) return null;
        try ret.toError();

        return node;
    }

    /// Depth-first iterate the namespace starting at the first child of 'parent_node'.
    pub fn forEachChildSimple(
        parent_node: *const Node,
        comptime UserContextT: type,
        callback: IterationCallback(UserContextT),
        user_context: ?*UserContextT,
    ) !void {
        const ret: Status = @enumFromInt(c_uacpi.uacpi_namespace_for_each_child_simple(
            @ptrCast(@constCast(parent_node)),
            makeIterationCallbackWrapper(UserContextT, callback),
            user_context,
        ));
        try ret.toError();
    }

    pub const Depth = enum(u32) {
        any = c_uacpi.UACPI_MAX_DEPTH_ANY,

        _,
    };

    /// Depth-first iterate the namespace starting at the first child of 'parent_node'.
    ///
    /// 'descending_callback' is invoked the first time a node is visited when walking down.
    ///
    /// 'ascending_callback' is invoked the second time a node is visited after we reach the leaf node without children
    /// and start walking up.
    ///
    /// Either of the callbacks may be `null`, but not both at the same time.
    ///
    /// Only nodes matching 'type_mask' are passed to the callbacks.
    ///
    /// 'max_depth' is used to limit the maximum reachable depth from 'parent', where 1 is only direct children of
    /// 'parent', 2 is children of first-level children etc.
    pub fn forEachChild(
        parent_node: *const Node,
        comptime UserContextT: type,
        opt_descending_callback: ?IterationCallback(UserContextT),
        opt_ascending_callback: ?IterationCallback(UserContextT),
        type_mask: Object.TypeBits,
        max_depth: Depth,
        user_context: ?*UserContextT,
    ) !void {
        const ret: Status = @enumFromInt(c_uacpi.uacpi_namespace_for_each_child(
            @ptrCast(@constCast(parent_node)),
            if (opt_descending_callback) |descending_callback|
                makeIterationCallbackWrapper(UserContextT, descending_callback)
            else
                null,
            if (opt_ascending_callback) |ascending_callback|
                makeIterationCallbackWrapper(UserContextT, ascending_callback)
            else
                null,
            @bitCast(type_mask),
            @intFromEnum(max_depth),
            user_context,
        ));
        try ret.toError();
    }

    /// Returns an iterator over the immediate children of a node.
    pub fn childIterator(parent_node: *const Node) !ChildIterator {
        var child: ?*Node = null;

        const ret: Status = @enumFromInt(c_uacpi.uacpi_namespace_node_next(
            @ptrCast(@constCast(parent_node)),
            @ptrCast(&child),
        ));
        if (ret == .not_found) return .{
            .parent = parent_node,
            .current_child = null,
            .type_mask = null,
        };
        try ret.toError();

        return .{
            .parent = parent_node,
            .current_child = child,
            .type_mask = null,
        };
    }

    /// Returns an iterator over the immediate children of a node.
    ///
    /// Only nodes matching 'type_mask' are returned.
    pub fn childIteratorTyped(parent_node: *const Node, type_mask: Object.TypeBits) !ChildIterator {
        var child: ?*Node = null;

        const ret: Status = @enumFromInt(c_uacpi.uacpi_namespace_node_next_typed(
            @ptrCast(@constCast(parent_node)),
            @ptrCast(&child),
            @bitCast(type_mask),
        ));
        if (ret == .not_found) return .{
            .parent = parent_node,
            .current_child = null,
            .type_mask = type_mask,
        };
        try ret.toError();

        return .{
            .parent = parent_node,
            .current_child = child,
            .type_mask = type_mask,
        };
    }

    pub const ChildIterator = struct {
        parent: *const Node,
        current_child: ?*Node,
        type_mask: ?Object.TypeBits,

        pub fn next(self: *ChildIterator) !?*Node {
            const child = self.current_child orelse return null;

            const ret: Status = if (self.type_mask) |type_mask|
                @enumFromInt(c_uacpi.uacpi_namespace_node_next_typed(
                    @ptrCast(@constCast(self.parent)),
                    @ptrCast(&self.current_child),
                    @bitCast(type_mask),
                ))
            else
                @enumFromInt(c_uacpi.uacpi_namespace_node_next(
                    @ptrCast(@constCast(self.parent)),
                    @ptrCast(&self.current_child),
                ));

            if (ret == .not_found) {
                self.current_child = null;
                return child;
            }
            try ret.toError();

            return child;
        }
    };

    pub const AbsoultePath = struct {
        path: [:0]const u8,

        pub fn deinit(self: AbsoultePath) void {
            c_uacpi.uacpi_free_absolute_path(self.path.ptr);
        }
    };

    pub fn getAbsolutePath(self: *const Node) AbsoultePath {
        const ptr: [*:0]const u8 = c_uacpi.uacpi_namespace_node_generate_absolute_path(@ptrCast(self));
        return .{ .path = std.mem.sliceTo(ptr, 0) };
    }

    /// Install a Notify() handler to a device node.
    ///
    /// A handler installed to the root node will receive all notifications, even if a device already has a
    /// dedicated Notify handler.
    pub fn installNotifyHandler(
        node: *Node,
        comptime UserContextT: type,
        handler: NotifyHandler(UserContextT),
        user_context: ?*UserContextT,
    ) !void {
        const ret: Status = @enumFromInt(c_uacpi.uacpi_install_notify_handler(
            @ptrCast(node),
            makeNotifyHandlerWrapper(UserContextT, handler),
            user_context,
        ));
        try ret.toError();
    }

    pub fn uninstallNotifyHandler(
        node: *Node,
        comptime UserContextT: type,
        handler: NotifyHandler(UserContextT),
    ) !void {
        const ret: Status = @enumFromInt(c_uacpi.uacpi_uninstall_notify_handler(
            @ptrCast(node),
            makeNotifyHandlerWrapper(UserContextT, handler),
        ));
        try ret.toError();
    }

    pub const AddressSpace = enum(c_uacpi.uacpi_address_space) {
        system_memory = c_uacpi.UACPI_ADDRESS_SPACE_SYSTEM_MEMORY,
        system_io = c_uacpi.UACPI_ADDRESS_SPACE_SYSTEM_IO,
        pci_config = c_uacpi.UACPI_ADDRESS_SPACE_PCI_CONFIG,
        embedded_controller = c_uacpi.UACPI_ADDRESS_SPACE_EMBEDDED_CONTROLLER,
        smbus = c_uacpi.UACPI_ADDRESS_SPACE_SMBUS,
        system_cmos = c_uacpi.UACPI_ADDRESS_SPACE_SYSTEM_CMOS,
        pci_bar_target = c_uacpi.UACPI_ADDRESS_SPACE_PCI_BAR_TARGET,
        ipmi = c_uacpi.UACPI_ADDRESS_SPACE_IPMI,
        general_purpose_io = c_uacpi.UACPI_ADDRESS_SPACE_GENERAL_PURPOSE_IO,
        generic_serial_bus = c_uacpi.UACPI_ADDRESS_SPACE_GENERIC_SERIAL_BUS,
        pcc = c_uacpi.UACPI_ADDRESS_SPACE_PCC,
        prm = c_uacpi.UACPI_ADDRESS_SPACE_PRM,
        ffixedhw = c_uacpi.UACPI_ADDRESS_SPACE_FFIXEDHW,

        // Internal type
        table_data = c_uacpi.UACPI_ADDRESS_SPACE_TABLE_DATA,
    };

    /// Install an address space handler to a device node.
    ///
    /// The handler is recursively connected to all of the operation regions of type 'space' underneath 'device_node'.
    ///
    /// Note that this recursion stops as soon as another device node that already has an address space handler of this
    /// type installed is encountered.
    pub fn installAddressSpaceHandler(
        device_node: *Node,
        space: AddressSpace,
        comptime UserContextT: type,
        handler: RegionHandler(UserContextT),
        user_context: ?*UserContextT,
    ) !void {
        const ret: Status = @enumFromInt(c_uacpi.uacpi_install_address_space_handler(
            @ptrCast(device_node),
            @intFromEnum(space),
            makeRegionHandlerWrapper(UserContextT, handler),
            user_context,
        ));
        try ret.toError();
    }

    /// Uninstall the handler of type 'space' from a given device node.
    pub fn uninstallAddressSpaceHandler(
        device_node: *Node,
        space: AddressSpace,
    ) !void {
        const ret: Status = @enumFromInt(c_uacpi.uacpi_uninstall_address_space_handler(
            @ptrCast(device_node),
            @intFromEnum(space),
        ));
        try ret.toError();
    }

    /// Execute _REG(space, ACPI_REG_CONNECT) for all of the opregions with this address space underneath this device.
    ///
    /// This should only be called manually if you want to register an early handler that must be available before the
    /// call to `namespaceInitialize`.
    pub fn regAllOpregions(
        device_node: *Node,
        space: AddressSpace,
    ) !void {
        const ret: Status = @enumFromInt(c_uacpi.uacpi_reg_all_opregions(
            @ptrCast(device_node),
            @intFromEnum(space),
        ));
        try ret.toError();
    }

    /// Checks whether the device at 'node' matches any of the PNP ids provided in 'list'.
    ///
    /// This is done by first attempting to match the value returned from _HID and then the value(s) from _CID.
    ///
    /// Note that the presence of the device (_STA) is not verified here.
    pub fn deviceMatchesPnpId(device_node: *const Node, list: [:null]const ?[*:0]const u8) bool {
        return c_uacpi.uacpi_device_matches_pnp_id(
            @ptrCast(@constCast(device_node)),
            list.ptr,
        );
    }

    /// Find all the devices in the namespace starting at 'parent' matching the specified 'hids' against any value from
    /// _HID or _CID.
    ///
    /// Only devices reported as present via _STA are checked.
    ///
    /// Any matching devices are then passed to the 'callback'.
    pub fn findDevicesAt(
        parent_node: *const Node,
        hids: [:null]const ?[*:0]const u8,
        comptime UserContextT: type,
        callback: IterationCallback(UserContextT),
        user_context: ?*UserContextT,
    ) !void {
        const ret: Status = @enumFromInt(c_uacpi.uacpi_find_devices_at(
            @ptrCast(@constCast(parent_node)),
            hids.ptr,
            makeIterationCallbackWrapper(UserContextT, callback),
            user_context,
        ));
        try ret.toError();
    }

    /// Same as `findDevicesAt`, except this starts at the root and only matches one hid.
    pub fn findDevices(
        hid: [:0]const u8,
        comptime UserContextT: type,
        callback: IterationCallback(UserContextT),
        user_context: ?*UserContextT,
    ) !void {
        const ret: Status = @enumFromInt(c_uacpi.uacpi_find_devices(
            hid.ptr,
            makeIterationCallbackWrapper(UserContextT, callback),
            user_context,
        ));
        try ret.toError();
    }

    pub const PciRoutingTable = extern struct {
        num_entries: usize,
        _entries: Entry,

        pub fn entries(self: *const PciRoutingTable) []const Entry {
            const ptr: [*]const Entry = @ptrCast(&self._entries);
            return ptr[0..self.num_entries];
        }

        pub fn deinit(self: *const PciRoutingTable) void {
            c_uacpi.uacpi_free_pci_routing_table(@ptrCast(@constCast(self)));
        }

        pub const Entry = extern struct {
            address: u32,
            index: u32,
            source: *Node,
            pin: u8,

            comptime {
                core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_pci_routing_table_entry));
            }
        };
    };

    pub fn getPciRoutingTable(
        device_node: *const Node,
    ) !*const PciRoutingTable {
        var table: *const PciRoutingTable = undefined;

        const ret: Status = @enumFromInt(c_uacpi.uacpi_get_pci_routing_table(
            @ptrCast(@constCast(device_node)),
            @ptrCast(&table),
        ));
        try ret.toError();

        return table;
    }

    pub const IdString = extern struct {
        /// size of the string including the null byte
        size: u32,
        _value: [*:0]const u8,

        pub fn value(self: *const IdString) ?[:0]const u8 {
            if (self.size == 0) return null;
            return self._value[0 .. self.size - 1 :0];
        }

        pub fn deinit(self: *const IdString) void {
            c_uacpi.uacpi_free_id_string(@ptrCast(@constCast(self)));
        }

        comptime {
            core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_id_string));
        }
    };

    /// Evaluate a device's _HID method and get its value.
    pub fn evalHid(node: *const Node) !?*const IdString {
        var id_string: *const IdString = undefined;

        const ret: Status = @enumFromInt(c_uacpi.uacpi_eval_hid(
            @ptrCast(@constCast(node)),
            @ptrCast(&id_string),
        ));
        if (ret == .not_found) return null;
        try ret.toError();

        return id_string;
    }

    pub const PnpIdList = extern struct {
        num_ids: u32,
        size: u32,
        _ids: IdString,

        pub fn ids(self: *const PnpIdList) []const IdString {
            const ptr: [*]const IdString = @ptrCast(&self._ids);
            return ptr[0..self.num_ids];
        }

        pub fn deinit(self: *const PnpIdList) void {
            c_uacpi.uacpi_free_pnp_id_list(@ptrCast(@constCast(self)));
        }
    };

    /// Evaluate a device's _CID method and get its value.
    pub fn evalCid(node: *const Node) !?*const PnpIdList {
        var list: *const PnpIdList = undefined;

        const ret: Status = @enumFromInt(c_uacpi.uacpi_eval_cid(
            @ptrCast(@constCast(node)),
            @ptrCast(&list),
        ));
        if (ret == .not_found) return null;
        try ret.toError();

        return list;
    }

    /// Evaluate a device's _STA method and get its value.
    pub fn evalSta(node: *const Node) !?u32 {
        var value: u32 = undefined;

        const ret: Status = @enumFromInt(c_uacpi.uacpi_eval_sta(
            @ptrCast(@constCast(node)),
            @ptrCast(&value),
        ));
        if (value == std.math.maxInt(u32)) return null;
        try ret.toError();

        return value;
    }

    /// Evaluate a device's _ADR method and get its value.
    pub fn evalAdr(node: *const Node) !?u64 {
        var value: u64 = undefined;

        const ret: Status = @enumFromInt(c_uacpi.uacpi_eval_adr(
            @ptrCast(@constCast(node)),
            @ptrCast(&value),
        ));
        if (ret == .not_found) return null;
        try ret.toError();

        return value;
    }

    /// Evaluate a device's _CLS method and get its value.
    ///
    /// The format of returned string is BBSSPP where:
    /// - BB => Base Class (e.g. 01 => Mass Storage)
    /// - SS => Sub-Class (e.g. 06 => SATA)
    /// - PP => Programming Interface (e.g. 01 => AHCI)
    pub fn evalCls(node: *const Node) !?*const IdString {
        var id_string: *const IdString = undefined;

        const ret: Status = @enumFromInt(c_uacpi.uacpi_eval_cls(
            @ptrCast(@constCast(node)),
            @ptrCast(&id_string),
        ));
        if (ret == .not_found) return null;
        try ret.toError();

        return id_string;
    }

    /// Evaluate a device's _UID method and get its value.
    pub fn evalUid(node: *const Node) !?*const IdString {
        var id_string: *const IdString = undefined;

        const ret: Status = @enumFromInt(c_uacpi.uacpi_eval_uid(
            @ptrCast(@constCast(node)),
            @ptrCast(&id_string),
        ));
        if (ret == .not_found) return null;
        try ret.toError();

        return id_string;
    }

    /// Evaluate an object within the namespace and get back its value.
    ///
    /// Either parent_node or path must be valid.
    pub fn eval(
        parent_node: *Node,
        path: ?[:0]const u8,
        objects: []const *const Object,
    ) !*Object {
        var value: *Object = undefined;

        const ret: Status = @enumFromInt(c_uacpi.uacpi_eval(
            @ptrCast(parent_node),
            if (path) |p| p.ptr else null,
            &.{
                .objects = @ptrCast(@constCast(objects.ptr)),
                .count = objects.len,
            },
            @ptrCast(&value),
        ));
        try ret.toError();

        return value;
    }

    /// Evaluate an object within the namespace and get back its value.
    ///
    /// Either parent_node or path must be valid.
    pub fn evalSimple(
        parent_node: *Node,
        path: ?[:0]const u8,
    ) !*Object {
        var value: *Object = undefined;

        const ret: Status = @enumFromInt(c_uacpi.uacpi_eval_simple(
            @ptrCast(parent_node),
            if (path) |p| p.ptr else null,
            @ptrCast(&value),
        ));
        try ret.toError();

        return value;
    }

    /// Same as `eval`, but the return value type is validated against the `ret_mask`.
    ///
    /// `Error.TypeMismatch` is returned on error.
    pub fn evalTyped(
        parent_node: *Node,
        path: ?[:0]const u8,
        objects: []const *const Object,
        ret_mask: Object.TypeBits,
    ) !*Object {
        var value: *Object = undefined;

        const ret: Status = @enumFromInt(c_uacpi.uacpi_eval_typed(
            @ptrCast(parent_node),
            if (path) |p| p.ptr else null,
            &.{
                .objects = @ptrCast(@constCast(objects.ptr)),
                .count = objects.len,
            },
            @bitCast(ret_mask),
            @ptrCast(&value),
        ));
        try ret.toError();

        return value;
    }

    /// Same as `evalTyped`, but the return value type is validated against the `ret_mask`.
    ///
    /// `Error.TypeMismatch` is returned on error.
    pub fn evalTypedSimple(
        parent_node: *Node,
        path: ?[:0]const u8,
        ret_mask: Object.TypeBits,
    ) !*Object {
        var value: *Object = undefined;

        const ret: Status = @enumFromInt(c_uacpi.uacpi_eval_simple_typed(
            @ptrCast(parent_node),
            if (path) |p| p.ptr else null,
            @bitCast(ret_mask),
            @ptrCast(&value),
        ));
        try ret.toError();

        return value;
    }

    /// Same as `eval` but without a return value.
    pub fn execute(
        parent_node: *Node,
        path: ?[:0]const u8,
        objects: []const *const Object,
    ) !void {
        const ret: Status = @enumFromInt(c_uacpi.uacpi_execute(
            @ptrCast(parent_node),
            if (path) |p| p.ptr else null,
            &.{
                .objects = @ptrCast(@constCast(objects.ptr)),
                .count = objects.len,
            },
        ));
        try ret.toError();
    }

    /// Same as `evalSimple` but without a return value.
    pub fn executeSimple(
        parent_node: *Node,
        path: ?[:0]const u8,
    ) !void {
        const ret: Status = @enumFromInt(c_uacpi.uacpi_execute_simple(
            @ptrCast(parent_node),
            if (path) |p| p.ptr else null,
        ));
        try ret.toError();
    }

    /// A shorthand for `evalTyped` with `Object.TypeBits.integer`.
    pub fn evalInteger(
        parent_node: *Node,
        path: ?[:0]const u8,
        objects: []const *const Object,
    ) !u64 {
        var value: u64 = undefined;

        const ret: Status = @enumFromInt(c_uacpi.uacpi_eval_integer(
            @ptrCast(parent_node),
            if (path) |p| p.ptr else null,
            &.{
                .objects = @ptrCast(@constCast(objects.ptr)),
                .count = objects.len,
            },
            &value,
        ));
        try ret.toError();

        return value;
    }

    /// A shorthand for `evalTypedSimple` with `Object.TypeBits.integer`.
    pub fn evalIntegerSimple(
        parent_node: *Node,
        path: ?[:0]const u8,
    ) !u64 {
        var value: u64 = undefined;

        const ret: Status = @enumFromInt(c_uacpi.uacpi_eval_simple_integer(
            @ptrCast(parent_node),
            if (path) |p| p.ptr else null,
            &value,
        ));
        try ret.toError();

        return value;
    }

    /// A shorthand for `evalTyped` with `Object.TypeBits.buffer`|`Object.TypeBits.string`.
    ///
    /// Use `Object.getStringOrBuffer` to retrieve the resulting buffer data.
    pub fn evalBufferOrString(
        parent_node: *Node,
        path: ?[:0]const u8,
        objects: []const *const Object,
    ) !*Object {
        var value: *Object = undefined;

        const ret: Status = @enumFromInt(c_uacpi.uacpi_eval_buffer_or_string(
            @ptrCast(parent_node),
            if (path) |p| p.ptr else null,
            &.{
                .objects = @ptrCast(@constCast(objects.ptr)),
                .count = objects.len,
            },
            @ptrCast(&value),
        ));
        try ret.toError();

        return value;
    }

    /// A shorthand for `evalTypedSimple` with `Object.TypeBits.buffer`|`Object.TypeBits.string`.
    ///
    /// Use `Object.getStringOrBuffer` to retrieve the resulting buffer data.
    pub fn evalBufferOrStringSimple(
        parent_node: *Node,
        path: ?[:0]const u8,
    ) !*Object {
        var value: *Object = undefined;

        const ret: Status = @enumFromInt(c_uacpi.uacpi_eval_simple_buffer_or_string(
            @ptrCast(parent_node),
            if (path) |p| p.ptr else null,
            @ptrCast(&value),
        ));
        try ret.toError();

        return value;
    }

    /// A shorthand for `evalTyped` with `Object.TypeBits.string`.
    ///
    /// Use `Object.getString` to retrieve the resulting buffer data.
    pub fn evalString(
        parent_node: *Node,
        path: ?[:0]const u8,
        objects: []const *const Object,
    ) !*Object {
        var value: *Object = undefined;

        const ret: Status = @enumFromInt(c_uacpi.uacpi_eval_string(
            @ptrCast(parent_node),
            if (path) |p| p.ptr else null,
            &.{
                .objects = @ptrCast(@constCast(objects.ptr)),
                .count = objects.len,
            },
            @ptrCast(&value),
        ));
        try ret.toError();

        return value;
    }

    /// A shorthand for `evalTypedSimple` with `Object.TypeBits.string`.
    ///
    /// Use `Object.getString` to retrieve the resulting buffer data.
    pub fn evalStringSimple(
        parent_node: *Node,
        path: ?[:0]const u8,
    ) !*Object {
        var value: *Object = undefined;

        const ret: Status = @enumFromInt(c_uacpi.uacpi_eval_simple_string(
            @ptrCast(parent_node),
            if (path) |p| p.ptr else null,
            @ptrCast(&value),
        ));
        try ret.toError();

        return value;
    }

    /// A shorthand for `evalTyped` with `Object.TypeBits.buffer`.
    ///
    /// Use `Object.getBuffer` to retrieve the resulting buffer data.
    pub fn evalBuffer(
        parent_node: *Node,
        path: ?[:0]const u8,
        objects: []const *const Object,
    ) !*Object {
        var value: *Object = undefined;

        const ret: Status = @enumFromInt(c_uacpi.uacpi_eval_buffer(
            @ptrCast(parent_node),
            if (path) |p| p.ptr else null,
            &.{
                .objects = @ptrCast(@constCast(objects.ptr)),
                .count = objects.len,
            },
            @ptrCast(&value),
        ));
        try ret.toError();

        return value;
    }

    /// A shorthand for `evalTypedSimple` with `Object.TypeBits.buffer`.
    ///
    /// Use `Object.getBuffer` to retrieve the resulting buffer data.
    pub fn evalBufferSimple(
        parent_node: *Node,
        path: ?[:0]const u8,
    ) !*Object {
        var value: *Object = undefined;

        const ret: Status = @enumFromInt(c_uacpi.uacpi_eval_simple_buffer(
            @ptrCast(parent_node),
            if (path) |p| p.ptr else null,
            @ptrCast(&value),
        ));
        try ret.toError();

        return value;
    }

    /// A shorthand for `evalTyped` with `Object.TypeBits.package`.
    ///
    /// Use `Object.getPackage` to retrieve the resulting object array.
    pub fn evalPackage(
        parent_node: *Node,
        path: ?[:0]const u8,
        objects: []const *const Object,
    ) !*Object {
        var value: *Object = undefined;

        const ret: Status = @enumFromInt(c_uacpi.uacpi_eval_package(
            @ptrCast(parent_node),
            if (path) |p| p.ptr else null,
            &.{
                .objects = @ptrCast(@constCast(objects.ptr)),
                .count = objects.len,
            },
            @ptrCast(&value),
        ));
        try ret.toError();

        return value;
    }

    /// A shorthand for `evalTypedSimple` with `Object.TypeBits.package`.
    ///
    /// Use `Object.getPackage` to retrieve the resulting object array.
    pub fn evalPackageSimple(
        parent_node: *Node,
        path: ?[:0]const u8,
    ) !*Object {
        var value: *Object = undefined;

        const ret: Status = @enumFromInt(c_uacpi.uacpi_eval_simple_package(
            @ptrCast(parent_node),
            if (path) |p| p.ptr else null,
            @ptrCast(&value),
        ));
        try ret.toError();

        return value;
    }

    pub const Info = extern struct {
        /// Size of the entire structure
        size: u32,

        name: Object.Name,
        type: Object.Type,
        num_params: u8,

        flags: Flags,

        /// A mapping of [S1..S4] to the shallowest D state supported by the device in that S state.
        sxd: [4]u8,

        /// A mapping of [S0..S4] to the deepest D state supported by the device in that S state to be able to wake
        /// itself.
        sxw: [5]u8,

        addr: u64,
        hid: IdString,
        uid: IdString,
        cls: IdString,
        cid: PnpIdList,

        pub const Flags = packed struct(u8) {
            has_adr: bool,
            has_hid: bool,
            has_uid: bool,
            has_cid: bool,
            has_cls: bool,
            has_sxd: bool,
            has_sxw: bool,
            _reserved: u1,
        };

        pub fn deinit(self: *const Info) void {
            c_uacpi.uacpi_free_namespace_node_info(@ptrCast(@constCast(self)));
        }
    };

    /// Retrieve information about a namespace node.
    ///
    /// This includes the attached object's type, name, number of parameters (if it's a method), the result of
    /// evaluating _ADR, _UID, _CLS, _HID, _CID, as well as _SxD and _SxW.
    pub fn info(node: *const Node) !*const Info {
        var info_ptr: *const Info = undefined;

        const ret: Status = @enumFromInt(c_uacpi.uacpi_get_namespace_node_info(
            @ptrCast(@constCast(node)),
            @ptrCast(&info_ptr),
        ));
        try ret.toError();

        return info_ptr;
    }

    /// Get the info for a given GPE.
    ///
    /// NOTE: 'gpe_device' may be null for GPEs managed by \_GPE
    pub fn gpeInfo(gpe_device: ?*const Node, index: u16) !EventInfo {
        var event_info: EventInfo = undefined;
        const ret: Status = @enumFromInt(c_uacpi.uacpi_gpe_info(
            @ptrCast(@constCast(gpe_device)),
            index,
            @ptrCast(&event_info),
        ));
        try ret.toError();
        return event_info;
    }

    /// Installs a handler to the provided GPE at 'index' controlled by device 'gpe_device'.
    ///
    /// The GPE is automatically disabled & cleared according to the configured triggering upon invoking the handler.
    ///
    /// The event is optionally re-enabled (by returning `InterruptReturn.gpe_reenable`).
    ///
    /// NOTE: 'gpe_device' may be null for GPEs managed by \_GPE
    pub fn installGPEHandler(
        gpe_device: ?*Node,
        index: u16,
        triggering: Triggering,
        comptime UserContextT: type,
        handler: GPEHandler(UserContextT),
        user_context: ?*UserContextT,
    ) !void {
        const ret: Status = @enumFromInt(c_uacpi.uacpi_install_gpe_handler(
            @ptrCast(gpe_device),
            index,
            @intFromEnum(triggering),
            makeGPEHandlerWrapper(UserContextT, handler),
            user_context,
        ));
        try ret.toError();
    }

    /// Installs a raw handler to the provided GPE at 'index' controlled by device 'gpe_device'.
    ///
    /// The handler is dispatched immediately after the event is received, status & enable bits are untouched.
    ///
    /// NOTE: 'gpe_device' may be null for GPEs managed by \_GPE
    pub fn installRawGPEHandler(
        gpe_device: ?*Node,
        index: u16,
        comptime UserContextT: type,
        handler: GPEHandler(UserContextT),
        user_context: ?*UserContextT,
    ) !void {
        const ret: Status = @enumFromInt(c_uacpi.uacpi_install_gpe_handler_raw(
            @ptrCast(gpe_device),
            index,
            makeGPEHandlerWrapper(UserContextT, handler),
            user_context,
        ));
        try ret.toError();
    }

    pub fn uninstallGPEHandler(
        gpe_device: ?*Node,
        index: u16,
        comptime UserContextT: type,
        handler: GPEHandler(UserContextT),
    ) !void {
        const ret: Status = @enumFromInt(c_uacpi.uacpi_uninstall_gpe_handler(
            @ptrCast(gpe_device),
            index,
            makeGPEHandlerWrapper(UserContextT, handler),
        ));
        try ret.toError();
    }

    /// Marks the GPE 'index' managed by 'gpe_device' as wake-capable.
    ///
    /// 'wake_device' is optional and configures the GPE to generate an implicit notification whenever an event occurs.
    ///
    /// NOTE: 'gpe_device' may be null for GPEs managed by \_GPE
    pub fn setupGPEForWake(
        gpe_device: ?*Node,
        index: u16,
        wake_device: ?*Node,
    ) !void {
        const ret: Status = @enumFromInt(c_uacpi.uacpi_setup_gpe_for_wake(
            @ptrCast(gpe_device),
            index,
            @ptrCast(wake_device),
        ));
        try ret.toError();
    }

    /// Mark a GPE managed by 'gpe_device' as enabled for wake.
    ///
    /// The GPE must have previously been marked by calling `setupGPEForWake`.
    ///
    /// This function only affects the GPE enable register state following the call to `enableAllWakeGPEs`.
    ///
    /// NOTE: 'gpe_device' may be null for GPEs managed by \_GPE
    pub fn enableGPEForWake(
        gpe_device: ?*Node,
        index: u16,
    ) !void {
        const ret: Status = @enumFromInt(c_uacpi.uacpi_enable_gpe_for_wake(
            @ptrCast(gpe_device),
            index,
        ));
        try ret.toError();
    }

    /// Mark a GPE managed by 'gpe_device' as disabled for wake.
    ///
    /// The GPE must have previously been marked by calling `setupGPEForWake`.
    ///
    /// This function only affects the GPE enable register state following the call to `enableAllWakeGPEs`.
    ///
    /// NOTE: 'gpe_device' may be null for GPEs managed by \_GPE
    pub fn disableGPEForWake(
        gpe_device: ?*Node,
        index: u16,
    ) !void {
        const ret: Status = @enumFromInt(c_uacpi.uacpi_disable_gpe_for_wake(
            @ptrCast(gpe_device),
            index,
        ));
        try ret.toError();
    }

    /// Enable a general purpose event managed by 'gpe_device'.
    ///
    /// Internally this uses reference counting to make sure a GPE is not disabled until all possible users of it do so.
    ///
    /// GPEs not marked for wake are enabled automatically so this API is only needed for wake events or those that don't
    /// have a corresponding AML handler.
    ///
    /// NOTE: 'gpe_device' may be null for GPEs managed by \_GPE
    pub fn enableGPE(gpe_device: ?*Node, index: u16) !void {
        const ret: Status = @enumFromInt(c_uacpi.uacpi_enable_gpe(
            @ptrCast(gpe_device),
            index,
        ));
        try ret.toError();
    }

    /// Disable a general purpose event managed by 'gpe_device'.
    ///
    /// Internally this uses reference counting to make sure a GPE is not disabled until all possible users of it do so.
    ///
    /// GPEs not marked for wake are enabled automatically so this API is only needed for wake events or those that don't
    /// have a corresponding AML handler.
    ///
    /// NOTE: 'gpe_device' may be null for GPEs managed by \_GPE
    pub fn disableGPE(gpe_device: ?*Node, index: u16) !void {
        const ret: Status = @enumFromInt(c_uacpi.uacpi_disable_gpe(
            @ptrCast(gpe_device),
            index,
        ));
        try ret.toError();
    }

    /// Clear the status bit of the event 'index' managed by 'gpe_device'.
    ///
    /// NOTE: 'gpe_device' may be null for GPEs managed by \_GPE
    pub fn clearGPE(gpe_device: ?*Node, index: u16) !void {
        const ret: Status = @enumFromInt(c_uacpi.uacpi_clear_gpe(
            @ptrCast(gpe_device),
            index,
        ));
        try ret.toError();
    }

    /// Suspend a general purpose event managed by 'gpe_device'.
    ///
    /// This bypasses the reference counting mechanism and unconditionally clears/sets the corresponding bit in the
    /// enable registers.
    ///
    /// This is used for switching the GPE to poll mode.
    ///
    /// NOTE: 'gpe_device' may be null for GPEs managed by \_GPE
    pub fn suspendGPE(gpe_device: ?*Node, index: u16) !void {
        const ret: Status = @enumFromInt(c_uacpi.uacpi_suspend_gpe(
            @ptrCast(gpe_device),
            index,
        ));
        try ret.toError();
    }

    /// Resume a general purpose event managed by 'gpe_device'.
    ///
    /// This bypasses the reference counting mechanism and unconditionally clears/sets the corresponding bit in the
    /// enable registers.
    ///
    /// This is used for switching the GPE to poll mode.
    ///
    /// NOTE: 'gpe_device' may be null for GPEs managed by \_GPE
    pub fn resumeGPE(gpe_device: ?*Node, index: u16) !void {
        const ret: Status = @enumFromInt(c_uacpi.uacpi_resume_gpe(
            @ptrCast(gpe_device),
            index,
        ));
        try ret.toError();
    }

    /// Finish handling the GPE managed by 'gpe_device' at 'index'.
    ///
    /// This clears the status registers if it hasn't been cleared yet and re-enables the event if it was enabled before.
    ///
    /// NOTE: 'gpe_device' may be null for GPEs managed by \_GPE
    pub fn finishHandlingGPE(gpe_device: ?*Node, index: u16) !void {
        const ret: Status = @enumFromInt(c_uacpi.uacpi_finish_handling_gpe(
            @ptrCast(gpe_device),
            index,
        ));
        try ret.toError();
    }

    /// Hard mask a general purpose event at 'index' managed by 'gpe_device'.
    ///
    /// This is used to permanently silence an event so that further calls to enable/disable as well as suspend/resume
    /// get ignored.
    ///
    /// This might be necessary for GPEs that cause an event storm due to the kernel's inability to properly handle them.
    ///
    /// The only way to enable a masked event is by a call to unmask.
    ///
    /// NOTE: 'gpe_device' may be null for GPEs managed by \_GPE
    pub fn maskGPE(gpe_device: ?*Node, index: u16) !void {
        const ret: Status = @enumFromInt(c_uacpi.uacpi_mask_gpe(
            @ptrCast(gpe_device),
            index,
        ));
        try ret.toError();
    }

    /// Hard unmask a general purpose event at 'index' managed by 'gpe_device'.
    ///
    /// NOTE: 'gpe_device' may be null for GPEs managed by \_GPE
    pub fn unmaskGPE(gpe_device: ?*Node, index: u16) !void {
        const ret: Status = @enumFromInt(c_uacpi.uacpi_unmask_gpe(
            @ptrCast(gpe_device),
            index,
        ));
        try ret.toError();
    }

    /// Install a new GPE block, usually defined by a device in the namespace with a _HID of ACPI0006.
    pub fn installGPEBlock(
        gpe_device: *Node,
        address: u64,
        address_space: AddressSpace,
        num_registers: u16,
        irq: u32,
    ) !void {
        const ret: Status = @enumFromInt(c_uacpi.uacpi_install_gpe_block(
            @ptrCast(gpe_device),
            address,
            @intFromEnum(address_space),
            num_registers,
            irq,
        ));
        try ret.toError();
    }

    pub fn uninstallGPEBlock(gpe_device: *Node) !void {
        const ret: Status = @enumFromInt(c_uacpi.uacpi_uninstall_gpe_block(
            @ptrCast(gpe_device),
        ));
        try ret.toError();
    }

    /// Evaluate the _CRS method for a 'device' and get the returned resource list.
    ///
    /// NOTE: the returned buffer must be released via `Resources.deinit` when no longer needed.
    pub fn getCurrentResources(device: *const Node) !?*Resources {
        var resources: *Resources = undefined;

        const ret: Status = @enumFromInt(c_uacpi.uacpi_get_current_resources(
            @ptrCast(@constCast(device)),
            @ptrCast(&resources),
        ));
        if (ret == .not_found) return null;
        try ret.toError();

        return resources;
    }

    /// Evaluate the _PRS method for a 'device' and get the returned resource list.
    ///
    /// NOTE: the returned buffer must be released via `Resources.deinit` when no longer needed.
    pub fn getPossibleResources(device: *const Node) !?*Resources {
        var resources: *Resources = undefined;

        const ret: Status = @enumFromInt(c_uacpi.uacpi_get_possible_resources(
            @ptrCast(@constCast(device)),
            @ptrCast(&resources),
        ));
        if (ret == .not_found) return null;
        try ret.toError();

        return resources;
    }

    /// Evaluate an arbitrary method that is expected to return an AML resource buffer for a 'device' and get the
    /// returned resource list.
    ///
    /// NOTE: the returned buffer must be released via `Resources.deinit` when no longer needed.
    pub fn getResources(device: *const Node, method: [:0]const u8) !?*Resources {
        var resources: *Resources = undefined;

        const ret: Status = @enumFromInt(c_uacpi.uacpi_get_device_resources(
            @ptrCast(@constCast(device)),
            method.ptr,
            @ptrCast(&resources),
        ));
        if (ret == .not_found) return null;
        try ret.toError();

        return resources;
    }

    /// Set the configuration to be used by the 'device' by calling its _SRS method.
    ///
    /// Note that this expects 'resources' in the normal 'Resources' format, and not the raw AML resources bytestream,
    /// the conversion to the latter is done automatically by this API.
    ///
    /// If you want to _SRS a raw AML resources bytestream, use 'Node.execute' or similar API directly.
    pub fn setResources(device: *Node, resources: *const Resources) !void {
        const ret: Status = @enumFromInt(c_uacpi.uacpi_set_resources(
            @ptrCast(device),
            @ptrCast(@constCast(resources)),
        ));

        try ret.toError();
    }

    pub fn forEachDeviceResource(
        device: *const Node,
        method: [:0]const u8,
        comptime UserContextT: type,
        callback: ResourceIterationCallback(UserContextT),
        user_context: ?*UserContextT,
    ) !void {
        const ret: Status = @enumFromInt(c_uacpi.uacpi_for_each_device_resource(
            @ptrCast(@constCast(device)),
            method.ptr,
            makeResourceIterationCallbackWrapper(UserContextT, callback),
            user_context,
        ));
        try ret.toError();
    }
};

pub const Object = opaque {
    pub fn ref(self: *Object) void {
        c_uacpi.uacpi_object_ref(@ptrCast(self));
    }

    pub fn unref(self: *Object) void {
        c_uacpi.uacpi_object_unref(@ptrCast(self));
    }

    pub fn getType(self: *const Object) Type {
        return @enumFromInt(c_uacpi.uacpi_object_get_type(@ptrCast(@constCast(self))));
    }

    pub fn getTypeBit(self: *const Object) TypeBits {
        return @bitCast(c_uacpi.uacpi_object_get_type_bit(@ptrCast(@constCast(self))));
    }

    pub fn is(self: *const Object, object_type: Type) bool {
        return c_uacpi.uacpi_object_is(@ptrCast(@constCast(self)), @intFromEnum(object_type));
    }

    pub fn isOneOf(self: *const Object, type_mask: TypeBits) bool {
        return c_uacpi.uacpi_object_is_one_of(
            @ptrCast(@constCast(self)),
            @bitCast(type_mask),
        );
    }

    /// Create an uninitialized object.
    ///
    /// The object can be further overwritten via `Object.assign*` to anything.
    pub fn createUninitialized() error{OutOfMemory}!*Object {
        return @ptrCast(c_uacpi.uacpi_object_create_uninitialized() orelse return error.OutOfMemory);
    }

    pub fn createInteger(value: u64) error{OutOfMemory}!*Object {
        return @ptrCast(c_uacpi.uacpi_object_create_integer(value) orelse return error.OutOfMemory);
    }

    pub const OverflowBehavior = enum(c_uacpi.uacpi_overflow_behavior) {
        allow = c_uacpi.UACPI_OVERFLOW_ALLOW,
        truncate = c_uacpi.UACPI_OVERFLOW_TRUNCATE,
        disallow = c_uacpi.UACPI_OVERFLOW_DISALLOW,
    };

    pub fn createIntegerSafe(value: u64, overflow_behavior: OverflowBehavior) !*Object {
        var object: *Object = undefined;
        const ret: Status = @enumFromInt(c_uacpi.uacpi_object_create_integer_safe(
            value,
            @intFromEnum(overflow_behavior),
            @ptrCast(&object),
        ));
        try ret.toError();
        return object;
    }

    pub fn assignInteger(self: *Object, value: u64) !void {
        const ret: Status = @enumFromInt(c_uacpi.uacpi_object_assign_integer(
            @ptrCast(self),
            value,
        ));
        try ret.toError();
    }

    pub fn getInteger(self: *const Object) !u64 {
        var value: u64 = undefined;
        const ret: Status = @enumFromInt(c_uacpi.uacpi_object_get_integer(
            @ptrCast(@constCast(self)),
            &value,
        ));
        try ret.toError();
        return value;
    }

    /// Create a string object.
    ///
    /// Takes in a constant view of the data.
    ///
    /// NOTE: The data is copied to a separately allocated buffer and is not taken ownership of.
    pub fn createString(str: []const u8) error{OutOfMemory}!*Object {
        return @ptrCast(c_uacpi.uacpi_object_create_string(.{
            .unnamed_0 = .{ .const_bytes = str.ptr },
            .length = str.len,
        }) orelse return error.OutOfMemory);
    }

    /// Create a buffer object.
    ///
    /// Takes in a constant view of the data.
    ///
    /// NOTE: The data is copied to a separately allocated buffer and is not taken ownership of.
    pub fn createBuffer(str: []const u8) error{OutOfMemory}!*Object {
        return @ptrCast(c_uacpi.uacpi_object_create_buffer(.{
            .unnamed_0 = .{ .const_bytes = str.ptr },
            .length = str.len,
        }) orelse return error.OutOfMemory);
    }

    /// Make the provided object a string.
    ///
    /// Takes in a constant view of the data to be stored in the object.
    ///
    /// NOTE: The data is copied to a separately allocated buffer and is not taken ownership of.
    pub fn assignString(self: *Object, str: []const u8) !void {
        const ret: Status = @enumFromInt(c_uacpi.uacpi_object_assign_string(
            @ptrCast(self),
            .{
                .unnamed_0 = .{ .const_bytes = str.ptr },
                .length = str.len,
            },
        ));
        try ret.toError();
    }

    /// Make the provided object a buffer.
    ///
    /// Takes in a constant view of the data to be stored in the object.
    ///
    /// NOTE: The data is copied to a separately allocated buffer and is not taken ownership of.
    pub fn assignBuffer(self: *Object, str: []const u8) !void {
        const ret: Status = @enumFromInt(c_uacpi.uacpi_object_assign_buffer(
            @ptrCast(self),
            .{
                .unnamed_0 = .{ .const_bytes = str.ptr },
                .length = str.len,
            },
        ));
        try ret.toError();
    }

    /// Returns a writable view of the data stored in the string or buffer object.
    pub fn getStringOrBuffer(self: *Object) ![]u8 {
        var data_view: c_uacpi.uacpi_data_view = undefined;
        const ret: Status = @enumFromInt(c_uacpi.uacpi_object_get_string_or_buffer(
            @ptrCast(self),
            &data_view,
        ));
        try ret.toError();
        return data_view.unnamed_0.bytes[0..data_view.length];
    }

    /// Returns a writable view of the data stored in the string object.
    pub fn getString(self: *Object) ![]u8 {
        var data_view: c_uacpi.uacpi_data_view = undefined;
        const ret: Status = @enumFromInt(c_uacpi.uacpi_object_get_string(
            @ptrCast(self),
            &data_view,
        ));
        try ret.toError();
        return data_view.unnamed_0.bytes[0..data_view.length];
    }

    /// Returns a writable view of the data stored in the buffer object.
    pub fn getBuffer(self: *Object) ![]u8 {
        var data_view: c_uacpi.uacpi_data_view = undefined;
        const ret: Status = @enumFromInt(c_uacpi.uacpi_object_get_buffer(
            @ptrCast(self),
            &data_view,
        ));
        try ret.toError();
        return data_view.unnamed_0.bytes[0..data_view.length];
    }

    /// Returns `true` if the provided string object is actually an AML namepath.
    ///
    /// This can only be the case for package elements.
    ///
    /// If a package element is specified as a path to an object in AML, it's not resolved by the interpreter right away
    /// as it might not have been defined at that point yet, and is instead stored as a special string object to be
    /// resolved by client code when needed.
    ///
    /// Example usage:
    /// ```zig
    ///    var target_node: ?*uacpi.Node = null;
    ///
    ///    const obj = try scope.eval(path, &.{});
    ///
    ///    const arr = try obj.getPackage();
    ///
    ///    if (arr[0].isAmlNamepath()) {
    ///        target_node = try arr[0].resolveAsAmlNamepath(scope);
    ///    }
    /// ```
    pub fn isAmlNamepath(self: *const Object) bool {
        return c_uacpi.uacpi_object_is_aml_namepath(@ptrCast(@constCast(self)));
    }

    /// Resolve an AML namepath contained in a string object.
    ///
    /// This is only applicable to objects that are package elements.
    ///
    /// See an explanation of how this works in the comment above the declaration of `isAmlNamepath`.
    pub fn resolveAsAmlNamepath(self: *const Object, scope: *const Node) !*Node {
        var target_node: *Node = undefined;
        const ret: Status = @enumFromInt(c_uacpi.uacpi_object_resolve_as_aml_namepath(
            @ptrCast(@constCast(self)),
            @ptrCast(@constCast(scope)),
            @ptrCast(&target_node),
        ));
        try ret.toError();
        return target_node;
    }

    /// Create a package object and store all of the objects in the array inside.
    ///
    /// The array is allowed to be empty.
    ///
    /// NOTE: the reference count of each object is incremented before being stored in the object.
    ///       Client code must remove all of the locally created references at its own discretion.
    pub fn createPackage(objects: []const *Object) error{OutOfMemory}!*Object {
        return @ptrCast(c_uacpi.uacpi_object_create_package(
            .{
                .count = objects.len,
                .objects = @ptrCast(@constCast(objects.ptr)),
            },
        ) orelse return error.OutOfMemory);
    }

    /// Returns the list of objects stored in a package object.
    ///
    /// NOTE: the reference count of the objects stored inside is not incremented, which means destroying/overwriting
    /// the object also potentially destroys all of the objects stored inside unless the reference count is incremented
    /// by the client via `Object.ref`.
    pub fn getPackage(object: *const Object) ![]const *Object {
        var object_array: c_uacpi.uacpi_object_array = undefined;

        const ret: Status = @enumFromInt(c_uacpi.uacpi_object_get_package(
            @ptrCast(@constCast(object)),
            &object_array,
        ));
        try ret.toError();

        const ptr: [*]const *Object = @ptrCast(object_array.objects);
        return ptr[0..object_array.count];
    }

    /// Make the provided object a package and store all of the objects in the array inside.
    ///
    /// The array is allowed to be empty.
    ///
    /// NOTE: the reference count of each object is incremented before being stored in the object.
    ///       Client code must remove all of the locally created references at its own discretion.
    pub fn assignPackage(object: *Object, objects: []const *Object) !void {
        const ret: Status = @enumFromInt(c_uacpi.uacpi_object_assign_package(
            @ptrCast(object),
            .{
                .count = objects.len,
                .objects = @ptrCast(@constCast(objects.ptr)),
            },
        ));
        try ret.toError();
    }

    /// Create a reference object and make it point to 'child'.
    ///
    /// NOTE: child's reference count is incremented by one.
    ///       Client code must remove all of the locally created references at its own discretion.
    pub fn createReference(child: *Object) error{OutOfMemory}!*Object {
        return @ptrCast(c_uacpi.uacpi_object_create_reference(@ptrCast(child)) orelse return error.OutOfMemory);
    }
    /// Make the provided object a reference and make it point to 'child'.
    ///
    /// NOTE: child's reference count is incremented by one.
    ///       Client code must remove all of the locally created references at its own discretion.
    pub fn assignReference(object: *Object, child: *Object) !void {
        const ret: Status = @enumFromInt(c_uacpi.uacpi_object_assign_reference(
            @ptrCast(object),
            @ptrCast(child),
        ));
        try ret.toError();
    }

    /// Retrieve the object pointed to by a reference object.
    ///
    /// NOTE: the reference count of the returned object is incremented by one and must be `unref`'ed by the
    ///       client when no longer needed.
    pub fn getReference(object: *const Object) !*Object {
        var child: *Object = undefined;
        const ret: Status = @enumFromInt(c_uacpi.uacpi_object_get_dereferenced(
            @ptrCast(@constCast(object)),
            @ptrCast(&child),
        ));
        try ret.toError();
        return child;
    }

    pub const ProcessorInfo = extern struct {
        id: u8,
        block_address: u32,
        block_length: u8,

        comptime {
            core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_processor_info));
        }
    };

    /// Returns the information about the provided processor object.
    pub fn getProcessorInfo(object: *const Object) !ProcessorInfo {
        var info: ProcessorInfo = undefined;
        const ret: Status = @enumFromInt(c_uacpi.uacpi_object_get_processor_info(
            @ptrCast(@constCast(object)),
            @ptrCast(&info),
        ));
        try ret.toError();
        return info;
    }

    pub const PowerResourceInfo = extern struct {
        system_level: u8,
        resource_order: u16,

        comptime {
            core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_power_resource_info));
        }
    };

    /// Returns the information about the provided power resource object.
    pub fn getPowerResourceInfo(object: *const Object) !PowerResourceInfo {
        var info: PowerResourceInfo = undefined;
        const ret: Status = @enumFromInt(c_uacpi.uacpi_object_get_power_resource_info(
            @ptrCast(@constCast(object)),
            @ptrCast(&info),
        ));
        try ret.toError();
        return info;
    }

    pub const Name = extern union {
        text: [4]u8,
        id: u32,

        comptime {
            core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_object_name));
        }
    };

    pub const Type = enum(c_uacpi.uacpi_object_type) {
        uninitialized = c_uacpi.UACPI_OBJECT_UNINITIALIZED,
        integer = c_uacpi.UACPI_OBJECT_INTEGER,
        string = c_uacpi.UACPI_OBJECT_STRING,
        buffer = c_uacpi.UACPI_OBJECT_BUFFER,
        package = c_uacpi.UACPI_OBJECT_PACKAGE,
        field_unit = c_uacpi.UACPI_OBJECT_FIELD_UNIT,
        device = c_uacpi.UACPI_OBJECT_DEVICE,
        event = c_uacpi.UACPI_OBJECT_EVENT,
        method = c_uacpi.UACPI_OBJECT_METHOD,
        mutex = c_uacpi.UACPI_OBJECT_MUTEX,
        operation_region = c_uacpi.UACPI_OBJECT_OPERATION_REGION,
        power_resource = c_uacpi.UACPI_OBJECT_POWER_RESOURCE,
        processor = c_uacpi.UACPI_OBJECT_PROCESSOR,
        thermal_zone = c_uacpi.UACPI_OBJECT_THERMAL_ZONE,
        buffer_field = c_uacpi.UACPI_OBJECT_BUFFER_FIELD,
        debug = c_uacpi.UACPI_OBJECT_DEBUG,
        reference = c_uacpi.UACPI_OBJECT_REFERENCE,
        buffer_index = c_uacpi.UACPI_OBJECT_BUFFER_INDEX,
    };

    pub const TypeBits = packed struct(c_uacpi.uacpi_object_type_bits) {
        _uninitialized: u1 = 0,
        integer: bool = false,
        string: bool = false,
        buffer: bool = false,
        package: bool = false,
        field_unit: bool = false,
        device: bool = false,
        event: bool = false,
        method: bool = false,
        mutex: bool = false,
        operation_region: bool = false,
        power_resource: bool = false,
        processor: bool = false,
        thermal_zone: bool = false,
        buffer_field: bool = false,
        _unused15: u1 = 0,
        debug: bool = false,
        _unused17_19: u3 = 0,
        reference: bool = false,
        buffer_index: bool = false,
        _unused22_31: u10 = 0,

        pub const any: TypeBits = @bitCast(c_uacpi.UACPI_OBJECT_ANY_BIT);

        comptime {
            core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_object_type_bits));
        }
    };
};

pub const Table = extern struct {
    table: extern union {
        virtual_address: core.VirtualAddress,
        ptr: *anyopaque,
        header: *acpi.tables.SharedHeader,
    },
    index: usize,

    /// Move to the next table with the same signature.
    ///
    /// Returns `true` if the table was found.
    pub fn nextWithSameSignature(table: *Table) !bool {
        const ret: Status = @enumFromInt(c_uacpi.uacpi_table_find_next_with_same_signature(
            @ptrCast(table),
        ));
        if (ret == .not_found) return false;
        try ret.toError();
        return true;
    }

    pub fn ref(table: Table) !void {
        const ret: Status = @enumFromInt(c_uacpi.uacpi_table_ref(
            @constCast(@ptrCast(&table)),
        ));
        try ret.toError();
    }

    pub fn unref(table: Table) !void {
        const ret: Status = @enumFromInt(c_uacpi.uacpi_table_unref(
            @constCast(@ptrCast(&table)),
        ));
        try ret.toError();
    }

    pub fn findBySignature(signature: *const [4]u8) !?Table {
        var table: Table = undefined;

        const ret: Status = @enumFromInt(c_uacpi.uacpi_table_find_by_signature(
            signature,
            @ptrCast(&table),
        ));
        if (ret == .not_found) return null;
        try ret.toError();

        return table;
    }

    pub fn find(table_identifiers: *const TableIdentifiers) !?Table {
        var table: Table = undefined;

        const ret: Status = @enumFromInt(c_uacpi.uacpi_table_find(
            @ptrCast(table_identifiers),
            @ptrCast(&table),
        ));
        if (ret == .not_found) return null;
        try ret.toError();

        return table;
    }

    /// Install a table from a virtual address.
    ///
    /// The table is simply stored in the internal table array, and not loaded by the interpreter (see `load`).
    ///
    /// The table is optionally returned via 'out_table'.
    ///
    /// Manual calls to `install` are not subject to filtering via the table installation callback (if any).
    pub fn installVirtual(address: core.VirtualAddress, out_table: ?*Table) !void {
        const ret: Status = @enumFromInt(c_uacpi.uacpi_table_install(
            address.toPtr(?*anyopaque),
            @ptrCast(out_table),
        ));
        try ret.toError();
    }

    /// Install a table from a physical address.
    ///
    /// The table is simply stored in the internal table array, and not loaded by the interpreter (see `load`).
    ///
    /// The table is optionally returned via 'out_table'.
    ///
    /// Manual calls to `install` are not subject to filtering via the table installation callback (if any).
    pub fn installPhysical(address: core.PhysicalAddress, out_table: ?*Table) !void {
        const ret: Status = @enumFromInt(c_uacpi.uacpi_table_install_physical(
            @bitCast(address),
            @ptrCast(out_table),
        ));
        try ret.toError();
    }

    /// Load a previously installed table by feeding it to the interpreter.
    pub fn load(index: usize) !void {
        const ret: Status = @enumFromInt(c_uacpi.uacpi_table_load(
            @intCast(index),
        ));
        try ret.toError();
    }

    /// Returns the pointer to a sanitized internal version of FADT.
    ///
    /// - The revision is guaranteed to be correct.
    /// - All of the registers are converted to GAS format.
    /// - Fields that might contain garbage are cleared.
    pub fn fadt() !*acpi.FADT {
        var fadt_ptr: *acpi.FADT = undefined;

        const ret: Status = @enumFromInt(c_uacpi.uacpi_table_fadt(
            @ptrCast(&fadt_ptr),
        ));
        try ret.toError();

        return fadt_ptr;
    }

    /// Set a handler that is invoked for each table before it gets installed.
    ///
    /// Depending on the return value, the table is either allowed to be installed as-is, denied, or overriden with a
    /// new one.
    pub fn setTableInstallationHandler(handler: TableInstallationHandler) !void {
        const handler_wrapper = struct {
            fn handlerWrapper(
                header: *acpi.tables.SharedHeader,
                out_override_address: *u64,
            ) callconv(.C) TableInstallationDisposition {
                return handler(header, out_override_address);
            }
        }.handlerWrapper;

        const ret: Status = @enumFromInt(c_uacpi.uacpi_set_table_installation_handler(
            @ptrCast(handler_wrapper),
        ));
        try ret.toError();
    }

    pub const TableInstallationDisposition = enum(c_uacpi.uacpi_table_installation_disposition) {
        /// Allow the table to be installed as-is
        allow = c_uacpi.UACPI_TABLE_INSTALLATION_DISPOSITON_ALLOW,

        /// Deny the table from being installed completely.
        ///
        /// This is useful for debugging various problems, e.g. AML loading bad SSDTs that cause the system to hang or
        /// enter an undesired state.
        deny = c_uacpi.UACPI_TABLE_INSTALLATION_DISPOSITON_DENY,

        /// Override the table being installed with the table at the virtual address returned in 'out_override_address'.
        virtual_override = c_uacpi.UACPI_TABLE_INSTALLATION_DISPOSITON_VIRTUAL_OVERRIDE,

        /// Override the table being installed with the table at the physical address returned in 'out_override_address'.
        physical_override = c_uacpi.UACPI_TABLE_INSTALLATION_DISPOSITON_PHYSICAL_OVERRIDE,
    };

    pub const TableInstallationHandler = fn (
        header: *acpi.tables.SharedHeader,
        out_override_address: *u64,
    ) TableInstallationDisposition;

    pub const TableIdentifiers = extern struct {
        signature: Object.Name,

        /// if oemid[0] == 0 this field is ignored
        oemid: [6]u8 = @splat(0),

        /// if oem_table_id[0] == 0 this field is ignored
        oem_table_id: [8]u8 = @splat(0),

        comptime {
            core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_table_identifiers));
        }
    };

    comptime {
        core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_table));
    }
};

pub const Resources = extern struct {
    length: usize,
    entries: [*]const Resource,

    pub fn deinit(self: *const Resources) void {
        c_uacpi.uacpi_free_resources(@ptrCast(@constCast(self)));
    }

    // uacpi_for_each_resource not implemented as below iterator is superior

    pub fn iterate(self: *const Resources) Iterator {
        return .{
            .data = @ptrCast(self.entries),
        };
    }

    pub const Iterator = struct {
        data: [*]const u8,

        pub fn next(self: *Iterator) ?*const Resource {
            const current: *const Resource = @ptrCast(@alignCast(self.data));

            if (current.type == .end_tag) return null;

            self.data += current.length;

            return current;
        }
    };

    comptime {
        core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_resources));
    }
};

pub const Resource = extern struct {
    type: Type,
    length: u32,

    data: Data,

    /// Convert a single AML-encoded resource to native format.
    ///
    /// This should be used for converting Connection() fields (passed during IO on GeneralPurposeIO or GenericSerialBus
    /// operation regions) or other similar buffers with only one resource to native format.
    ///
    /// NOTE: the returned buffer must be released via `Resource.deinit` when no longer needed.
    pub fn fromBuffer(buffer: []const u8) !*Resource {
        var resource: *Resource = undefined;

        const ret: Status = @enumFromInt(c_uacpi.uacpi_get_resource_from_buffer(
            .{
                .unnamed_0 = .{ .const_bytes = buffer.ptr },
                .length = buffer.len,
            },
            @ptrCast(&resource),
        ));
        try ret.toError();

        return resource;
    }

    pub fn deinit(self: *Resource) void {
        c_uacpi.uacpi_free_resource(@ptrCast(self));
    }

    pub const Type = enum(c_uacpi.uacpi_resource_type) {
        irq = c_uacpi.UACPI_RESOURCE_TYPE_IRQ,
        extended_irq = c_uacpi.UACPI_RESOURCE_TYPE_EXTENDED_IRQ,

        dma = c_uacpi.UACPI_RESOURCE_TYPE_DMA,
        fixed_dma = c_uacpi.UACPI_RESOURCE_TYPE_FIXED_DMA,

        io = c_uacpi.UACPI_RESOURCE_TYPE_IO,
        fixed_io = c_uacpi.UACPI_RESOURCE_TYPE_FIXED_IO,

        address16 = c_uacpi.UACPI_RESOURCE_TYPE_ADDRESS16,
        address32 = c_uacpi.UACPI_RESOURCE_TYPE_ADDRESS32,
        address64 = c_uacpi.UACPI_RESOURCE_TYPE_ADDRESS64,
        address64_extended = c_uacpi.UACPI_RESOURCE_TYPE_ADDRESS64_EXTENDED,

        memory24 = c_uacpi.UACPI_RESOURCE_TYPE_MEMORY24,
        memory32 = c_uacpi.UACPI_RESOURCE_TYPE_MEMORY32,
        fixed_memory32 = c_uacpi.UACPI_RESOURCE_TYPE_FIXED_MEMORY32,

        start_dependent = c_uacpi.UACPI_RESOURCE_TYPE_START_DEPENDENT,

        // internal to the C API
        // end_dependent = c_uacpi.UACPI_RESOURCE_TYPE_END_DEPENDENT,

        // Up to 7 bytes - called vendor_small in the C API
        vendor = c_uacpi.UACPI_RESOURCE_TYPE_VENDOR_SMALL,

        // Up to 2^16 - 1 bytes - called vendor_large in the C API
        vendor_typed = c_uacpi.UACPI_RESOURCE_TYPE_VENDOR_LARGE,

        generic_register = c_uacpi.UACPI_RESOURCE_TYPE_GENERIC_REGISTER,
        gpio_connection = c_uacpi.UACPI_RESOURCE_TYPE_GPIO_CONNECTION,

        // These must always be contiguous in this order
        i2c_connection = c_uacpi.UACPI_RESOURCE_TYPE_SERIAL_I2C_CONNECTION,
        spi_connection = c_uacpi.UACPI_RESOURCE_TYPE_SERIAL_SPI_CONNECTION,
        uart_connection = c_uacpi.UACPI_RESOURCE_TYPE_SERIAL_UART_CONNECTION,
        csi2_connection = c_uacpi.UACPI_RESOURCE_TYPE_SERIAL_CSI2_CONNECTION,

        pin_function = c_uacpi.UACPI_RESOURCE_TYPE_PIN_FUNCTION,
        pin_configuration = c_uacpi.UACPI_RESOURCE_TYPE_PIN_CONFIGURATION,
        pin_group = c_uacpi.UACPI_RESOURCE_TYPE_PIN_GROUP,
        pin_group_function = c_uacpi.UACPI_RESOURCE_TYPE_PIN_GROUP_FUNCTION,
        pin_group_configuration = c_uacpi.UACPI_RESOURCE_TYPE_PIN_GROUP_CONFIGURATION,

        clock_input = c_uacpi.UACPI_RESOURCE_TYPE_CLOCK_INPUT,

        end_tag = c_uacpi.UACPI_RESOURCE_TYPE_END_TAG,
    };

    pub const Data = extern union {
        irq: Irq,
        extended_irq: ExtendedIrq,
        dma: Dma,
        fixed_dma: FixedDma,
        io: Io,
        fixed_io: FixedIo,
        address16: Address16,
        address32: Address32,
        address64: Address64,
        address64_extended: Address64Extended,
        memory24: Memory24,
        memory32: Memory32,
        fixed_memory32: FixedMemory32,
        start_dependent: StartDependent,
        vendor: Vendor,
        vendor_typed: VendorTyped,
        generic_register: GenericRegister,
        gpio_connection: GpioConnection,
        i2c_connection: I2cConnection,
        spi_connection: SpiConnection,
        uart_connection: UartConnection,
        csi2_connection: Csi2Connection,
        pin_function: PinFunction,
        pin_configuration: PinConfiguration,
        pin_group: PinGroup,
        pin_group_function: PinGroupFunction,
        pin_group_configuration: PinGroupConfiguration,
        clock_input: ClockInput,
    };

    pub const Irq = extern struct {
        length_kind: LengthKind,
        triggering: Triggering,
        polarity: Polarity,
        sharing: Sharing,
        wake_capability: WakeCapability,
        num_irqs: u8,
        _irqs: u8,

        pub fn irqs(self: *const Irq) []const u8 {
            const ptr: [*]const u8 = @ptrCast(&self._irqs);
            return ptr[0..self.num_irqs];
        }

        comptime {
            core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_resource_irq) + @sizeOf(u8));
        }
    };

    pub const ExtendedIrq = extern struct {
        direction: Direction,
        triggering: Triggering,
        polarity: Polarity,
        sharing: Sharing,
        wake_capability: WakeCapability,
        num_irqs: u8,
        source: Source,
        _irqs: u32,

        pub fn irqs(self: *const ExtendedIrq) []const u32 {
            const ptr: [*]const u32 = @ptrCast(&self._irqs);
            return ptr[0..self.num_irqs];
        }

        comptime {
            // `u64` due to the alignment forced by the `source` field
            core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_resource_extended_irq) + @sizeOf(u64));
        }
    };

    pub const Dma = extern struct {
        transfer_type: TransferType,
        bus_master_status: BusMasterStatus,
        channel_speed: ChannelSpeed,
        num_channels: u8,
        _channels: u8,

        pub fn channels(self: *const Dma) []const u8 {
            const ptr: [*]const u8 = @ptrCast(&self._channels);
            return ptr[0..self.num_channels];
        }

        pub const TransferType = enum(u8) {
            @"8_bit" = c_uacpi.UACPI_TRANSFER_TYPE_8_BIT,
            @"8_and_16_bit" = c_uacpi.UACPI_TRANSFER_TYPE_8_AND_16_BIT,
            @"16_bit" = c_uacpi.UACPI_TRANSFER_TYPE_16_BIT,
        };

        pub const BusMasterStatus = packed struct(u8) {
            bus_master: bool, // c_uacpi.UACPI_BUS_MASTER

            _reserved: u7,
        };

        pub const ChannelSpeed = enum(u8) {
            compatibility = c_uacpi.UACPI_DMA_COMPATIBILITY,
            a = c_uacpi.UACPI_DMA_TYPE_A,
            b = c_uacpi.UACPI_DMA_TYPE_B,
            f = c_uacpi.UACPI_DMA_TYPE_F,
        };

        comptime {
            core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_resource_dma) + @sizeOf(u8));
        }
    };

    pub const FixedDma = extern struct {
        request_line: u16,
        channel: u16,
        transfer_width: TransferWidth,

        pub const TransferWidth = enum(u8) {
            @"8" = c_uacpi.UACPI_TRANSFER_WIDTH_8,
            @"16" = c_uacpi.UACPI_TRANSFER_WIDTH_16,
            @"32" = c_uacpi.UACPI_TRANSFER_WIDTH_32,
            @"64" = c_uacpi.UACPI_TRANSFER_WIDTH_64,
            @"128" = c_uacpi.UACPI_TRANSFER_WIDTH_128,
            @"256" = c_uacpi.UACPI_TRANSFER_WIDTH_256,
        };

        comptime {
            core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_resource_fixed_dma));
        }
    };

    pub const Io = extern struct {
        decode_type: DecodeType,
        minimum: u16,
        maximum: u16,
        alignment: u8,
        length: u8,

        pub const DecodeType = enum(u8) {
            @"16" = c_uacpi.UACPI_DECODE_16,
            @"10" = c_uacpi.UACPI_DECODE_10,
        };

        comptime {
            core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_resource_io));
        }
    };

    pub const FixedIo = extern struct {
        address: u16,
        length: u8,

        comptime {
            core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_resource_fixed_io));
        }
    };

    pub const Address16 = extern struct {
        common: AddressCommon,
        granularity: u16,
        minimum: u16,
        maximum: u16,
        translation_offset: u16,
        address_length: u16,
        source: Source,

        comptime {
            core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_resource_address16));
        }
    };

    pub const Address32 = extern struct {
        common: AddressCommon,
        granularity: u32,
        minimum: u32,
        maximum: u32,
        translation_offset: u32,
        address_length: u32,
        source: Source,

        comptime {
            core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_resource_address32));
        }
    };

    pub const Address64 = extern struct {
        common: AddressCommon,
        granularity: u64,
        minimum: u64,
        maximum: u64,
        translation_offset: u64,
        address_length: u64,
        source: Source,

        comptime {
            core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_resource_address64));
        }
    };

    pub const Address64Extended = extern struct {
        common: AddressCommon,
        revision_id: u8,
        granularity: u64,
        minimum: u64,
        maximum: u64,
        translation_offset: u64,
        address_length: u64,
        attributes: u64,

        comptime {
            core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_resource_address64_extended));
        }
    };

    pub const Memory24 = extern struct {
        write_status: WriteStatus,
        minimum: u16,
        maximum: u16,
        alignment: u16,
        length: u16,

        comptime {
            core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_resource_memory24));
        }
    };

    pub const Memory32 = extern struct {
        write_status: WriteStatus,
        minimum: u32,
        maximum: u32,
        alignment: u32,
        length: u32,

        comptime {
            core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_resource_memory32));
        }
    };

    pub const FixedMemory32 = extern struct {
        write_status: WriteStatus,
        address: u32,
        length: u32,

        comptime {
            core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_resource_fixed_memory32));
        }
    };

    pub const StartDependent = extern struct {
        length_kind: LengthKind,
        compatibility: CompatibilityPerformance,
        performance: CompatibilityPerformance,

        comptime {
            core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_resource_start_dependent));
        }
    };

    pub const Vendor = extern struct {
        length: u8,
        _data: u8,

        pub fn data(self: *const Vendor) []const u8 {
            const ptr: [*]const u8 = @ptrCast(&self._data);
            return ptr[0..self.length];
        }

        comptime {
            core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_resource_vendor) + @sizeOf(u8));
        }
    };

    pub const VendorTyped = extern struct {
        length: u16,
        sub_type: u8,
        uuid: [16]u8,
        _data: u8,

        pub fn data(self: *const VendorTyped) []const u8 {
            const ptr: [*]const u8 = @ptrCast(&self._data);
            return ptr[0..self.length];
        }

        comptime {
            core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_resource_vendor_typed));
        }
    };

    pub const GenericRegister = extern struct {
        address_space_id: u8,
        bit_width: u8,
        bit_offset: u8,
        access_size: u8,
        address: u64,

        comptime {
            core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_resource_generic_register));
        }
    };

    pub const GpioConnection = extern struct {
        revision_id: u8,
        type: GpioType,
        direction: Direction,
        data: GpioData,
        pull_configuration: PullConfiguration,
        drive_strength: u16,
        debounce_timeout: u16,
        vendor_data_length: u16,
        pin_table_length: u16,
        source: Source,
        pin_table: [*]const u16,
        vendor_data: [*]const u8,

        pub const GpioData = extern union {
            interrupt: InterruptConnectionFlags,
            io: IoConnectionFlags,
            type_specific: u16,
        };

        pub const GpioType = enum(u8) {
            interrupt = c_uacpi.UACPI_GPIO_CONNECTION_INTERRUPT,
            io = c_uacpi.UACPI_GPIO_CONNECTION_IO,
        };

        pub const InterruptConnectionFlags = extern struct {
            triggering: Triggering,
            polarity: Polarity,
            sharing: Sharing,
            wake_capability: WakeCapability,

            comptime {
                core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_interrupt_connection_flags));
            }
        };

        pub const IoConnectionFlags = extern struct {
            restriction: Restriction,
            sharing: Sharing,

            pub const Restriction = enum(u8) {
                none = c_uacpi.UACPI_IO_RESTRICTION_NONE,
                input = c_uacpi.UACPI_IO_RESTRICTION_INPUT,
                output = c_uacpi.UACPI_IO_RESTRICTION_OUTPUT,
                none_preserve = c_uacpi.UACPI_IO_RESTRICTION_NONE_PRESERVE,
            };

            comptime {
                core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_io_connection_flags));
            }
        };

        comptime {
            core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_resource_gpio_connection));
        }
    };

    pub const I2cConnection = extern struct {
        common: SerialBusCommon,
        addressing_mode: AddressingMode,
        slave_address: u16,
        connection_speed: u32,

        pub const AddressingMode = enum(u8) {
            @"7bit" = c_uacpi.UACPI_I2C_7BIT,
            @"10bit" = c_uacpi.UACPI_I2C_10BIT,
        };

        comptime {
            core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_resource_i2c_connection));
        }
    };

    pub const SpiConnection = extern struct {
        common: SerialBusCommon,
        wire_mode: WireMode,
        device_polarity: DevicePolarity,
        data_bit_length: u8,
        phase: Phase,
        polarity: SpiPolarity,
        device_selection: u16,
        connection_speed: u32,

        pub const WireMode = enum(u8) {
            @"4" = c_uacpi.UACPI_SPI_4_WIRES,
            @"3" = c_uacpi.UACPI_SPI_3_WIRES,
        };

        pub const DevicePolarity = enum(u8) {
            active_low = c_uacpi.UACPI_SPI_ACTIVE_LOW,
            active_high = c_uacpi.UACPI_SPI_ACTIVE_HIGH,
        };

        pub const Phase = enum(u8) {
            first = c_uacpi.UACPI_SPI_PHASE_FIRST,
            second = c_uacpi.UACPI_SPI_PHASE_SECOND,
        };

        pub const SpiPolarity = enum(u8) {
            start_low = c_uacpi.UACPI_SPI_START_LOW,
            start_high = c_uacpi.UACPI_SPI_START_HIGH,
        };

        comptime {
            core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_resource_spi_connection));
        }
    };

    pub const UartConnection = extern struct {
        common: SerialBusCommon,
        stop_bits: StopBits,
        data_bits: DataBits,
        endianness: Endianness,
        parity: Parity,
        lines_enabled: LinesEnabled,
        flow_control: FlowControl,
        baud_rate: u32,
        rx_fifo: u16,
        tx_fifo: u16,

        pub const StopBits = enum(u8) {
            none = c_uacpi.UACPI_UART_STOP_BITS_NONE,
            @"1" = c_uacpi.UACPI_UART_STOP_BITS_1,
            @"1_5" = c_uacpi.UACPI_UART_STOP_BITS_1_5,
            @"2" = c_uacpi.UACPI_UART_STOP_BITS_2,
        };

        pub const DataBits = enum(u8) {
            @"5" = c_uacpi.UACPI_UART_DATA_5BITS,
            @"6" = c_uacpi.UACPI_UART_DATA_6BITS,
            @"7" = c_uacpi.UACPI_UART_DATA_7BITS,
            @"8" = c_uacpi.UACPI_UART_DATA_8BITS,
            @"9" = c_uacpi.UACPI_UART_DATA_9BITS,
        };

        pub const Endianness = enum(u8) {
            little = c_uacpi.UACPI_UART_LITTLE_ENDIAN,
            big = c_uacpi.UACPI_UART_BIG_ENDIAN,
        };

        pub const Parity = enum(u8) {
            none = c_uacpi.UACPI_UART_PARITY_NONE,
            even = c_uacpi.UACPI_UART_PARITY_EVEN,
            odd = c_uacpi.UACPI_UART_PARITY_ODD,
            mark = c_uacpi.UACPI_UART_PARITY_MARK,
            space = c_uacpi.UACPI_UART_PARITY_SPACE,
        };

        pub const LinesEnabled = packed struct(u8) {
            _reserved: u2,
            data_carrier_detect: bool,
            ring_indicator: bool,
            data_set_ready: bool,
            data_terminal_ready: bool,
            clear_to_send: bool,
            request_to_send: bool,
        };

        pub const FlowControl = enum(u8) {
            none = c_uacpi.UACPI_UART_FLOW_CONTROL_NONE,
            hardware = c_uacpi.UACPI_UART_FLOW_CONTROL_HW,
            xon_xoff = c_uacpi.UACPI_UART_FLOW_CONTROL_XON_XOFF,
        };

        comptime {
            core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_resource_uart_connection));
        }
    };

    pub const Csi2Connection = extern struct {
        common: SerialBusCommon,
        phy_type: PhyType,
        local_port: u8,

        pub const PhyType = enum(u8) {
            c = c_uacpi.UACPI_CSI2_PHY_C,
            d = c_uacpi.UACPI_CSI2_PHY_D,
        };

        comptime {
            core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_resource_csi2_connection));
        }
    };

    pub const PinFunction = extern struct {
        revision_id: u8,
        sharing: Sharing,
        pull_configuration: PullConfiguration,
        function_number: u16,
        pin_table_length: u16,
        vendor_data_length: u16,
        source: Source,
        pin_table: [*]const u16,
        vendor_data: [*]const u8,

        comptime {
            core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_resource_pin_function));
        }
    };

    pub const PinConfiguration = extern struct {
        revision_id: u8,
        sharing: Sharing,
        direction: Direction,
        type: PinConfigurationType,
        value: u32,
        pin_table_length: u16,
        vendor_data_length: u16,
        source: Source,
        pin_table: [*]const u16,
        vendor_data: [*]const u8,

        comptime {
            core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_resource_pin_configuration));
        }
    };

    pub const PullConfiguration = enum(u8) {
        default = c_uacpi.UACPI_PIN_CONFIG_DEFAULT,
        pull_up = c_uacpi.UACPI_PIN_CONFIG_PULL_UP,
        pull_down = c_uacpi.UACPI_PIN_CONFIG_PULL_DOWN,
        no_pull = c_uacpi.UACPI_PIN_CONFIG_NO_PULL,
    };

    pub const PinGroup = extern struct {
        revision_id: u8,
        direction: Direction,
        pin_table_length: u16,
        vendor_data_length: u16,
        label: Label,
        pin_table: [*]const u16,
        vendor_data: [*]const u8,

        comptime {
            core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_resource_pin_group));
        }
    };

    pub const PinGroupFunction = extern struct {
        revision_id: u8,
        sharing: Sharing,
        direction: Direction,
        function: u16,
        vendor_data_length: u16,
        source: Source,
        label: Label,
        vendor_data: [*]const u8,

        comptime {
            core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_resource_pin_group_function));
        }
    };

    pub const PinGroupConfiguration = extern struct {
        revision_id: u8,
        sharing: Sharing,
        direction: Direction,
        type: PinConfigurationType,
        value: u32,
        vendor_data_length: u16,
        source: Source,
        label: Label,
        vendor_data: [*]const u8,

        comptime {
            core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_resource_pin_group_configuration));
        }
    };

    pub const PinConfigurationType = enum(u8) {
        default = c_uacpi.UACPI_PIN_CONFIG_DEFAULT,
        bias_pull_up = c_uacpi.UACPI_PIN_CONFIG_BIAS_PULL_UP,
        bias_pull_down = c_uacpi.UACPI_PIN_CONFIG_BIAS_PULL_DOWN,
        bias_default = c_uacpi.UACPI_PIN_CONFIG_BIAS_DEFAULT,
        bias_disable = c_uacpi.UACPI_PIN_CONFIG_BIAS_DISABLE,
        bias_high_impedance = c_uacpi.UACPI_PIN_CONFIG_BIAS_HIGH_IMPEDANCE,
        bias_bus_hold = c_uacpi.UACPI_PIN_CONFIG_BIAS_BUS_HOLD,
        drive_open_drain = c_uacpi.UACPI_PIN_CONFIG_DRIVE_OPEN_DRAIN,
        drive_open_source = c_uacpi.UACPI_PIN_CONFIG_DRIVE_OPEN_SOURCE,
        drive_push_pull = c_uacpi.UACPI_PIN_CONFIG_DRIVE_PUSH_PULL,
        drive_strength = c_uacpi.UACPI_PIN_CONFIG_DRIVE_STRENGTH,
        slew_rate = c_uacpi.UACPI_PIN_CONFIG_SLEW_RATE,
        input_debounce = c_uacpi.UACPI_PIN_CONFIG_INPUT_DEBOUNCE,
        input_schmitt_trigger = c_uacpi.UACPI_PIN_CONFIG_INPUT_SCHMITT_TRIGGER,
    };

    pub const ClockInput = extern struct {
        revision_id: u8,
        frequency: Frequency,
        scale: Scale,
        divisor: u16,
        numerator: u32,
        source: Source,

        pub const Scale = enum(u8) {
            hz = c_uacpi.UACPI_SCALE_HZ,
            khz = c_uacpi.UACPI_SCALE_KHZ,
            mhz = c_uacpi.UACPI_SCALE_MHZ,
        };

        pub const Frequency = enum(u8) {
            fixed = c_uacpi.UACPI_FREQUENCY_FIXED,
            variable = c_uacpi.UACPI_FREQUENCY_VARIABLE,
        };

        comptime {
            core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_resource_clock_input));
        }
    };

    pub const SerialBusCommon = extern struct {
        revision_id: u8,
        type: u8,
        mode: Mode,
        direction: Direction,
        sharing: Sharing,
        type_revision_id: u8,
        type_data_length: u16,
        vendor_data_length: u16,
        source: Source,
        vendor_data: [*]const u8,

        pub const Mode = enum(u8) {
            controller_initiated = c_uacpi.UACPI_MODE_CONTROLLER_INITIATED,
            device_initiated = c_uacpi.UACPI_MODE_DEVICE_INITIATED,
        };

        comptime {
            core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_resource_serial_bus_common));
        }
    };

    pub const CompatibilityPerformance = enum(u8) {
        good = c_uacpi.UACPI_GOOD,
        acceptable = c_uacpi.UACPI_ACCEPTABLE,
        sub_optimal = c_uacpi.UACPI_SUB_OPTIMAL,
    };

    pub const AddressCommon = extern struct {
        address_attribute: AddressAttribute,
        type: AddressType,
        direction: Direction,
        decode_type: DecodeType,
        fixed_min_address: FixedAddress,
        fixed_max_address: FixedAddress,

        pub const FixedAddress = enum(u8) {
            not_fixed = c_uacpi.UACPI_ADDRESS_NOT_FIXED,
            fixed = c_uacpi.UACPI_ADDRESS_FIXED,
        };

        pub const AddressType = enum(u8) {
            memory = c_uacpi.UACPI_RANGE_MEMORY,
            io = c_uacpi.UACPI_RANGE_IO,
            bus = c_uacpi.UACPI_RANGE_BUS,
        };

        pub const DecodeType = enum(u8) {
            positive = c_uacpi.UACPI_POISITIVE_DECODE,
            subtractive = c_uacpi.UACPI_SUBTRACTIVE_DECODE,
        };

        pub const AddressAttribute = extern union {
            memory: MemoryAttribute,
            io: IoAttribute,
            type_specific: u8,

            pub const MemoryAttribute = extern struct {
                write_status: WriteStatus,
                caching: Caching,
                range_type: RangeType,
                translation: Translation,

                pub const Caching = enum(u8) {
                    non_cacheable = c_uacpi.UACPI_NON_CACHEABLE,
                    cacheable = c_uacpi.UACPI_CACHEABLE,
                    write_combining = c_uacpi.UACPI_CACHEABLE_WRITE_COMBINING,
                    prefetchable = c_uacpi.UACPI_PREFETCHABLE,
                };

                comptime {
                    core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_memory_attribute));
                }
            };

            pub const IoAttribute = extern struct {
                range_type: RangeType,
                translation: Translation,
                translation_type: TranslationType,

                pub const TranslationType = enum(u8) {
                    dense = c_uacpi.UACPI_TRANSLATION_DENSE,
                    sparse = c_uacpi.UACPI_TRANSLATION_SPARSE,
                };

                comptime {
                    core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_io_attribute));
                }
            };

            comptime {
                core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_address_attribute));
            }
        };

        comptime {
            core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_resource_address_common));
        }
    };

    pub const LengthKind = enum(u8) {
        dont_care = c_uacpi.UACPI_RESOURCE_LENGTH_KIND_DONT_CARE,
        one_less = c_uacpi.UACPI_RESOURCE_LENGTH_KIND_ONE_LESS,
        full = c_uacpi.UACPI_RESOURCE_LENGTH_KIND_FULL,
    };

    pub const Direction = enum(u8) {
        producer = c_uacpi.UACPI_PRODUCER,
        consumer = c_uacpi.UACPI_CONSUMER,
    };

    pub const Polarity = enum(u8) {
        high = c_uacpi.UACPI_POLARITY_ACTIVE_HIGH,
        low = c_uacpi.UACPI_POLARITY_ACTIVE_LOW,
        both = c_uacpi.UACPI_POLARITY_ACTIVE_BOTH,
    };

    pub const Sharing = enum(u8) {
        exclusive = c_uacpi.UACPI_EXCLUSIVE,
        shared = c_uacpi.UACPI_SHARED,
    };

    pub const WakeCapability = enum(u8) {
        capable = c_uacpi.UACPI_WAKE_CAPABLE,
        not_capable = c_uacpi.UACPI_NOT_WAKE_CAPABLE,
    };

    pub const Source = extern struct {
        index: u8,
        index_present: bool,
        length: u16,
        _str: [*:0]const u8,

        pub fn str(self: Source) []const u8 {
            return std.mem.sliceTo(self._str, 0);
        }

        comptime {
            core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_resource_source));
        }
    };

    pub const WriteStatus = enum(u8) {
        non_writable = c_uacpi.UACPI_NON_WRITABLE,
        writable = c_uacpi.UACPI_WRITABLE,
    };

    pub const RangeType = enum(u8) {
        memory = c_uacpi.UACPI_RANGE_TYPE_MEMORY,
        reserved = c_uacpi.UACPI_RANGE_TYPE_RESERVED,
        acpi = c_uacpi.UACPI_RANGE_TYPE_ACPI,
        nvs = c_uacpi.UACPI_RANGE_TYPE_NVS,
    };

    pub const Translation = enum(u8) {
        translation = c_uacpi.UACPI_IO_MEM_TRANSLATION,
        static = c_uacpi.UACPI_IO_MEM_STATIC,
    };

    pub const Label = extern struct {
        length: u16,
        _string: [*]const u8,

        pub fn string(self: *const Label) []const u8 {
            return self._string[0..self.length];
        }

        comptime {
            core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_resource_label));
        }
    };

    comptime {
        core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_resource));
    }
};

pub const ByteWidth = enum(u8) {
    one = 1,
    two = 2,
    four = 4,
};

pub const EventInfo = packed struct(c_uacpi.uacpi_event_info) {
    /// Event is enabled in software
    enabled: bool,
    /// Event is enabled in software (only for wake)
    enabled_for_wake: bool,
    /// Event is masked
    masked: bool,
    /// Event has a handler attached
    has_handler: bool,
    /// Hardware enable bit is set
    hardware_enabled: bool,
    /// Hardware status bit is set
    hardware_status: bool,

    _reserved: u26,
};

pub const InterruptReturn = enum(c_uacpi.uacpi_interrupt_ret) {
    not_handled = c_uacpi.UACPI_INTERRUPT_NOT_HANDLED,
    handled = c_uacpi.UACPI_INTERRUPT_HANDLED,

    /// Only valid for GPE handlers, returned if the handler wishes to reenable the GPE it just handled.
    gpe_reenable = c_uacpi.UACPI_GPE_REENABLE,
};

pub const Timeout = enum(u16) {
    none = 0,
    infinite = 0xFFFF,

    _,
};

pub const Triggering = enum(u8) {
    level = c_uacpi.UACPI_GPE_TRIGGERING_LEVEL,
    edge = c_uacpi.UACPI_GPE_TRIGGERING_EDGE,

    comptime {
        std.debug.assert(c_uacpi.UACPI_GPE_TRIGGERING_LEVEL == c_uacpi.UACPI_TRIGGERING_LEVEL);
        std.debug.assert(c_uacpi.UACPI_GPE_TRIGGERING_EDGE == c_uacpi.UACPI_TRIGGERING_EDGE);
    }
};

pub const Status = enum(c_uacpi.uacpi_status) {
    ok = c_uacpi.UACPI_STATUS_OK,
    mapping_failed = c_uacpi.UACPI_STATUS_MAPPING_FAILED,
    out_of_memory = c_uacpi.UACPI_STATUS_OUT_OF_MEMORY,
    bad_checksum = c_uacpi.UACPI_STATUS_BAD_CHECKSUM,
    invalid_signature = c_uacpi.UACPI_STATUS_INVALID_SIGNATURE,
    invalid_table_length = c_uacpi.UACPI_STATUS_INVALID_TABLE_LENGTH,
    not_found = c_uacpi.UACPI_STATUS_NOT_FOUND,
    invalid_argument = c_uacpi.UACPI_STATUS_INVALID_ARGUMENT,
    unimplemented = c_uacpi.UACPI_STATUS_UNIMPLEMENTED,
    already_exists = c_uacpi.UACPI_STATUS_ALREADY_EXISTS,
    internal_error = c_uacpi.UACPI_STATUS_INTERNAL_ERROR,
    type_mismatch = c_uacpi.UACPI_STATUS_TYPE_MISMATCH,
    init_level_mismatch = c_uacpi.UACPI_STATUS_INIT_LEVEL_MISMATCH,
    namespace_node_dangling = c_uacpi.UACPI_STATUS_NAMESPACE_NODE_DANGLING,
    no_handler = c_uacpi.UACPI_STATUS_NO_HANDLER,
    no_resource_end_tag = c_uacpi.UACPI_STATUS_NO_RESOURCE_END_TAG,
    compiled_out = c_uacpi.UACPI_STATUS_COMPILED_OUT,
    hardware_timeout = c_uacpi.UACPI_STATUS_HARDWARE_TIMEOUT,
    timeout = c_uacpi.UACPI_STATUS_TIMEOUT,
    overridden = c_uacpi.UACPI_STATUS_OVERRIDDEN,
    denied = c_uacpi.UACPI_STATUS_DENIED,

    // All errors that have bytecode-related origin should go here
    aml_undefined_reference = c_uacpi.UACPI_STATUS_AML_UNDEFINED_REFERENCE,
    aml_invalid_namestring = c_uacpi.UACPI_STATUS_AML_INVALID_NAMESTRING,
    aml_object_already_exists = c_uacpi.UACPI_STATUS_AML_OBJECT_ALREADY_EXISTS,
    aml_invalid_opcode = c_uacpi.UACPI_STATUS_AML_INVALID_OPCODE,
    aml_incompatible_object_type = c_uacpi.UACPI_STATUS_AML_INCOMPATIBLE_OBJECT_TYPE,
    aml_bad_encoding = c_uacpi.UACPI_STATUS_AML_BAD_ENCODING,
    aml_out_of_bounds_index = c_uacpi.UACPI_STATUS_AML_OUT_OF_BOUNDS_INDEX,
    aml_sync_level_too_high = c_uacpi.UACPI_STATUS_AML_SYNC_LEVEL_TOO_HIGH,
    aml_invalid_resource = c_uacpi.UACPI_STATUS_AML_INVALID_RESOURCE,
    aml_loop_timeout = c_uacpi.UACPI_STATUS_AML_LOOP_TIMEOUT,
    aml_call_stack_depth_limit = c_uacpi.UACPI_STATUS_AML_CALL_STACK_DEPTH_LIMIT,

    fn toError(self: Status) Error!void {
        return switch (self) {
            .ok => {
                @branchHint(.likely);
            },
            .mapping_failed => Error.MappingFailed,
            .out_of_memory => Error.OutOfMemory,
            .bad_checksum => Error.BadChecksum,
            .invalid_signature => Error.InvalidSignature,
            .invalid_table_length => Error.InvalidTableLength,
            .not_found => Error.NotFound,
            .invalid_argument => Error.InvalidArgument,
            .unimplemented => Error.Unimplemented,
            .already_exists => Error.AlreadyExists,
            .internal_error => Error.InternalError,
            .type_mismatch => Error.TypeMismatch,
            .init_level_mismatch => Error.InitLevelMismatch,
            .namespace_node_dangling => Error.NamespaceNodeDangling,
            .no_handler => Error.NoHandler,
            .no_resource_end_tag => Error.NoResourceEndTag,
            .compiled_out => Error.CompiledOut,
            .hardware_timeout => Error.HardwareTimeout,
            .timeout => Error.Timeout,
            .overridden => Error.Overriden,
            .denied => Error.Denied,

            .aml_undefined_reference => Error.AMLUndefinedReference,
            .aml_invalid_namestring => Error.AMLInvalidNamestring,
            .aml_object_already_exists => Error.AMLObjectAlreadyExists,
            .aml_invalid_opcode => Error.AMLInvalidOpcode,
            .aml_incompatible_object_type => Error.AMLIncompatibleObjectType,
            .aml_bad_encoding => Error.AMLBadEncoding,
            .aml_out_of_bounds_index => Error.AMLOutOfBoundsIndex,
            .aml_sync_level_too_high => Error.AMLSyncLevelTooHigh,
            .aml_invalid_resource => Error.AMLInvalidResource,
            .aml_loop_timeout => Error.AMLLoopTimeout,
            .aml_call_stack_depth_limit => Error.AMLCallStackDepthLimit,
        };
    }
};

pub const Error = error{
    MappingFailed,
    OutOfMemory,
    BadChecksum,
    InvalidSignature,
    InvalidTableLength,
    NotFound,
    InvalidArgument,
    Unimplemented,
    AlreadyExists,
    InternalError,
    TypeMismatch,
    InitLevelMismatch,
    NamespaceNodeDangling,
    NoHandler,
    NoResourceEndTag,
    CompiledOut,
    HardwareTimeout,
    Timeout,
    Overriden,
    Denied,

    AMLUndefinedReference,
    AMLInvalidNamestring,
    AMLObjectAlreadyExists,
    AMLInvalidOpcode,
    AMLIncompatibleObjectType,
    AMLBadEncoding,
    AMLOutOfBoundsIndex,
    AMLSyncLevelTooHigh,
    AMLInvalidResource,
    AMLLoopTimeout,
    AMLCallStackDepthLimit,
};

pub const FirmwareRequest = extern struct {
    type: Type,

    data: Data,

    const Type = enum(c_uacpi.uacpi_firmware_request_type) {
        breakpoint = c_uacpi.UACPI_FIRMWARE_REQUEST_TYPE_BREAKPOINT,
        fatal = c_uacpi.UACPI_FIRMWARE_REQUEST_TYPE_FATAL,
    };

    const Data = extern union {
        breakpoint: Breakpoint,
        fatal: Fatal,

        const Breakpoint = extern struct {
            /// The context of the method currently being executed
            ctx: *anyopaque,
        };

        const Fatal = extern struct {
            type: u8,
            code: u32,
            arg: u64,
        };
    };

    comptime {
        core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_firmware_request));
    }
};

pub const LogLevel = enum(c_uacpi.uacpi_log_level) {
    /// Super verbose logging, every op & uop being processed is logged.
    /// Mostly useful for tracking down hangs/lockups.
    DEBUG = c_uacpi.UACPI_LOG_DEBUG,

    /// A little verbose, every operation region access is traced with a bit of
    /// extra information on top.
    TRACE = c_uacpi.UACPI_LOG_TRACE,

    /// Only logs the bare minimum information about state changes and/or
    /// initialization progress.
    INFO = c_uacpi.UACPI_LOG_INFO,

    /// Logs recoverable errors and/or non-important aborts.
    WARN = c_uacpi.UACPI_LOG_WARN,

    /// Logs only critical errors that might affect the ability to initialize or
    /// prevent stable runtime.
    ERROR = c_uacpi.UACPI_LOG_ERROR,
};

pub const WorkType = enum(c_uacpi.uacpi_work_type) {
    /// Schedule a GPE handler method for execution.
    ///
    /// This should be scheduled to run on CPU0 to avoid potential SMI-related firmware bugs.
    gpe_execution = c_uacpi.UACPI_WORK_GPE_EXECUTION,

    /// Schedule a Notify(device) firmware request for execution.
    ///
    /// This can run on any CPU.
    work_notification = c_uacpi.UACPI_WORK_NOTIFICATION,
};

pub const WorkHandler = *const fn (*anyopaque) callconv(.C) void;
pub const RawInterruptHandler = *const fn (?*anyopaque) callconv(.C) InterruptReturn;
pub const CpuFlags = c_uacpi.uacpi_cpu_flags;

pub const DataView = extern struct {
    bytes: [*]const u8,
    length: usize,

    pub fn slice(self: *const DataView) []const u8 {
        return self.bytes[0..self.length];
    }

    comptime {
        core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_data_view));
    }
};

pub const IterationDecision = enum(c_uacpi.uacpi_iteration_decision) {
    @"continue" = c_uacpi.UACPI_ITERATION_DECISION_CONTINUE,

    @"break" = c_uacpi.UACPI_ITERATION_DECISION_BREAK,

    /// Only applicable for uacpi_namespace_for_each_child
    next_peer = c_uacpi.UACPI_ITERATION_DECISION_NEXT_PEER,
};

pub fn IterationCallback(comptime UserContextT: type) type {
    return fn (
        node: *Node,
        node_depth: u32,
        user_context: ?*UserContextT,
    ) IterationDecision;
}

inline fn makeIterationCallbackWrapper(
    comptime UserContextT: type,
    callback: IterationCallback(UserContextT),
) c_uacpi.uacpi_iteration_callback {
    return comptime @ptrCast(&struct {
        fn callbackWrapper(
            user_ctx: ?*anyopaque,
            node: *Node,
            node_depth: u32,
        ) callconv(.C) IterationDecision {
            return callback(node, node_depth, @ptrCast(user_ctx));
        }
    }.callbackWrapper);
}

pub fn ResourceIterationCallback(comptime UserContextT: type) type {
    return fn (
        resource: *const Resource,
        user_context: ?*UserContextT,
    ) IterationDecision;
}

inline fn makeResourceIterationCallbackWrapper(
    comptime UserContextT: type,
    callback: ResourceIterationCallback(UserContextT),
) c_uacpi.uacpi_resource_iteration_callback {
    return comptime @ptrCast(&struct {
        fn callbackWrapper(user_ctx: ?*anyopaque, resource: *const Resource) callconv(.C) Node.IterationDecision {
            return callback(resource, @ptrCast(user_ctx));
        }
    }.callbackWrapper);
}

pub fn NotifyHandler(comptime UserContextT: type) type {
    return fn (
        node: *Node,
        value: u64,
        user_context: ?*UserContextT,
    ) Status;
}

inline fn makeNotifyHandlerWrapper(
    comptime UserContextT: type,
    handler: NotifyHandler(UserContextT),
) c_uacpi.uacpi_notify_handler {
    return comptime @ptrCast(&struct {
        fn handlerWrapper(
            user_ctx: ?*anyopaque,
            node: *Node,
            value: u64,
        ) callconv(.C) Status {
            return handler(node, value, @ptrCast(user_ctx));
        }
    }.handlerWrapper);
}

pub fn GPEHandler(comptime UserContextT: type) type {
    return fn (
        gpe_device: *Node,
        index: u16,
        user_context: ?*UserContextT,
    ) InterruptReturn;
}

inline fn makeGPEHandlerWrapper(
    comptime UserContextT: type,
    handler: GPEHandler(UserContextT),
) c_uacpi.uacpi_gpe_handler {
    return comptime @ptrCast(&struct {
        fn handlerWrapper(
            user_ctx: ?*anyopaque,
            gpe_device: *Node,
            index: u16,
        ) callconv(.C) InterruptReturn {
            return handler(gpe_device, index, @ptrCast(user_ctx));
        }
    }.handlerWrapper);
}

pub fn InterruptHandler(comptime UserContextT: type) type {
    return fn (
        user_context: ?*UserContextT,
    ) InterruptReturn;
}

inline fn makeInterruptHandlerWrapper(
    comptime UserContextT: type,
    handler: InterruptHandler(UserContextT),
) c_uacpi.uacpi_interrupt_handler {
    return comptime @ptrCast(&struct {
        fn handlerWrapper(
            user_ctx: ?*anyopaque,
        ) callconv(.C) InterruptReturn {
            return handler(@ptrCast(user_ctx));
        }
    }.handlerWrapper);
}

pub const RegionOperationType = enum(c_uacpi.uacpi_region_op) {
    attach = c_uacpi.UACPI_REGION_OP_ATTACH,

    detach = c_uacpi.UACPI_REGION_OP_DETACH,

    read = c_uacpi.UACPI_REGION_OP_READ,
    write = c_uacpi.UACPI_REGION_OP_WRITE,

    pcc_send = c_uacpi.UACPI_REGION_OP_PCC_SEND,

    gpio_read = c_uacpi.UACPI_REGION_OP_GPIO_READ,
    gpio_write = c_uacpi.UACPI_REGION_OP_GPIO_WRITE,

    ipmi_command = c_uacpi.UACPI_REGION_OP_IPMI_COMMAND,

    ffixedhw_command = c_uacpi.UACPI_REGION_OP_FFIXEDHW_COMMAND,

    prm_command = c_uacpi.UACPI_REGION_OP_PRM_COMMAND,

    serial_read = c_uacpi.UACPI_REGION_OP_SERIAL_READ,
    serial_write = c_uacpi.UACPI_REGION_OP_SERIAL_WRITE,
};

pub fn RegionOperation(comptime UserContextT: type) type {
    return union(RegionOperationType) {
        attach: *Attach,
        detach: *Detach,
        read: *ReadWrite,
        write: *ReadWrite,
        pcc_send: *PccSend,
        gpio_read: *GpioReadWrite,
        gpio_write: *GpioReadWrite,
        ipmi_command: *IpmiCommand,
        ffixedhw_command: *FixedHardwareCommand,
        prm_command: *PrmReadWrite,
        serial_read: *SerialReadWrite,
        serial_write: *SerialReadWrite,

        pub const Attach = extern struct {
            user_context: ?*UserContextT,
            region_node: *Node,
            region_info: RegionInfo,
            out_region_context: ?*anyopaque,

            pub const RegionInfo = extern union {
                generic: Generic,
                pcc: Pcc,
                gpio: Gpio,

                pub const Generic = extern struct {
                    base: u64,
                    length: u64,

                    comptime {
                        core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_generic_region_info));
                    }
                };

                pub const Pcc = extern struct {
                    buffer: DataView,
                    subspace_id: u8,

                    comptime {
                        core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_pcc_region_info));
                    }
                };

                pub const Gpio = extern struct {
                    num_pins: u64,

                    comptime {
                        core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_gpio_region_info));
                    }
                };
            };

            comptime {
                core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_region_attach_data));
            }
        };

        pub const Detach = extern struct {
            user_context: ?*UserContextT,
            region_context: ?*anyopaque,
            region_node: *Node,

            comptime {
                core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_region_detach_data));
            }
        };

        pub const ReadWrite = extern struct {
            user_context: ?*UserContextT,
            region_context: ?*anyopaque,
            addr: extern union {
                address: core.PhysicalAddress,
                offset: u64,
            },
            value: u64,
            byte_width: ByteWidth,

            comptime {
                core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_region_rw_data));
            }
        };

        pub const PccSend = extern struct {
            user_context: ?*UserContextT,
            region_context: ?*anyopaque,
            buffer: DataView,

            comptime {
                core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_region_pcc_send_data));
            }
        };

        pub const GpioReadWrite = extern struct {
            user_context: ?*UserContextT,
            region_context: ?*anyopaque,
            connection: DataView,
            pin_offset: u32,
            num_pins: u32,
            value: u64,

            comptime {
                core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_region_gpio_rw_data));
            }
        };

        pub const IpmiCommand = extern struct {
            user_context: ?*UserContextT,
            region_context: ?*anyopaque,
            in_out_message: DataView,
            command: u64,

            comptime {
                core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_region_ipmi_rw_data));
            }
        };

        pub const FixedHardwareCommand = extern struct {
            user_context: ?*UserContextT,
            region_context: ?*anyopaque,
            in_out_message: DataView,
            command: u64,

            comptime {
                core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_region_ffixedhw_rw_data));
            }
        };

        pub const PrmReadWrite = extern struct {
            user_context: ?*UserContextT,
            region_context: ?*anyopaque,
            in_out_message: DataView,

            comptime {
                core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_region_prm_rw_data));
            }
        };

        pub const SerialReadWrite = extern struct {
            user_context: ?*UserContextT,
            region_context: ?*anyopaque,
            command: u64,
            connection: DataView,
            in_out_buffer: DataView,
            access_attribute: AccessAttribute,

            /// Applicable only is `access_attribute` is one of:
            ///  - `bytes`
            ///  - `raw_bytes`
            ///  - `raw_process_bytes`
            access_length: u8,

            pub const AccessAttribute = enum(c_uacpi.uacpi_access_attribute) {
                quick = c_uacpi.UACPI_ACCESS_ATTRIBUTE_QUICK,
                send_receive = c_uacpi.UACPI_ACCESS_ATTRIBUTE_SEND_RECEIVE,
                byte = c_uacpi.UACPI_ACCESS_ATTRIBUTE_BYTE,
                word = c_uacpi.UACPI_ACCESS_ATTRIBUTE_WORD,
                block = c_uacpi.UACPI_ACCESS_ATTRIBUTE_BLOCK,
                bytes = c_uacpi.UACPI_ACCESS_ATTRIBUTE_BYTES,
                process_call = c_uacpi.UACPI_ACCESS_ATTRIBUTE_PROCESS_CALL,
                block_process_call = c_uacpi.UACPI_ACCESS_ATTRIBUTE_BLOCK_PROCESS_CALL,
                raw_bytes = c_uacpi.UACPI_ACCESS_ATTRIBUTE_RAW_BYTES,
                raw_process_bytes = c_uacpi.UACPI_ACCESS_ATTRIBUTE_RAW_PROCESS_BYTES,
            };

            comptime {
                core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_region_serial_rw_data));
            }
        };
    };
}

pub fn RegionHandler(comptime UserContextT: type) type {
    return fn (operation: RegionOperation(UserContextT)) Status;
}

inline fn makeRegionHandlerWrapper(
    comptime UserContextT: type,
    handler: RegionHandler(UserContextT),
) c_uacpi.uacpi_region_handler {
    return comptime @ptrCast(&struct {
        fn handlerWrapper(
            op: RegionOperationType,
            op_data: *anyopaque,
        ) callconv(.C) Status {
            return handler(switch (op) {
                .attach => .{ .attach = @ptrCast(@alignCast(op_data)) },
                .detach => .{ .detach = @ptrCast(@alignCast(op_data)) },
                .read => .{ .read = @ptrCast(@alignCast(op_data)) },
                .write => .{ .write = @ptrCast(@alignCast(op_data)) },
                .pcc_send => .{ .pcc_send = @ptrCast(@alignCast(op_data)) },
                .gpio_read => .{ .gpio_read = @ptrCast(@alignCast(op_data)) },
                .gpio_write => .{ .gpio_write = @ptrCast(@alignCast(op_data)) },
                .ipmi_command => .{ .ipmi_command = @ptrCast(@alignCast(op_data)) },
                .ffixedhw_command => .{ .ffixedhw_command = @ptrCast(@alignCast(op_data)) },
                .prm_command => .{ .prm_command = @ptrCast(@alignCast(op_data)) },
                .serial_read => .{ .serial_read = @ptrCast(@alignCast(op_data)) },
                .serial_write => .{ .serial_write = @ptrCast(@alignCast(op_data)) },
            });
        }
    }.handlerWrapper);
}

pub const InterfaceHandler = fn (
    name: [:0]const u8,
    supported: bool,
) bool;

inline fn makeInterfaceHandlerWrapper(
    handler: InterfaceHandler,
) c_uacpi.uacpi_interface_handler {
    return comptime @ptrCast(&struct {
        fn handlerWrapper(
            name: [*:0]const u8,
            supported: bool,
        ) callconv(.C) bool {
            return handler(std.mem.sliceTo(name, 0), supported);
        }
    }.handlerWrapper);
}

comptime {
    std.debug.assert(@sizeOf(core.PhysicalAddress) == @sizeOf(c_uacpi.uacpi_phys_addr));
    std.debug.assert(@sizeOf(acpi.Address) == @sizeOf(c_uacpi.acpi_gas));
    std.debug.assert(@intFromPtr(c_uacpi.UACPI_THREAD_ID_NONE) == @intFromEnum(kernel.Task.Id.none));
}

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const acpi = kernel.acpi;
const c_uacpi = @cImport({
    @cInclude("uacpi/event.h");
    @cInclude("uacpi/io.h");
    @cInclude("uacpi/namespace.h");
    @cInclude("uacpi/notify.h");
    @cInclude("uacpi/opregion.h");
    @cInclude("uacpi/osi.h");
    @cInclude("uacpi/registers.h");
    @cInclude("uacpi/resources.h");
    @cInclude("uacpi/sleep.h");
    @cInclude("uacpi/status.h");
    @cInclude("uacpi/tables.h");
    @cInclude("uacpi/types.h");
    @cInclude("uacpi/uacpi.h");
    @cInclude("uacpi/utilities.h");
});
