// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>

/// Attempt to set up some form of early output.
pub fn registerEarlyOutput() void {
    const static = struct {
        var init_output_serial_port: SerialPort = undefined;
    };

    for (std.meta.tags(SerialPort.COMPort)) |com_port| {
        if (SerialPort.init(com_port, .Baud115200)) |serial| {
            static.init_output_serial_port = serial;

            kernel.init.Output.registerOutput(.{
                .writeFn = struct {
                    fn writeFn(context: *anyopaque, str: []const u8) void {
                        const serial_port: *SerialPort = @ptrCast(@alignCast(context));
                        serial_port.write(str);
                    }
                }.writeFn,
                .context = &static.init_output_serial_port,
            });

            return;
        }
    }
}

/// Prepares the provided `Executor` for the bootstrap executor.
pub fn prepareBootstrapExecutor(
    bootstrap_executor: *kernel.Executor,
) void {
    const static = struct {
        var bootstrap_double_fault_stack: [kernel.config.kernel_stack_size.value]u8 align(16) = undefined;
        var bootstrap_non_maskable_interrupt_stack: [kernel.config.kernel_stack_size.value]u8 align(16) = undefined;
    };

    prepareExecutorShared(bootstrap_executor, .fromRange(
        .fromSlice(u8, &static.bootstrap_double_fault_stack),
        .fromSlice(u8, &static.bootstrap_double_fault_stack),
    ), .fromRange(
        .fromSlice(u8, &static.bootstrap_non_maskable_interrupt_stack),
        .fromSlice(u8, &static.bootstrap_non_maskable_interrupt_stack),
    ));
}

/// Prepares the provided `Executor` for use.
///
/// **WARNING**: This function will panic if the cpu cannot be prepared.
pub fn prepareExecutor(executor: *kernel.Executor, current_task: *kernel.Task) void {
    prepareExecutorShared(
        executor,
        kernel.Stack.createStack(current_task) catch core.panic("failed to allocate double fault stack", null),
        kernel.Stack.createStack(current_task) catch core.panic("failed to allocate NMI stack", null),
    );
}

fn prepareExecutorShared(
    executor: *kernel.Executor,
    double_fault_stack: kernel.Stack,
    non_maskable_interrupt_stack: kernel.Stack,
) void {
    executor.arch = .{
        .double_fault_stack = double_fault_stack,
        .non_maskable_interrupt_stack = non_maskable_interrupt_stack,
    };

    executor.arch.tss.setInterruptStack(
        @intFromEnum(x64.interrupts.InterruptStackSelector.double_fault),
        executor.arch.double_fault_stack.stack_pointer,
    );
    executor.arch.tss.setInterruptStack(
        @intFromEnum(x64.interrupts.InterruptStackSelector.non_maskable_interrupt),
        executor.arch.non_maskable_interrupt_stack.stack_pointer,
    );
}

/// Load the provided `Executor` as the current executor.
pub fn loadExecutor(executor: *kernel.Executor) void {
    executor.arch.gdt.load();
    executor.arch.gdt.setTss(&executor.arch.tss);

    x64.interrupts.init.loadIdt();

    lib_x64.registers.KERNEL_GS_BASE.write(@intFromPtr(executor));
}

/// Capture any system information that can be without using mmio.
///
/// For example, on x64 this should capture CPUID but not APIC or ACPI information.
pub fn captureEarlySystemInformation() !void {
    log.debug("capturing cpuid information", .{});
    try x64.info.cpu_id.capture();

    if (x64.info.cpu_id.determineCrystalFrequency()) |crystal_frequency| {
        const lapic_base_tick_duration_fs = kernel.time.fs_per_s / crystal_frequency;
        x64.info.lapic_base_tick_duration_fs = lapic_base_tick_duration_fs;
        log.debug("lapic base tick duration: {} fs", .{lapic_base_tick_duration_fs});
    }

    if (x64.info.cpu_id.determineTscFrequency()) |tsc_frequency| {
        const tsc_tick_duration_fs = kernel.time.fs_per_s / tsc_frequency;
        x64.info.tsc_tick_duration_fs = tsc_tick_duration_fs;
        log.debug("tsc tick duration: {} fs", .{tsc_tick_duration_fs});
    }
}

pub const CaptureSystemInformationOptions = struct {
    x2apic_enabled: bool,
};

/// Capture any system information that needs mmio.
///
/// For example, on x64 this should capture APIC and ACPI information.
pub fn captureSystemInformation(
    options: CaptureSystemInformationOptions,
) !void {
    const madt_acpi_table = kernel.acpi.getTable(kernel.acpi.MADT, 0) orelse return error.NoMADT;
    defer madt_acpi_table.deinit();
    const madt = madt_acpi_table.table;

    const fadt_acpi_table = kernel.acpi.getTable(kernel.acpi.FADT, 0) orelse return error.NoFADT;
    defer fadt_acpi_table.deinit();
    const fadt = fadt_acpi_table.table;

    log.debug("capturing FADT information", .{});
    {
        const flags = fadt.IA_PC_BOOT_ARCH;

        x64.info.have_ps2_controller = flags.@"8042";
        log.debug("have ps2 controller: {}", .{x64.info.have_ps2_controller});

        x64.info.msi_supported = !flags.msi_not_supported;
        log.debug("message signaled interrupts supported: {}", .{x64.info.msi_supported});

        x64.info.have_cmos_rtc = !flags.cmos_rtc_not_present;
        log.debug("have cmos rtc: {}", .{x64.info.have_cmos_rtc});
    }

    log.debug("capturing MADT information", .{});
    {
        x64.info.have_pic = madt.flags.PCAT_COMPAT;
        log.debug("have pic: {}", .{x64.info.have_pic});
    }

    log.debug("capturing APIC information", .{});
    x64.apic.init.captureApicInformation(fadt, madt, options.x2apic_enabled);

    log.debug("capturing IOAPIC information", .{});
    try x64.ioapic.init.captureMADTInformation(madt);
}

/// Configure any global system features.
pub fn configureGlobalSystemFeatures() !void {
    if (x64.info.have_pic) {
        log.debug("disabling pic", .{});
        lib_x64.disablePic();
    }
}

/// Configure any per-executor system features.
///
/// **WARNING**: The `executor` provided must be the current executor.
pub fn configurePerExecutorSystemFeatures(executor: *const kernel.Executor) void {
    if (x64.info.cpu_id.rdtscp) {
        lib_x64.registers.IA32_TSC_AUX.write(@intFromEnum(executor.id));
    }

    // CR0
    {
        var cr0 = lib_x64.registers.Cr0.read();

        if (!cr0.protected_mode_enable) core.panic("protected mode not enabled", null);
        if (!cr0.paging) core.panic("paging not enabled", null);

        cr0.write_protect = true;

        cr0.write();
    }

    // EFER
    {
        var efer = lib_x64.registers.EFER.read();

        if (!efer.long_mode_active or !efer.long_mode_enable) core.panic("not in long mode", null);

        if (x64.info.cpu_id.syscall_sysret) efer.syscall_enable = true;
        if (x64.info.cpu_id.execute_disable) efer.no_execute_enable = true;

        efer.write();
    }
}

/// Register any architectural time sources.
///
/// For example, on x86_64 this should register the TSC, HPET, PIT, etc.
pub fn registerArchitecturalTimeSources(candidate_time_sources: *kernel.time.init.CandidateTimeSources) void {
    x64.tsc.init.registerTimeSource(candidate_time_sources);
    x64.hpet.init.registerTimeSource(candidate_time_sources);
    x64.apic.init.registerTimeSource(candidate_time_sources);

    // TODO: PIT, KVMCLOCK
}

/// Initialize the local interrupt controller for the current executor.
///
/// For example, on x86_64 this should initialize the APIC.
pub fn initLocalInterruptController() void {
    x64.apic.init.initApicOnCurrentExecutor();
}

/// A *very* basic write only serial port.
const SerialPort = struct {
    _data_port: u16,
    _line_status_port: u16,

    /// Init the serial port at `com_port` with the baud rate `baud_rate`.
    ///
    /// Returns `null` if either the serial port is not connected or is faulty.
    pub fn init(com_port: COMPort, baud_rate: BaudRate) ?SerialPort {
        const data_port_number = @intFromEnum(com_port);

        // write to the scratch register to check if the serial port is connected
        portWriteU8(data_port_number + 7, 0xBA);

        // if the scratch register is not `0xBA` then the serial port is not connected
        if (portReadU8(data_port_number + 7) != 0xBA) return null;

        // disable interrupts
        portWriteU8(data_port_number + 1, 0x00);

        // set baudrate
        portWriteU8(data_port_number + 3, 0x80);
        portWriteU8(data_port_number, @intFromEnum(baud_rate));
        portWriteU8(data_port_number + 1, 0x00);

        // 8 bits, no parity, one stop bit
        portWriteU8(data_port_number + 3, 0x03);

        // enable FIFO
        portWriteU8(data_port_number + 2, 0xC7);

        // mark data terminal ready
        portWriteU8(data_port_number + 4, 0x0B);

        // enable loopback
        portWriteU8(data_port_number + 4, 0x1E);

        // send `0xAE` to the serial port
        portWriteU8(data_port_number, 0xAE);

        // check that the `0xAE` was received due to loopback
        if (portReadU8(data_port_number) != 0xAE) return null;

        // disable loopback
        portWriteU8(data_port_number + 4, 0x0F);

        return .{
            ._data_port = data_port_number,
            ._line_status_port = data_port_number + 5,
        };
    }

    /// Write to the serial port.
    pub fn write(self: SerialPort, bytes: []const u8) void {
        var previous_byte: u8 = 0;

        for (bytes) |byte| {
            defer previous_byte = byte;

            if (byte == '\n' and previous_byte != '\r') {
                @branchHint(.unlikely);
                self.writeByte('\r');
            }

            self.writeByte(byte);
        }
    }

    inline fn writeByte(self: SerialPort, byte: u8) void {
        // wait for output ready
        while (portReadU8(self._line_status_port) & OUTPUT_READY == 0) {}
        portWriteU8(self._data_port, byte);
    }

    pub const COMPort = enum(u16) {
        COM1 = 0x3F8,
        COM2 = 0x2F8,
        COM3 = 0x3E8,
        COM4 = 0x2E8,
    };

    pub const BaudRate = enum(u8) {
        Baud115200 = 1,
        Baud57600 = 2,
        Baud38400 = 3,
        Baud28800 = 4,
    };

    const portReadU8 = lib_x64.instructions.portReadU8;
    const portWriteU8 = lib_x64.instructions.portWriteU8;
    const OUTPUT_READY: u8 = 1 << 5;
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const x64 = @import("x64.zig");
const lib_x64 = @import("x64");
const log = kernel.debug.log.scoped(.init);
