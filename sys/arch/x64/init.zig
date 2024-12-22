// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

/// The entry point that is exported as `_start` and acts as fallback entry point for unknown bootloaders.
///
/// No bootloader is ever expected to call `_start` and instead should use bootloader specific entry points;
/// meaning this function is not expected to ever be called.
///
/// This function is required to disable interrupts and halt execution at a minimum but may perform any additional
/// debugging and error output if possible.
pub fn unknownBootloaderEntryPoint() callconv(.Naked) noreturn {
    @call(.always_inline, arch.interrupts.disableInterruptsAndHalt, .{});
    unreachable;
}

var opt_early_output_serial_port: ?SerialPort = null;

/// Attempt to set up some form of early output.
pub fn setupEarlyOutput() void {
    for (std.meta.tags(SerialPort.COMPort)) |com_port| {
        if (SerialPort.init(com_port, .Baud115200)) |serial_port| {
            opt_early_output_serial_port = serial_port;
            return;
        }
    }
}

/// Write to early output.
///
/// Cannot fail, any errors are ignored.
pub fn writeToEarlyOutput(bytes: []const u8) void {
    if (opt_early_output_serial_port) |early_output_serial_port| {
        early_output_serial_port.write(bytes);
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

    prepareExecutorShared(
        bootstrap_executor,
        .fromRange(
            .fromSlice(u8, &static.bootstrap_double_fault_stack),
            .fromSlice(u8, &static.bootstrap_double_fault_stack),
        ),
        .fromRange(
            .fromSlice(u8, &static.bootstrap_non_maskable_interrupt_stack),
            .fromSlice(u8, &static.bootstrap_non_maskable_interrupt_stack),
        ),
    );
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

    // TODO: set privilege stack in the TSS
}

/// Load the provided `Executor` as the current executor.
pub fn loadExecutor(executor: *kernel.Executor) void {
    executor.arch.gdt.load();

    executor.arch.gdt.setTss(&executor.arch.tss);

    x64.interrupts.init.loadIdt();

    lib_x64.registers.KERNEL_GS_BASE.write(@intFromPtr(executor));
}

pub const initInterrupts = x64.interrupts.init.initInterrupts;
pub const loadStandardInterruptHandlers = x64.interrupts.init.loadStandardInterruptHandlers;

pub const CaptureSystemInformationOptions = struct {
    x2apic_enabled: bool,
};

/// Capture any system information that is required for the architecture.
///
/// For example, on x64 this should capture the CPUID information.
pub fn captureSystemInformation(
    options: CaptureSystemInformationOptions,
) !void {
    log.debug("capturing cpuid information", .{});
    try captureCPUIDInformation();

    const madt = kernel.acpi.getTable(acpi.MADT, 0) orelse return error.NoMADT;
    const fadt = kernel.acpi.getTable(acpi.FADT, 0) orelse return error.NoFADT;

    log.debug("capturing FADT information", .{});
    captureFADTInformation(fadt);

    log.debug("capturing MADT information", .{});
    captureMADTInformation(madt);

    log.debug("capturing APIC information", .{});
    x64.apic.init.captureApicInformation(fadt, madt, options.x2apic_enabled);
}

fn captureCPUIDInformation() !void {
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

fn captureFADTInformation(fadt: *const acpi.FADT) void {
    const flags = fadt.IA_PC_BOOT_ARCH;

    x64.info.have_ps2_controller = flags.@"8042";
    log.debug("have ps2 controller: {}", .{x64.info.have_ps2_controller});

    x64.info.msi_supported = !flags.msi_not_supported;
    log.debug("message signaled interrupts supported: {}", .{x64.info.msi_supported});

    x64.info.have_cmos_rtc = !flags.cmos_rtc_not_present;
    log.debug("have cmos rtc: {}", .{x64.info.have_cmos_rtc});
}

fn captureMADTInformation(madt: *const acpi.MADT) void {
    x64.info.have_pic = madt.flags.PCAT_COMPAT;
    log.debug("have pic: {}", .{x64.info.have_pic});
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
/// The `executor` provided must be the current executor.
pub fn configurePerExecutorSystemFeatures(executor: *kernel.Executor) void {
    if (x64.info.cpu_id.rdtscp) {
        lib_x64.registers.IA32_TSC_AUX.write(@intFromEnum(executor.id));
    }

    // CR0
    {
        var cr0 = lib_x64.registers.Cr0.read();

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
                // TODO: per branch cold
                self.waitForOutputReady();
                portWriteU8(self._data_port, '\r');
            }

            self.waitForOutputReady();
            portWriteU8(self._data_port, byte);
        }
    }

    fn waitForOutputReady(self: SerialPort) void {
        while (portReadU8(self._line_status_port) & OUTPUT_READY == 0) {
            lib_x64.instructions.pause();
        }
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
const lib_x64 = @import("lib_x64");
const arch = @import("arch");
const log = kernel.log.scoped(.init_x64);
const acpi = @import("acpi");
