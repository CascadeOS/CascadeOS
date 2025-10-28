// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const AcpiTable = cascade.acpi.init.AcpiTable;
const cascade = @import("cascade");
const core = @import("core");
const SerialPort = arch.init.InitOutput.Output.uart.IoPort16550;

const x64 = @import("x64.zig");

const log = cascade.debug.log.scoped(.x64_init);

/// Attempt to get some form of init output.
pub fn tryGetSerialOutput(current_task: *cascade.Task) ?arch.init.InitOutput {
    if (DebugCon.detect()) {
        log.debug(current_task, "using debug console for serial output", .{});
        return .{
            .output = DebugCon.output,
            .preference = .use,
        };
    }

    const static = struct {
        var init_output_serial_port: SerialPort = undefined;

        const COMPort = enum(u16) {
            COM1 = 0x3F8,
            COM2 = 0x2F8,
            COM3 = 0x3E8,
            COM4 = 0x2E8,
        };
    };

    for (std.meta.tags(static.COMPort)) |com_port| {
        if (SerialPort.create(
            @intFromEnum(com_port),
            .{ .clock_frequency = .@"1.8432 MHz", .baud_rate = .@"115200" },
        ) catch continue) |serial| {
            log.debug(current_task, "using {t} for serial output", .{com_port});

            static.init_output_serial_port = serial;
            return .{
                .output = static.init_output_serial_port.output(),
                .preference = .prefer_generic,
            };
        }
    }

    return null;
}

/// Prepares the current executor as the bootstrap executor.
pub fn prepareBootstrapExecutor(
    current_task: *cascade.Task,
    architecture_processor_id: u64,
) void {
    const static = struct {
        var bootstrap_double_fault_stack: [cascade.config.kernel_stack_size.value]u8 align(16) = undefined;
        var bootstrap_non_maskable_interrupt_stack: [cascade.config.kernel_stack_size.value]u8 align(16) = undefined;
    };

    prepareExecutorShared(
        current_task.known_executor.?,
        @intCast(architecture_processor_id),
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
pub fn prepareExecutor(current_task: *cascade.Task, executor: *cascade.Executor, architecture_processor_id: u64) void {
    prepareExecutorShared(
        executor,
        @intCast(architecture_processor_id),
        cascade.Task.init.earlyCreateStack(current_task) catch @panic("failed to allocate double fault stack"),
        cascade.Task.init.earlyCreateStack(current_task) catch @panic("failed to allocate NMI stack"),
    );
}

fn prepareExecutorShared(
    executor: *cascade.Executor,
    apic_id: u32,
    double_fault_stack: cascade.Task.Stack,
    non_maskable_interrupt_stack: cascade.Task.Stack,
) void {
    executor.arch_specific = .{
        .apic_id = apic_id,
        .double_fault_stack = double_fault_stack,
        .non_maskable_interrupt_stack = non_maskable_interrupt_stack,
    };

    executor.arch_specific.tss.setInterruptStack(
        @intFromEnum(x64.interrupts.InterruptStackSelector.double_fault),
        executor.arch_specific.double_fault_stack.stack_pointer,
    );
    executor.arch_specific.tss.setInterruptStack(
        @intFromEnum(x64.interrupts.InterruptStackSelector.non_maskable_interrupt),
        executor.arch_specific.non_maskable_interrupt_stack.stack_pointer,
    );
}

/// Load the executor that `current_task` is running on as the current executor.
pub fn loadExecutor(current_task: *cascade.Task) void {
    const executor = current_task.known_executor.?;

    executor.arch_specific.gdt.load();
    executor.arch_specific.gdt.setTss(&executor.arch_specific.tss);

    x64.interrupts.init.loadIdt();

    x64.registers.KERNEL_GS_BASE.write(@intFromPtr(executor));
}

/// Capture any system information that can be without using mmio.
///
/// For example, on x64 this should capture CPUID but not APIC or ACPI information.
pub fn captureEarlySystemInformation(current_task: *cascade.Task) void {
    log.debug(current_task, "capturing cpuid information", .{});
    x64.info.cpu_id.capture() catch @panic("failed to capture cpuid information");

    if (!x64.info.cpu_id.mtrr) {
        @panic("MTRRs not supported");
    }

    const mtrr_cap = x64.registers.IA32_MTRRCAP.read();
    x64.info.mtrr_number_of_variable_registers = mtrr_cap.number_of_variable_range_registers;
    x64.info.mtrr_write_combining_supported = mtrr_cap.write_combining_supported;
    log.debug(current_task, "mtrr number of variable registers: {}", .{x64.info.mtrr_number_of_variable_registers});
    log.debug(current_task, "mtrr write combining supported: {}", .{x64.info.mtrr_write_combining_supported});

    if (!x64.info.cpu_id.pat) {
        @panic("PAT not supported");
    }

    if (x64.info.cpu_id.determineCrystalFrequency()) |crystal_frequency| {
        const lapic_base_tick_duration_fs = cascade.time.fs_per_s / crystal_frequency;
        x64.info.lapic_base_tick_duration_fs = lapic_base_tick_duration_fs;
        log.debug(current_task, "lapic base tick duration: {} fs", .{lapic_base_tick_duration_fs});
    }

    if (x64.info.cpu_id.determineTscFrequency()) |tsc_frequency| {
        const tsc_tick_duration_fs = cascade.time.fs_per_s / tsc_frequency;
        x64.info.tsc_tick_duration_fs = tsc_tick_duration_fs;
        log.debug(current_task, "tsc tick duration: {} fs", .{tsc_tick_duration_fs});
    }
}

pub const CaptureSystemInformationOptions = struct {
    x2apic_enabled: bool,
};

/// Capture any system information that needs mmio.
///
/// For example, on x64 this should capture APIC and ACPI information.
pub fn captureSystemInformation(
    current_task: *cascade.Task,
    options: CaptureSystemInformationOptions,
) !void {
    const madt_acpi_table = AcpiTable(cascade.acpi.tables.MADT).get(0) orelse return error.NoMADT;
    defer madt_acpi_table.deinit();
    const madt = madt_acpi_table.table;

    const fadt_acpi_table = AcpiTable(cascade.acpi.tables.FADT).get(0) orelse return error.NoFADT;
    defer fadt_acpi_table.deinit();
    const fadt = fadt_acpi_table.table;

    log.debug(current_task, "capturing FADT information", .{});
    {
        const flags = fadt.IA_PC_BOOT_ARCH;

        x64.info.have_ps2_controller = flags.@"8042";
        log.debug(current_task, "have ps2 controller: {}", .{x64.info.have_ps2_controller});

        x64.info.msi_supported = !flags.msi_not_supported;
        log.debug(current_task, "message signaled interrupts supported: {}", .{x64.info.msi_supported});

        x64.info.have_cmos_rtc = !flags.cmos_rtc_not_present;
        log.debug(current_task, "have cmos rtc: {}", .{x64.info.have_cmos_rtc});
    }

    log.debug(current_task, "capturing MADT information", .{});
    {
        x64.info.have_pic = madt.flags.PCAT_COMPAT;
        log.debug(current_task, "have pic: {}", .{x64.info.have_pic});
    }

    log.debug(current_task, "capturing APIC information", .{});
    x64.apic.init.captureApicInformation(current_task, fadt, madt, options.x2apic_enabled);

    log.debug(current_task, "capturing IOAPIC information", .{});
    try x64.ioapic.init.captureMADTInformation(current_task, madt);
}

/// Configure any global system features.
pub fn configureGlobalSystemFeatures(current_task: *cascade.Task) void {
    if (x64.info.have_pic) {
        log.debug(current_task, "disabling pic", .{});
        disablePic();
    }
}

/// Remaps the PIC interrupts to 0x20-0x2f and masks all of them.
fn disablePic() void {
    const portWriteU8 = x64.instructions.portWriteU8;

    const PRIMARY_COMMAND_PORT = 0x20;
    const PRIMARY_DATA_PORT = 0x21;
    const SECONDARY_COMMAND_PORT = 0xA0;
    const SECONDARY_DATA_PORT = 0xA1;

    const CMD_INIT = 0x11;
    const MODE_8086: u8 = 0x01;

    // Tell each PIC that we're going to send it a three-byte initialization sequence on its data port.
    portWriteU8(PRIMARY_COMMAND_PORT, CMD_INIT);
    portWriteU8(0x80, 0); // wait
    portWriteU8(SECONDARY_COMMAND_PORT, CMD_INIT);
    portWriteU8(0x80, 0); // wait

    // Remap master PIC to 0x20
    portWriteU8(PRIMARY_DATA_PORT, 0x20);
    portWriteU8(0x80, 0); // wait

    // Remap slave PIC to 0x28
    portWriteU8(SECONDARY_DATA_PORT, 0x28);
    portWriteU8(0x80, 0); // wait

    // Configure chaining between master and slave
    portWriteU8(PRIMARY_DATA_PORT, 4);
    portWriteU8(0x80, 0); // wait
    portWriteU8(SECONDARY_DATA_PORT, 2);
    portWriteU8(0x80, 0); // wait

    // Set our mode.
    portWriteU8(PRIMARY_DATA_PORT, MODE_8086);
    portWriteU8(0x80, 0); // wait
    portWriteU8(SECONDARY_DATA_PORT, MODE_8086);
    portWriteU8(0x80, 0); // wait

    // Mask all interrupts
    portWriteU8(PRIMARY_DATA_PORT, 0xFF);
    portWriteU8(0x80, 0); // wait
    portWriteU8(SECONDARY_DATA_PORT, 0xFF);
    portWriteU8(0x80, 0); // wait
}

/// Configure any per-executor system features.
pub fn configurePerExecutorSystemFeatures(current_task: *cascade.Task) void {
    if (x64.info.cpu_id.rdtscp) {
        x64.registers.IA32_TSC_AUX.write(@intFromEnum(current_task.known_executor.?.id));
    }

    // TODO: be more thorough with setting up these registers

    // CR0
    {
        var cr0 = x64.registers.Cr0.read();

        if (!cr0.protected_mode_enable) {
            @panic("protected mode not enabled");
        }
        if (!cr0.paging) {
            @panic("paging not enabled");
        }

        cr0.write_protect = true;

        cr0.write();
    }

    // CR4
    {
        var cr4 = x64.registers.Cr4.read();

        if (!cr4.physical_address_extension) {
            @panic("physical address extension not enabled");
        }

        cr4.time_stamp_disable = false;
        cr4.debugging_extensions = true;
        cr4.machine_check_exception = x64.info.cpu_id.mce;
        cr4.page_global = true;
        cr4.performance_monitoring_counter = true;
        cr4.os_fxsave = false; // TODO
        cr4.unmasked_exception_support = false; // TODO
        cr4.usermode_instruction_prevention = x64.info.cpu_id.umip;
        cr4.level_5_paging = false;
        cr4.fsgsbase = x64.info.cpu_id.fsgsbase;
        cr4.pcid = false; // TODO
        cr4.osxsave = false; // TODO
        cr4.supervisor_mode_execution_prevention = x64.info.cpu_id.smep;
        cr4.supervisor_mode_access_prevention = x64.info.cpu_id.smap;

        cr4.write();
    }

    // EFER
    {
        var efer = x64.registers.EFER.read();

        if (!efer.long_mode_active or !efer.long_mode_enable) {
            @panic("not in long mode");
        }

        efer.syscall_enable = x64.info.cpu_id.syscall_sysret;
        efer.no_execute_enable = x64.info.cpu_id.execute_disable;

        efer.write();
    }

    // PAT
    {
        // Match the default PAT configuration on power up as per the SDM, except for entry 6.
        // Using entry 6 as write combining allows us to access it using `PAT = 1 PCD = 1` in the page table, which
        // during the small window after starting an executor and before setting the PAT means accesses to it will be
        // uncached.
        var pat = x64.registers.PAT.read();

        pat.entry0 = .write_back;
        pat.entry1 = .write_through;
        pat.entry2 = .uncached;
        pat.entry3 = .unchacheable;
        pat.entry4 = .write_back;
        pat.entry5 = .write_through;
        pat.entry6 = .write_combining; // defaults to uncached
        pat.entry7 = .unchacheable;
        x64.registers.PAT.write(pat);

        // flip the page global bit to ensure the PAT is applied
        var cr4 = x64.registers.Cr4.read();
        cr4.page_global = false;
        cr4.write();
        cr4.page_global = true;
        cr4.write();
    }
}

/// Register any architectural time sources.
///
/// For example, on x86_64 this should register the TSC, HPET, PIT, etc.
pub fn registerArchitecturalTimeSources(
    current_task: *cascade.Task,
    candidate_time_sources: *cascade.time.init.CandidateTimeSources,
) void {
    x64.tsc.init.registerTimeSource(current_task, candidate_time_sources);
    x64.hpet.init.registerTimeSource(current_task, candidate_time_sources);
    x64.apic.init.registerTimeSource(current_task, candidate_time_sources);

    // TODO: PIT, KVMCLOCK
}

/// Initialize the local interrupt controller for the current executor.
///
/// For example, on x86_64 this should initialize the APIC.
pub fn initLocalInterruptController() void {
    x64.apic.init.initApicOnCurrentExecutor();
}

const DebugCon = struct {
    const port = 0xe9;

    fn detect() bool {
        return x64.instructions.portReadU8(port) == port;
    }

    fn writeStr(str: []const u8) void {
        for (0..str.len) |i| {
            const byte = str[i];

            if (byte == '\n') {
                @branchHint(.unlikely);

                const newline_first_or_only = str.len == 1 or i == 0;

                if (newline_first_or_only or str[i - 1] != '\r') {
                    @branchHint(.likely);
                    x64.instructions.portWriteU8(port, '\r');
                }
            }

            x64.instructions.portWriteU8(port, byte);
        }
    }

    const output: arch.init.InitOutput.Output = .{
        .writeFn = struct {
            fn writeFn(_: *anyopaque, str: []const u8) void {
                writeStr(str);
            }
        }.writeFn,
        .splatFn = struct {
            fn splatFn(_: *anyopaque, str: []const u8, splat: usize) void {
                for (0..splat) |_| writeStr(str);
            }
        }.splatFn,
        .remapFn = struct {
            fn remapFn(_: *anyopaque, _: *cascade.Task) !void {
                return;
            }
        }.remapFn,
        .state = undefined,
    };
};
