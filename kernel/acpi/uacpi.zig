// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>
// SPDX-FileCopyrightText: 2022-2024 Daniil Tatianin (https://github.com/UltraOS/uACPI/blob/1d636a34152dc82833c89175b702f2c0671f04e3/LICENSE)

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

    pub fn name(self: *const Node) ObjectName {
        return @bitCast(c_uacpi.uacpi_namespace_node_name(@ptrCast(self)));
    }

    /// Returns the type of object stored at the namespace node.
    ///
    /// NOTE: due to the existance of the CopyObject operator in AML, the return value of this function is subject
    /// to TOCTOU bugs.
    pub fn objectType(self: *const Node) !ObjectType {
        var object_type: ObjectType = undefined;

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
    pub fn isType(self: *const Node, object_type: ObjectType) !bool {
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
    pub fn isTypeOneOf(self: *const Node, object_type_bits: ObjectTypeBits) !bool {
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
        type_mask: ObjectTypeBits,
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
};

pub const io = struct {
    pub fn readGas(gas: *const acpi.Address) !u64 {
        var value: u64 = undefined;

        const ret: Status = @enumFromInt(c_uacpi.uacpi_gas_read(
            @ptrCast(gas),
            @ptrCast(&value),
        ));
        try ret.toError();

        return value;
    }

    pub fn writeGas(gas: *const acpi.Address, value: u64) !void {
        const ret: Status = @enumFromInt(c_uacpi.uacpi_gas_write(
            @ptrCast(gas),
            value,
        ));
        try ret.toError();
    }
};

pub const sleep = struct {
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
};

pub const tables = struct {
    pub const Table = extern struct {
        table: extern union {
            virtual_address: core.VirtualAddress,
            ptr: *anyopaque,
            header: *acpi.SharedHeader,
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

        pub fn refTable(table: Table) !void {
            const ret: Status = @enumFromInt(c_uacpi.uacpi_table_ref(
                @constCast(@ptrCast(&table)),
            ));
            try ret.toError();
        }

        pub fn unrefTable(table: Table) !void {
            const ret: Status = @enumFromInt(c_uacpi.uacpi_table_unref(
                @constCast(@ptrCast(&table)),
            ));
            try ret.toError();
        }

        comptime {
            core.testing.expectSize(Table, @sizeOf(c_uacpi.uacpi_table));
        }
    };

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

    pub const TableIdentifiers = extern struct {
        signature: ObjectName,

        /// if oemid[0] == 0 this field is ignored
        oemid: [6]u8 = @splat(0),

        /// if oem_table_id[0] == 0 this field is ignored
        oem_table_id: [8]u8 = @splat(0),

        comptime {
            core.testing.expectSize(TableIdentifiers, @sizeOf(c_uacpi.uacpi_table_identifiers));
        }
    };

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
        header: *acpi.SharedHeader,
        out_override_address: *u64,
    ) TableInstallationDisposition;

    /// Set a handler that is invoked for each table before it gets installed.
    ///
    /// Depending on the return value, the table is either allowed to be installed as-is, denied, or overriden with a
    /// new one.
    pub fn setTableInstallationHandler(handler: TableInstallationHandler) !void {
        const handler_wrapper = struct {
            fn handlerWrapper(
                header: *acpi.SharedHeader,
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
};

pub const utilities = struct {
    pub const InterruptModel = enum(c_uacpi.uacpi_interrupt_model) {
        pic = c_uacpi.UACPI_INTERRUPT_MODEL_PIC,
        ioapic = c_uacpi.UACPI_INTERRUPT_MODEL_IOAPIC,
        iosapic = c_uacpi.UACPI_INTERRUPT_MODEL_IOSAPIC,
    };

    pub fn setInterruptModel(model: InterruptModel) !void {
        const ret: Status = @enumFromInt(c_uacpi.uacpi_set_interrupt_model(@intFromEnum(model)));
        try ret.toError();
    }
};

pub const ObjectName = extern union {
    text: [4]u8,
    id: u32,

    comptime {
        core.testing.expectSize(ObjectName, @sizeOf(c_uacpi.uacpi_object_name));
    }
};

pub const ObjectType = enum(c_uacpi.uacpi_object_type) {
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

pub const ObjectTypeBits = packed struct(c_uacpi.uacpi_object_type_bits) {
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

    pub const any: ObjectTypeBits = @bitCast(c_uacpi.UACPI_OBJECT_ANY_BIT);

    comptime {
        core.testing.expectSize(@This(), @sizeOf(c_uacpi.uacpi_object_type_bits));
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

pub fn NotifyHandler(comptime UserContextT: type) type {
    return fn (
        node: *Node,
        value: u64,
        user_context: ?*UserContextT,
    ) Status;
}

pub const AbsoultePath = struct {
    path: [:0]const u8,

    pub fn deinit(self: AbsoultePath) void {
        c_uacpi.uacpi_free_absolute_path(self.path.ptr);
    }
};

pub const Depth = enum(u32) {
    any = c_uacpi.UACPI_MAX_DEPTH_ANY,

    _,
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
            .ok => {},
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

    // TODO: are these possible from most functions?
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
const WorkType = enum(c_uacpi.uacpi_work_type) {
    /// Schedule a GPE handler method for execution.
    ///
    /// This should be scheduled to run on CPU0 to avoid potential SMI-related firmware bugs.
    gpe_execution = c_uacpi.UACPI_WORK_GPE_EXECUTION,

    /// Schedule a Notify(device) firmware request for execution.
    ///
    /// This can run on any CPU.
    work_notification = c_uacpi.UACPI_WORK_NOTIFICATION,
};

const InterruptHandler = *const fn (*anyopaque) callconv(.C) void;
const WorkHandler = *const fn (*anyopaque) callconv(.C) void;

const ByteWidth = enum(u8) {
    one = 1,
    two = 2,
    four = 4,
};

const LogLevel = enum(c_uacpi.uacpi_log_level) {
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

const FirmwareRequest = extern struct {
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
        core.testing.expectSize(c_uacpi.uacpi_firmware_request, @sizeOf(FirmwareRequest));
    }
};

comptime {
    std.debug.assert(@sizeOf(core.PhysicalAddress) == @sizeOf(c_uacpi.uacpi_phys_addr));
    std.debug.assert(@sizeOf(acpi.Address) == @sizeOf(c_uacpi.acpi_gas));
    std.debug.assert(@intFromPtr(c_uacpi.UACPI_THREAD_ID_NONE) == @intFromEnum(kernel.Task.Id.none));
}

const kernel_api = struct {
    /// Returns the PHYSICAL address of the RSDP structure via *out_rsdp_address.
    export fn uacpi_kernel_get_rsdp(out_rsdp_address: *core.PhysicalAddress) Status {
        const address = kernel.boot.rsdp() orelse return Status.not_found;

        switch (address) {
            .physical => |addr| out_rsdp_address.* = addr,
            .virtual => |addr| out_rsdp_address.* =
                kernel.vmm.physicalFromDirectMap(addr) catch return .internal_error,
        }

        return .ok;
    }

    /// Open a PCI device at 'address' for reading & writing.
    ///
    /// The handle returned via 'out_handle' is used to perform IO on the configuration space of the device.
    export fn uacpi_kernel_pci_device_open(
        address: kernel.pci.Address,
        out_handle: **kernel.pci.PciFunction,
    ) Status {
        out_handle.* = kernel.pci.getFunction(address) orelse return Status.not_found;
        return .ok;
    }

    export fn uacpi_kernel_pci_device_close(handle: *anyopaque) void {
        _ = handle;
    }

    /// Read the configuration space of a previously open PCI device.
    ///
    /// NOTE:
    /// Since PCI registers are 32 bits wide this must be able to handle e.g. a 1-byte access by reading at the nearest
    /// 4-byte aligned offset below, then masking the value to select the target byte.
    export fn uacpi_kernel_pci_read(
        device: *kernel.pci.PciFunction,
        offset: usize,
        byte_width: ByteWidth,
        value: *u64,
    ) Status {
        const address = device.config_space_address.moveForward(.from(offset, .byte));

        value.* = switch (byte_width) {
            .one => address.toPtr(*const volatile u8).*,
            .two => address.toPtr(*const volatile u16).*,
            .four => address.toPtr(*const volatile u32).*,
        };

        return .ok;
    }

    /// Write the configuration space of a previously open PCI device.
    ///
    /// NOTE:
    /// Since PCI registers are 32 bits wide this must be able to handle e.g. a 1-byte access by reading at the nearest
    /// 4-byte aligned offset below, then masking the value to select the target byte.
    export fn uacpi_kernel_pci_write(
        device: *kernel.pci.PciFunction,
        offset: usize,
        byte_width: ByteWidth,
        value: u64,
    ) Status {
        const address = device.config_space_address.moveForward(.from(offset, .byte));

        switch (byte_width) {
            .one => address.toPtr(*volatile u8).* = @truncate(value),
            .two => address.toPtr(*volatile u16).* = @truncate(value),
            .four => address.toPtr(*volatile u32).* = @truncate(value),
        }

        return .ok;
    }

    /// Map a SystemIO address at [base, base + len) and return a kernel-implemented handle that can be used for reading
    /// and writing the IO range.
    export fn uacpi_kernel_io_map(base: u64, len: usize, out_handle: **anyopaque) Status {
        _ = len;
        out_handle.* = @ptrFromInt(base);
        return .ok;
    }

    export fn uacpi_kernel_io_unmap(handle: *anyopaque) void {
        _ = handle;
    }

    /// Read the IO range mapped via `uacpi_kernel_io_map` at a 0-based 'offset' within the range.
    ///
    /// NOTE:
    /// You are NOT allowed to break e.g. a 4-byte access into four 1-byte accesses. Hardware ALWAYS expects accesses to
    /// be of the exact width.
    export fn uacpi_kernel_io_read(
        handle: *anyopaque,
        offset: usize,
        byte_width: ByteWidth,
        value: *u64,
    ) Status {
        _ = offset;
        const port: u16 = @intCast(@intFromPtr(handle)); // IO ports are 16-bit
        switch (byte_width) {
            .one => value.* = kernel.arch.io.readPort(u8, port) catch return .invalid_argument,
            .two => value.* = kernel.arch.io.readPort(u16, port) catch return .invalid_argument,
            .four => value.* = kernel.arch.io.readPort(u32, port) catch return .invalid_argument,
        }
        return .ok;
    }

    /// Write the IO range mapped via `uacpi_kernel_io_map` at a 0-based 'offset' within the range.
    ///
    /// NOTE:
    /// You are NOT allowed to break e.g. a 4-byte access into four 1-byte accesses. Hardware ALWAYS expects accesses to
    /// be of the exact width.
    export fn uacpi_kernel_io_write(
        handle: *anyopaque,
        offset: usize,
        byte_width: ByteWidth,
        value: u64,
    ) Status {
        _ = offset;
        const port: u16 = @intCast(@intFromPtr(handle)); // IO ports are 16-bit
        switch (byte_width) {
            .one => kernel.arch.io.writePort(u8, port, @truncate(value)) catch return .invalid_argument,
            .two => kernel.arch.io.writePort(u16, port, @truncate(value)) catch return .invalid_argument,
            .four => kernel.arch.io.writePort(u32, port, @truncate(value)) catch return .invalid_argument,
        }

        return .ok;
    }

    export fn uacpi_kernel_map(addr: core.PhysicalAddress, len: usize) [*]u8 {
        _ = len;
        return kernel.vmm.nonCachedDirectMapFromPhysical(addr).toPtr([*]u8);
    }

    export fn uacpi_kernel_unmap(addr: [*]u8, len: usize) void {
        _ = addr;
        _ = len;
    }

    /// Allocate a block of memory of 'size' bytes.
    /// The contents of the allocated memory are unspecified.
    export fn uacpi_kernel_alloc(size: usize) ?[*]u8 {
        const allocation = kernel.heap.allocate(
            size,
            kernel.Task.getCurrent(),
        ) catch return null;
        return allocation.address.toPtr([*]u8);
    }

    /// Free a previously allocated memory block.
    ///
    /// 'mem' might be a NULL pointer. In this case, the call is assumed to be a no-op.
    export fn uacpi_kernel_free(opt_mem: ?[*]u8) void {
        const mem = opt_mem orelse return;
        kernel.heap.deallocateBase(.fromPtr(mem), kernel.Task.getCurrent());
    }

    export fn uacpi_kernel_log(uacpi_log_level: LogLevel, c_msg: [*:0]const u8) void {
        switch (uacpi_log_level) {
            inline else => |level| {
                const kernel_log_level: std.log.Level = comptime switch (level) {
                    .DEBUG, .TRACE, .INFO => .debug,
                    .WARN => .warn,
                    .ERROR => .err,
                };

                if (!log.levelEnabled(kernel_log_level)) return;

                const full_msg = std.mem.sliceTo(c_msg, 0);

                const msg = if (full_msg.len > 0 and full_msg[full_msg.len - 1] == '\n')
                    full_msg[0 .. full_msg.len - 1]
                else
                    full_msg;

                switch (kernel_log_level) {
                    .debug => log.debug("{s}", .{msg}),
                    .info => @compileError("NO INFO LOGS"),
                    .warn => log.warn("{s}", .{msg}),
                    .err => log.err("{s}", .{msg}),
                }
            },
        }
    }

    /// Returns the number of nanosecond ticks elapsed since boot, strictly monotonic.
    export fn uacpi_kernel_get_nanoseconds_since_boot() u64 {
        return kernel.time.wallclock.elapsed(.zero, kernel.time.wallclock.read()).value;
    }

    /// Spin for N microseconds.
    export fn uacpi_kernel_stall(usec: u8) void {
        const start = kernel.time.wallclock.read();

        const duration: core.Duration = .from(usec, .microsecond);

        while (kernel.time.wallclock.elapsed(start, kernel.time.wallclock.read()).lessThan(duration)) {
            kernel.arch.spinLoopHint();
        }
    }

    /// Sleep for N milliseconds.
    export fn uacpi_kernel_sleep(msec: u64) void {
        core.panicFmt("uacpi_kernel_sleep(msec={})", .{msec}, null);
    }

    /// Create an opaque non-recursive kernel mutex object.
    export fn uacpi_kernel_create_mutex() *kernel.sync.Mutex {
        const mutex = kernel.heap.allocator.create(kernel.sync.Mutex) catch unreachable;
        mutex.* = .{};
        return mutex;
    }

    /// Free a opaque non-recursive kernel mutex object.
    export fn uacpi_kernel_free_mutex(mutex: *kernel.sync.Mutex) void {
        kernel.heap.allocator.destroy(mutex);
    }

    /// Create/free an opaque kernel (semaphore-like) event object.
    export fn uacpi_kernel_create_event() *anyopaque {
        log.warn("uacpi_kernel_create_event called with dummy implementation", .{});

        const static = struct {
            var value: std.atomic.Value(usize) = .init(1);
        };

        return @ptrFromInt(static.value.fetchAdd(1, .acquire));
    }

    /// Free a previously allocated kernel (semaphore-like) event object.
    export fn uacpi_kernel_free_event(handle: *anyopaque) void {
        core.panicFmt("uacpi_kernel_free_event(handle={})", .{handle}, null);
    }

    /// Returns a unique identifier of the currently executing thread.
    ///
    /// The returned thread id cannot be UACPI_THREAD_ID_NONE.
    export fn uacpi_kernel_get_thread_id() kernel.Task.Id {
        return kernel.Task.getCurrent().id;
    }

    /// Try to acquire the mutex with a millisecond timeout.
    ///
    /// The timeout value has the following meanings:
    /// - 0x0000 - Attempt to acquire the mutex once, in a non-blocking manner
    /// - 0x0001...0xFFFE - Attempt to acquire the mutex for at least 'timeout' milliseconds
    /// - 0xFFFF - Infinite wait, block until the mutex is acquired
    ///
    /// The following are possible return values:
    /// 1. UACPI_STATUS_OK - successful acquire operation
    /// 2. UACPI_STATUS_TIMEOUT - timeout reached while attempting to acquire (or the single attempt to acquire was not
    ///                           successful for calls with timeout=0)
    /// 3. Any other value - signifies a host internal error and is treated as such
    export fn uacpi_kernel_acquire_mutex(mutex: *kernel.sync.Mutex, timeout: u16) Status {
        const current_task = kernel.Task.getCurrent();

        switch (timeout) {
            0x0000 => core.panic("mutex try lock not implemented", null),
            0x0001...0xFFFE => core.panic("mutex timeout lock not implemented", null),
            0xFFFF => mutex.lock(current_task),
        }

        return .ok;
    }

    export fn uacpi_kernel_release_mutex(mutex: *kernel.sync.Mutex) void {
        mutex.unlock(kernel.Task.getCurrent());
    }

    /// Try to wait for an event (counter > 0) with a millisecond timeout.
    ///
    /// A timeout value of 0xFFFF implies infinite wait.
    ///
    /// The internal counter is decremented by 1 if wait was successful.
    ///
    /// A successful wait is indicated by returning UACPI_TRUE.
    export fn uacpi_kernel_wait_for_event(handle: *anyopaque, timeout: u16) bool {
        core.panicFmt(
            "uacpi_kernel_wait_for_event(handle={}, timeout={})",
            .{ handle, timeout },
            null,
        );
    }

    /// Signal the event object by incrementing its internal counter by 1.
    ///
    /// This function may be used in interrupt contexts.
    export fn uacpi_kernel_signal_event(handle: *anyopaque) void {
        core.panicFmt("uacpi_kernel_signal_event(handle={})", .{handle}, null);
    }

    /// Reset the event counter to 0.
    export fn uacpi_kernel_reset_event(handle: *anyopaque) void {
        core.panicFmt("uacpi_kernel_reset_event(handle={})", .{handle}, null);
    }

    /// Handle a firmware request.
    ///
    /// Currently either a Breakpoint or Fatal operators.
    export fn uacpi_kernel_handle_firmware_request(request: *const FirmwareRequest) Status {
        core.panicFmt(
            "uacpi_kernel_handle_firmware_request(request={})",
            .{request},
            null,
        );
    }

    /// Install an interrupt handler at 'irq', 'ctx' is passed to the provided handler for every invocation.
    ///
    /// 'out_irq_handle' is set to a kernel-implemented value that can be used to refer to this handler from other API.
    export fn uacpi_kernel_install_interrupt_handler(
        irq: u32,
        handler: InterruptHandler,
        ctx: *anyopaque,
        out_irq_handle: **anyopaque,
    ) Status {
        const HandlerWrapper = struct {
            fn HandlerWrapper(
                _: *kernel.Task,
                _: *kernel.arch.interrupts.InterruptFrame,
                _handler: ?*anyopaque,
                _ctx: ?*anyopaque,
            ) void {
                const inner_handler: InterruptHandler = @ptrCast(@alignCast(_handler));
                inner_handler(@ptrCast(_ctx));
            }
        }.HandlerWrapper;

        const interrupt = kernel.arch.interrupts.allocateInterrupt(
            HandlerWrapper,
            @constCast(handler),
            ctx,
        ) catch |err| {
            log.err("failed to allocate interrupt: {}", .{err});
            return .internal_error;
        };

        kernel.arch.interrupts.routeInterrupt(irq, interrupt) catch |err| {
            kernel.arch.interrupts.deallocateInterrupt(interrupt);

            log.err("failed to route interrupt: {}", .{err});
            return .internal_error;
        };

        out_irq_handle.* = @ptrFromInt(@intFromEnum(interrupt));

        return .ok;
    }

    /// Uninstall an interrupt handler.
    ///
    /// 'irq_handle' is the value returned via 'out_irq_handle' during installation.
    export fn uacpi_kernel_uninstall_interrupt_handler(
        _: InterruptHandler,
        irq_handle: *anyopaque,
    ) Status {
        const interrupt: kernel.arch.interrupts.Interrupt = @enumFromInt(@intFromPtr(irq_handle));
        kernel.arch.interrupts.deallocateInterrupt(interrupt);

        return .ok;
    }

    /// Create a kernel spinlock object.
    ///
    /// Unlike other types of locks, spinlocks may be used in interrupt contexts.
    export fn uacpi_kernel_create_spinlock() *kernel.sync.TicketSpinLock {
        const lock = kernel.heap.allocator.create(kernel.sync.TicketSpinLock) catch unreachable;
        lock.* = .{};
        return lock;
    }

    /// Free a kernel spinlock object.
    ///
    /// Unlike other types of locks, spinlocks may be used in interrupt contexts.
    export fn uacpi_kernel_free_spinlock(spinlock: *kernel.sync.TicketSpinLock) void {
        kernel.heap.allocator.destroy(spinlock);
    }

    /// Lock a spinlock.
    ///
    /// These are expected to disable interrupts, returning the previous state of cpu flags, that can be used to
    /// possibly re-enable interrupts if they were enabled before.
    ///
    /// Note that lock is infalliable.
    export fn uacpi_kernel_lock_spinlock(spinlock: *kernel.sync.TicketSpinLock) c_uacpi.uacpi_cpu_flags {
        spinlock.lock(kernel.Task.getCurrent());
        return 0;
    }

    export fn uacpi_kernel_unlock_spinlock(spinlock: *kernel.sync.TicketSpinLock, cpu_flags: c_uacpi.uacpi_cpu_flags) void {
        _ = cpu_flags;
        spinlock.unlock(kernel.Task.getCurrent());
    }

    /// Schedules deferred work for execution.
    ///
    /// Might be invoked from an interrupt context.
    export fn uacpi_kernel_schedule_work(
        work_type: WorkType,
        handler: WorkHandler,
        ctx: *anyopaque,
    ) Status {
        core.panicFmt(
            "uacpi_kernel_schedule_work(work_type={}, handler={}, ctx={})",
            .{ work_type, handler, ctx },
            null,
        );
    }

    /// Waits for two types of work to finish:
    /// 1. All in-flight interrupts installed via uacpi_kernel_install_interrupt_handler
    /// 2. All work scheduled via uacpi_kernel_schedule_work
    ///
    /// Note that the waits must be done in this order specifically.
    export fn uacpi_kernel_wait_for_work_completion() Status {
        core.panic("uacpi_kernel_wait_for_work_completion()", null);
    }
};

comptime {
    _ = &kernel_api; // ensure kernel api is exported
}

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const log = kernel.debug.log.scoped(.uacpi);
const acpi = @import("acpi");
const c_uacpi = @cImport({
    @cInclude("uacpi/event.h");
    @cInclude("uacpi/io.h");
    @cInclude("uacpi/namespace.h");
    @cInclude("uacpi/notify.h");
    @cInclude("uacpi/opregion.h");
    @cInclude("uacpi/osi.h");
    @cInclude("uacpi/resources.h");
    @cInclude("uacpi/sleep.h");
    @cInclude("uacpi/tables.h");
    @cInclude("uacpi/uacpi.h");
    @cInclude("uacpi/utilities.h");
});
