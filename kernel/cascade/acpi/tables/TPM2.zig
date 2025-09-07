// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const cascade = @import("cascade");
const acpi = cascade.acpi;
const core = @import("core");

/// TCG Hardware Interface Description Table Format for TPM 2.0
///
/// [TCG ACPI Specification Version 1.4 Revision 15](https://trustedcomputinggroup.org/wp-content/uploads/TCG-ACPI-Specification-Version-1.4-Revision-15_pub.pdf)
pub const TPM2 = extern struct {
    header: acpi.tables.SharedHeader align(1),

    platform_class: PlatformClass align(1),

    _reserved: u16 align(1),

    /// For interfaces that use the Command Response Buffer, this field SHALL be the physical address of the Control
    /// Area.
    ///
    /// The Control Area contains status registers and the location of the memory buffers for communicating with the
    /// device.
    ///
    /// The area may be in either TPM 2.0 device memory or in memory reserved by the system during boot.
    ///
    /// Interfaces that do not require the Control Area SHALL set this value to zero.
    ///
    /// For a TPM implementation based on the “PC Client PTP” specification the address of the Control Area SHALL be the
    /// address of the TPM_CRB_CTRL_REQ_0 register.
    ///
    /// For FIFO interfaces with a fixed physical base address as defined in “PC Client PTP” specification, this field
    /// may be set to zero.
    ///
    /// For interfaces that use a FIFO interface as defined in the PTP without a fixed base address, this field SHALL be
    /// the base address of the FIFO interface.
    address: core.PhysicalAddress align(1),

    /// The Start Method selector determines which mechanism the device driver uses to notify the TPM 2.0 device that a
    /// command is available for processing.
    start_method: StartMethod align(1),

    /// The content of the Start Method specific parameters is determined by the Start Method used by the system’s TPM
    /// device interface.
    ///
    /// This field contains values that may be used to initiate command processing.
    start_method_specific_parameters: StartMethodSpecificParameters align(1),

    /// LAML
    ///
    /// Identifies the minimum length (in bytes) of the system’s pre-boot TCG event log area.
    ///
    /// Optional. See `logAreaMinimumLength`.
    ///
    /// Note: The “PC Client PFP” specification defines a minimum log size of 64KB.
    _log_area_minimum_length: u32 align(1),

    /// LASA
    ///
    /// Contains the 64-bit physical address of the start of the system's pre-boot TCG event log area.
    ///
    /// Optional. See `logAreaStartAddress`.
    ///
    /// Note: The log area ranges from address LASA to LASA+(LAML-1).
    ///
    /// Note: The format of the TCG event log area is defined in the “PC Client PFP” specification, Section 9.
    /// The crypto agile log format as defined by the “PC Client PFP” specification should be used.
    _log_area_start_address: core.PhysicalAddress align(1),

    pub const SIGNATURE_STRING = "TPM2";

    pub fn logAreaMinimumLength(tpm2: *const TPM2) ?core.Size {
        if (tpm2.header.length < @offsetOf(TPM2, "_log_area_minimum_length") + @sizeOf(u32)) return null;
        return .from(tpm2._log_area_minimum_length, .byte);
    }

    pub fn logAreaStartAddress(tpm2: *const TPM2) ?core.PhysicalAddress {
        if (tpm2.header.length < @offsetOf(TPM2, "_log_area_start_address") + @sizeOf(core.PhysicalAddress)) return null;
        return tpm2._log_area_start_address;
    }

    pub const PlatformClass = enum(u16) {
        client = 0,
        server = 1,
    };

    pub const StartMethod = enum(u32) {
        /// Not allowed (indicates value has not been set).
        not_allowed = 0,
        /// Uses the ACPI Start method.
        acpi_start_method = 2,
        /// Reserved for the Memory mapped I/O Interface (TIS 1.2+Cancel).
        memory_mapped_io = 6,
        /// Uses the Command Response Buffer Interface.
        command_response_buffer = 7,
        /// Uses the Command Response Buffer Interface with the ACPI Start Method.
        command_response_buffer_with_acpi_start_method = 8,
        /// Uses the Command Response Buffer Interface with Arm Secure Monitor or Hypervisor Call (SMC/HVC).
        command_response_buffer_with_smc_hvc = 11,
        /// Uses the FIFO Interface over I2C bus.
        fifo_i2c = 12,
        /// Uses the Command Response Buffer Interface with AMD Mailbox specific notification.
        command_response_buffer_with_amd_mailbox = 13,
        /// Uses the Command Response Buffer Interface with Arm Firmware Framework-A
        command_response_buffer_with_arm_firmware_framework_A = 15,

        _,
    };

    pub const StartMethodSpecificParameters = extern union {
        /// If the Start Method is `acpi_start_method`, then this field is at least four bytes in size and the first
        /// four bytes MUST be all zero.
        _acpi_start_method: [16]u8,

        command_response_buffer_with_smc_hvc: CommandResponseBufferWithSMCHVC,

        command_response_buffer_with_amd_mailbox: CommandResponseBufferWithAMDMailbox,

        command_response_buffer_with_arm_firmware_framework_A: CommandResponseBufferWithARMFirmwareFrameworkA,

        _pad: [16]u8,

        /// Fetch the value of the ACPI Start method.
        pub fn acpiStartMethod(
            self: *const StartMethodSpecificParameters,
            /// The length of the table from the ACPI header.
            table_length: u32,
        ) []const u8 {
            return self._acpi_start_method[0..@min(table_length - @offsetOf(TPM2, "start_method_specific_parameters"), 16)];
        }

        pub const CommandResponseBufferWithSMCHVC = extern struct {
            /// Global System Interrupt Vector of the TPM interrupt.
            ///
            /// MUST be zero if interrupt is not supported
            interrupt: u32 align(1),

            flags: Flags,

            operation_flags: OperationFlags,

            attributes: CommandResponseAttributes,

            _reserved: u8,

            /// This field provides the SMC/HVC call function ID that will invoke the TPM start method.
            ///
            /// Firmware SHALL implement the SMC call as an SMC32 or SMC64 Fast Call, compliant with the
            /// "SMC Calling Convention" specification.
            ///
            /// The call takes no client ID, no Secure OS ID, and no Session ID as parameters.
            ///
            /// The call SHALL return zero.
            ///
            /// The function ID SHALL be allocated from a Service Call Range over which the platform vendor has authority.
            smc_hvc_function_id: u32 align(1),

            pub const Flags = packed struct(u8) {
                /// If `true`, interrupt is supported. Interrupt is always edge triggered when using Arm SMC.
                ///
                /// If `false`, interrupt is not supported and software MUST poll CRB status.
                interrupt_support: bool,

                hypervisor_call: enum(u1) { smc = 0, hvc = 1 },

                /// If `true`, `attributes` field contains valid data.
                ///
                /// If `false`, `attributes` field does not contain valid data.
                attribute_field_valid: bool,

                _reserved: u5,

                pub fn print(
                    flags: Flags,
                    writer: *std.Io.Writer,
                    indent: usize,
                ) !void {
                    const new_indent = indent + 2;

                    try writer.writeAll("Flags{\n");

                    try writer.splatByteAll(' ', new_indent);
                    try writer.print("interrupt_support: {},\n", .{flags.interrupt_support});

                    try writer.splatByteAll(' ', new_indent);
                    try writer.print("hypervisor_call: {t},\n", .{flags.hypervisor_call});

                    try writer.splatByteAll(' ', new_indent);
                    try writer.print("attribute_field_valid: {},\n", .{flags.attribute_field_valid});

                    try writer.splatByteAll(' ', indent);
                    try writer.writeByte('}');
                }
            };

            pub const OperationFlags = packed struct(u8) {
                /// If `true`, CRB interface state transitions include "Idle", "Ready", "Reception", "Execution", and
                /// "Completion".
                ///
                /// If `false`, CRB interface state transitions only include "Ready" and "Execution" states.
                tpm_idle_support: bool,

                _reserved: u7,

                pub fn print(
                    operation_flags: OperationFlags,
                    writer: *std.Io.Writer,
                    _: usize,
                ) !void {
                    try writer.print("OperationFlags{{ tpm_idle_support: {} }}", .{operation_flags.tpm_idle_support});
                }
            };

            pub fn print(
                command_response_buffer_with_smc_hvc: *const CommandResponseBufferWithSMCHVC,
                writer: *std.Io.Writer,
                indent: usize,
            ) !void {
                const new_indent = indent + 2;

                try writer.writeAll("CommandResponseBufferWithSMCHVC{\n");

                try writer.splatByteAll(' ', new_indent);
                try writer.print("interrupt: 0x{x:0>16},\n", .{command_response_buffer_with_smc_hvc.interrupt});

                try writer.splatByteAll(' ', new_indent);
                try writer.writeAll("flags: ");
                try command_response_buffer_with_smc_hvc.flags.print(writer, new_indent);
                try writer.writeAll(",\n");

                try writer.splatByteAll(' ', new_indent);
                try writer.writeAll("operation_flags: ");
                try command_response_buffer_with_smc_hvc.operation_flags.print(writer, new_indent);
                try writer.writeAll(",\n");

                try writer.splatByteAll(' ', new_indent);
                try writer.writeAll("attributes: ");
                try command_response_buffer_with_smc_hvc.attributes.print(writer, new_indent);
                try writer.writeAll(",\n");

                try writer.splatByteAll(' ', new_indent);
                try writer.print(
                    "smc_hvc_function_id: 0x{x},\n",
                    .{command_response_buffer_with_smc_hvc.smc_hvc_function_id},
                );

                try writer.splatByteAll(' ', indent);
                try writer.writeByte('}');
            }

            pub fn format(
                command_response_buffer_with_smc_hvc: *const CommandResponseBufferWithSMCHVC,
                writer: *std.Io.Writer,
            ) !void {
                return command_response_buffer_with_smc_hvc.print(writer, 0);
            }

            comptime {
                core.testing.expectSize(CommandResponseBufferWithSMCHVC, 12);
            }
        };

        pub const CommandResponseBufferWithAMDMailbox = extern struct {
            /// The 64-bit physical address of the 32-bit activation register to indicate a command or register update
            /// is ready in the ControlArea buffer for the TPM.
            ///
            /// Set this 32-bit value to 1 to indicate to the TPM the message is ready.
            tpm_start_address: core.PhysicalAddress align(1),

            /// The 64-bit physical address of the 32-bit reply register to indicate the CRB Control Area or Response
            /// Area has been updated by the TPM.
            ///
            /// TPM sets this 32-bit value to 1 when complete.
            tpm_reply_address: core.PhysicalAddress align(1),

            pub fn print(
                command_response_buffer_with_amd_mailbox: *const CommandResponseBufferWithAMDMailbox,
                writer: *std.Io.Writer,
                indent: usize,
            ) !void {
                const new_indent = indent + 2;

                try writer.writeAll("CommandResponseBufferWithAMDMailbox{\n");

                try writer.splatByteAll(' ', new_indent);
                try writer.print(
                    "tpm_start_address: {f},\n",
                    .{command_response_buffer_with_amd_mailbox.tpm_start_address},
                );

                try writer.splatByteAll(' ', new_indent);
                try writer.print(
                    "tpm_reply_address: {f},\n",
                    .{command_response_buffer_with_amd_mailbox.tpm_reply_address},
                );

                try writer.splatByteAll(' ', indent);
                try writer.writeByte('}');
            }

            pub fn format(
                command_response_buffer_with_amd_mailbox: *const CommandResponseBufferWithAMDMailbox,
                writer: *std.Io.Writer,
            ) !void {
                return command_response_buffer_with_amd_mailbox.print(writer, 0);
            }

            comptime {
                core.testing.expectSize(CommandResponseBufferWithAMDMailbox, 16);
            }
        };

        pub const CommandResponseBufferWithARMFirmwareFrameworkA = extern struct {
            flags: Flags,

            attributes: CommandResponseAttributes,

            /// The partition ID of the FF-A secure partition that implements the TPM service.
            ///
            /// If the partition ID is 0, the client MUST discover the partition ID through FF-A using the UUID defined
            /// in the FF-A start method ABI.
            partition_id: u16 align(1),

            _reserved: u64 align(1),

            pub const Flags = packed struct(u8) {
                /// FF-A Notification Support
                ///
                /// If `true` notifications are supported, otherwise notifications are not supported (software MUST
                /// poll CRB status).
                ff_a_notification_support: bool,

                _reserved: u7,

                pub fn print(
                    flags: Flags,
                    writer: *std.Io.Writer,
                    _: usize,
                ) !void {
                    try writer.print(
                        "Flags{{ ff_a_notification_support: {} }}",
                        .{flags.ff_a_notification_support},
                    );
                }
            };

            pub fn print(
                command_response_buffer_with_arm_firmware_framework_A: *const CommandResponseBufferWithARMFirmwareFrameworkA,
                writer: *std.Io.Writer,
                indent: usize,
            ) !void {
                const new_indent = indent + 2;

                try writer.writeAll("CommandResponseBufferWithARMFirmwareFrameworkA{\n");

                try writer.splatByteAll(' ', new_indent);
                try writer.writeAll("flags: ");
                try command_response_buffer_with_arm_firmware_framework_A.flags.print(writer, new_indent);
                try writer.writeAll(",\n");

                try writer.splatByteAll(' ', new_indent);
                try writer.writeAll("attributes: ");
                try command_response_buffer_with_arm_firmware_framework_A.attributes.print(writer, new_indent);
                try writer.writeAll(",\n");

                try writer.splatByteAll(' ', new_indent);
                try writer.print(
                    "partition_id: 0x{x},\n",
                    .{command_response_buffer_with_arm_firmware_framework_A.partition_id},
                );

                try writer.splatByteAll(' ', indent);
                try writer.writeByte('}');
            }

            pub fn format(
                command_response_buffer_with_arm_firmware_framework_A: *const CommandResponseBufferWithARMFirmwareFrameworkA,
                writer: *std.Io.Writer,
            ) !void {
                return command_response_buffer_with_arm_firmware_framework_A.print(writer, 0);
            }

            comptime {
                core.testing.expectSize(CommandResponseBufferWithARMFirmwareFrameworkA, 12);
            }
        };

        comptime {
            core.testing.expectSize(StartMethodSpecificParameters, 16);
        }
    };

    pub const CommandResponseAttributes = packed struct(u8) {
        /// This field specifies the memory attributes of the CRB control area and command/response buffers
        memory_type: MemoryType,

        /// Specifies the per-locality size of the CRB region encompassing all registers and the command/response
        /// buffer.
        crb_region_size: RegionSize,

        _reserved: u4,

        pub const MemoryType = enum(u2) {
            /// Device non-Gathering, non-Reordering, no Early Write Acknowledgement.
            not_cacheable = 0b00,
            /// Normal memory, Outer non-cacheable, Inner non-cacheable.
            write_combining = 0b01,
            /// Normal Memory, Outer Write-through non-transient, Inner Write-through non-transient.
            write_through = 0b10,
            /// Normal Memory, Outer Write-back non-transient, Inner Write-back non-transient.
            write_back = 0b11,
        };

        pub const RegionSize = enum(u2) {
            @"4KiB" = 0b00,
            @"16KiB" = 0b01,
            @"64KiB" = 0b10,
        };

        pub fn print(
            attributes: CommandResponseAttributes,
            writer: *std.Io.Writer,
            indent: usize,
        ) !void {
            const new_indent = indent + 2;

            try writer.writeAll("CommandResponseAttributes{\n");

            try writer.splatByteAll(' ', new_indent);
            try writer.print("memory_type: {t},\n", .{attributes.memory_type});

            try writer.splatByteAll(' ', new_indent);
            try writer.print("crb_region_size: {t},\n", .{attributes.crb_region_size});

            try writer.splatByteAll(' ', indent);
            try writer.writeByte('}');
        }
    };

    pub fn print(tpm2: *const TPM2, writer: *std.Io.Writer, indent: usize) !void {
        const new_indent = indent + 2;

        try writer.writeAll("TPM2{\n");

        try writer.splatByteAll(' ', new_indent);
        try writer.print("address: {f},\n", .{tpm2.address});

        try writer.splatByteAll(' ', new_indent);
        switch (tpm2.start_method) {
            else => |method| try writer.print("start_method: {t},\n", .{method}),
            _ => |method| try writer.print(
                "start_method (unknown): {d},\n",
                .{@intFromEnum(method)},
            ),
        }

        switch (tpm2.start_method) {
            .acpi_start_method => {
                try writer.splatByteAll(' ', new_indent);
                try writer.print(
                    "start_method_specific_parameters: '{s}',\n",
                    .{tpm2.start_method_specific_parameters.acpiStartMethod(tpm2.header.length)},
                );
            },
            .command_response_buffer_with_smc_hvc => {
                try writer.splatByteAll(' ', new_indent);
                try writer.writeAll("start_method_specific_parameters: ");
                try tpm2.start_method_specific_parameters.command_response_buffer_with_smc_hvc.print(
                    writer,
                    new_indent,
                );
                try writer.writeAll(",\n");
            },
            .command_response_buffer_with_amd_mailbox => {
                try writer.splatByteAll(' ', new_indent);
                try writer.writeAll("start_method_specific_parameters: ");
                try tpm2.start_method_specific_parameters.command_response_buffer_with_amd_mailbox.print(
                    writer,
                    new_indent,
                );
                try writer.writeAll(",\n");
            },
            .command_response_buffer_with_arm_firmware_framework_A => {
                try writer.splatByteAll(' ', new_indent);
                try writer.writeAll("start_method_specific_parameters: ");
                try tpm2.start_method_specific_parameters.command_response_buffer_with_arm_firmware_framework_A.print(
                    writer,
                    new_indent,
                );
                try writer.writeAll(",\n");
            },
            else => {},
        }

        try writer.splatByteAll(' ', new_indent);
        if (tpm2.logAreaMinimumLength()) |laml| {
            try writer.print("log_area_minimum_length: {f},\n", .{laml});
        } else {
            try writer.print("log_area_minimum_length: null,\n", .{});
        }

        try writer.splatByteAll(' ', new_indent);
        if (tpm2.logAreaStartAddress()) |lasa| {
            try writer.print("log_area_start_address: {f},\n", .{lasa});
        } else {
            try writer.print("log_area_start_address: null,\n", .{});
        }

        try writer.splatByteAll(' ', indent);
        try writer.writeByte('}');
    }

    pub inline fn format(tpm2: *const TPM2, writer: *std.Io.Writer) !void {
        return tpm2.print(writer, 0);
    }

    comptime {
        core.testing.expectSize(TPM2, 80);
    }
};
