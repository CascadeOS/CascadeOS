// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>

/// Attempt to get some form of init output.
///
/// This function can return an architecture specific output if it is available and if not is expected to call into
/// `kernel.init.Output.tryGetSerialOutputFromGenericSources`.
pub fn tryGetSerialOutput() ?kernel.init.Output {
    if (DebugCon.detect()) return DebugCon.output;

    if (kernel.init.Output.tryGetSerialOutputFromGenericSources()) |output| return output;

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
        if (SerialPort.init(
            @intFromEnum(com_port),
            .{ .clock_frequency = .@"1.8432 MHz", .baud_rate = .@"115200" },
        ) catch continue) |serial| {
            static.init_output_serial_port = serial;
            return static.init_output_serial_port.output();
        }
    }

    return null;
}

/// Prepares the provided `Executor` for the bootstrap executor.
pub fn prepareBootstrapExecutor(
    bootstrap_executor: *kernel.Executor,
    architecture_processor_id: u64,
) void {
    const static = struct {
        var bootstrap_double_fault_stack: [kernel.config.kernel_stack_size.value]u8 align(16) = undefined;
        var bootstrap_non_maskable_interrupt_stack: [kernel.config.kernel_stack_size.value]u8 align(16) = undefined;
    };

    prepareExecutorShared(bootstrap_executor, @intCast(architecture_processor_id), .fromRange(
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
pub fn prepareExecutor(executor: *kernel.Executor, architecture_processor_id: u64, current_task: *kernel.Task) void {
    prepareExecutorShared(
        executor,
        @intCast(architecture_processor_id),
        kernel.Stack.createStack(current_task) catch @panic("failed to allocate double fault stack"),
        kernel.Stack.createStack(current_task) catch @panic("failed to allocate NMI stack"),
    );
}

fn prepareExecutorShared(
    executor: *kernel.Executor,
    apic_id: u32,
    double_fault_stack: kernel.Stack,
    non_maskable_interrupt_stack: kernel.Stack,
) void {
    executor.arch = .{
        .apic_id = apic_id,
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
    x64.interrupts.disableInterrupts(); // some CPUs don't have interrupts disabled on load

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

    if (!x64.info.cpu_id.mtrr) {
        @panic("MTRRs not supported");
    }

    const mtrr_cap = lib_x64.registers.IA32_MTRRCAP.read();
    x64.info.mtrr_number_of_variable_registers = mtrr_cap.number_of_variable_range_registers;
    x64.info.mtrr_write_combining_supported = mtrr_cap.write_combining_supported;
    log.debug("mtrr number of variable registers: {}", .{x64.info.mtrr_number_of_variable_registers});
    log.debug("mtrr write combining supported: {}", .{x64.info.mtrr_write_combining_supported});

    if (!x64.info.cpu_id.pat) {
        @panic("PAT not supported");
    }

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
    const madt_acpi_table = kernel.acpi.getTable(kernel.acpi.tables.MADT, 0) orelse
        return error.NoMADT;
    defer madt_acpi_table.deinit();
    const madt = madt_acpi_table.table;

    const fadt_acpi_table = kernel.acpi.getTable(kernel.acpi.tables.FADT, 0) orelse
        return error.NoFADT;
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

    // TODO: be more thorough with setting up these registers

    // CR0
    {
        var cr0 = lib_x64.registers.Cr0.read();

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
        var cr4 = lib_x64.registers.Cr4.read();

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
        var efer = lib_x64.registers.EFER.read();

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
        var pat = lib_x64.registers.PAT.read();

        pat.entry0 = .write_back;
        pat.entry1 = .write_through;
        pat.entry2 = .uncached;
        pat.entry3 = .unchacheable;
        pat.entry4 = .write_back;
        pat.entry5 = .write_through;
        pat.entry6 = .write_combining; // defaults to uncached
        pat.entry7 = .unchacheable;
        lib_x64.registers.PAT.write(pat);

        // flip the page global bit to ensure the PAT is applied
        var cr4 = lib_x64.registers.Cr4.read();
        cr4.page_global = false;
        cr4.write();
        cr4.page_global = true;
        cr4.write();
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

const DebugCon = struct {
    const port = 0xe9;

    fn detect() bool {
        return lib_x64.instructions.portReadU8(port) == port;
    }

    const output: kernel.init.Output = .{
        .writeFn = struct {
            fn writeFn(_: *anyopaque, str: []const u8) void {
                for (0..str.len) |i| {
                    const byte = str[i];

                    if (byte == '\n') {
                        @branchHint(.unlikely);

                        if (i != 0 and str[i - 1] != '\r') {
                            @branchHint(.likely);
                            lib_x64.instructions.portWriteU8(port, '\r');
                        }
                    }

                    lib_x64.instructions.portWriteU8(port, byte);
                }
            }
        }.writeFn,
        .remapFn = struct {
            fn remapFn(_: *anyopaque, _: *kernel.Task) !void {
                return;
            }
        }.remapFn,
        .context = undefined,
    };
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const x64 = @import("x64.zig");
const lib_x64 = @import("x64");
const log = kernel.debug.log.scoped(.init);
const SerialPort = kernel.init.Output.uart.IoPort16550;
