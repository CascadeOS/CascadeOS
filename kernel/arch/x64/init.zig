// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const SerialPort = arch.init.InitOutput.Output.uart.IoPort16550;
const kernel = @import("kernel");
const Task = kernel.Task;
const AcpiTable = kernel.acpi.init.AcpiTable;
const core = @import("core");

const x64 = @import("x64.zig");

const log = kernel.debug.log.scoped(.init_x64);

/// Attempt to get some form of init output.
pub fn tryGetSerialOutput() ?arch.init.InitOutput {
    if (DebugCon.detect()) {
        log.debug("using debug console for serial output", .{});
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
            log.debug("using {t} for serial output", .{com_port});

            static.init_output_serial_port = serial;
            return .{
                .output = static.init_output_serial_port.output(),
                .preference = .prefer_generic,
            };
        }
    }

    return null;
}

/// Prepares the executor as the bootstrap executor.
pub fn prepareBootstrapExecutor(
    executor: *kernel.Executor,
    architecture_processor_id: u64,
) void {
    const static = struct {
        var bootstrap_double_fault_stack: [kernel.config.task.kernel_stack_size.value]u8 align(16) = undefined;
        var bootstrap_non_maskable_interrupt_stack: [kernel.config.task.kernel_stack_size.value]u8 align(16) = undefined;
    };

    prepareExecutorShared(
        executor,
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
pub fn prepareExecutor(executor: *kernel.Executor, architecture_processor_id: u64) void {
    prepareExecutorShared(
        executor,
        @intCast(architecture_processor_id),
        Task.init.earlyCreateStack() catch @panic("failed to allocate double fault stack"),
        Task.init.earlyCreateStack() catch @panic("failed to allocate NMI stack"),
    );
}

fn prepareExecutorShared(
    executor: *kernel.Executor,
    apic_id: u32,
    double_fault_stack: Task.Stack,
    non_maskable_interrupt_stack: Task.Stack,
) void {
    const per_executor: *x64.PerExecutor = .from(executor);

    per_executor.* = .{
        .apic_id = apic_id,
        .double_fault_stack = double_fault_stack,
        .non_maskable_interrupt_stack = non_maskable_interrupt_stack,
    };

    per_executor.tss.setInterruptStack(
        .double_fault,
        per_executor.double_fault_stack.stack_pointer,
    );
    per_executor.tss.setInterruptStack(
        .non_maskable_interrupt,
        per_executor.non_maskable_interrupt_stack.stack_pointer,
    );
}

/// Initialize the executor.
///
/// ** REQUIREMENTS **:
/// - Must be called by the executor represented by `executor`
pub fn initExecutor(executor: *kernel.Executor) void {
    const per_executor: *x64.PerExecutor = .from(executor);

    per_executor.gdt.load();
    per_executor.gdt.setTss(&per_executor.tss);

    x64.interrupts.init.loadIdt();
}

/// Capture any system information that can be without using mmio.
///
/// For example, on x64 this should capture CPUID but not APIC or ACPI information.
pub fn captureEarlySystemInformation() void {
    log.debug("capturing cpuid information", .{});
    x64.info.cpu_id.capture() catch @panic("failed to capture cpuid information");

    if (!x64.info.cpu_id.mtrr) {
        @panic("MTRRs not supported");
    }

    const mtrr_cap = x64.registers.IA32_MTRRCAP.read();
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

    captureXsaveInformation();
}

fn captureXsaveInformation() void {
    if (!x64.info.cpu_id.xsave.supported) @panic("XSAVE is not supported");

    x64.info.xsave.method = if (x64.info.cpu_id.xsave.supported_features.xsaveopt) .xsaveopt else .xsave;
    log.debug("xsave method: {t}", .{x64.info.xsave.method});

    var cr4 = x64.registers.Cr4.read();
    cr4.osxsave = true; // enable `xgetbv`/`xsetbv`
    cr4.write();

    const supported_state = x64.info.cpu_id.xsave.supported_state;

    var xcr0: x64.registers.XCr0 = .read();
    std.debug.assert(supported_state.x87);
    xcr0.x87 = true;
    std.debug.assert(supported_state.sse);
    xcr0.sse = true;
    if (supported_state.avx) xcr0.avx = true;
    if (supported_state.avx_opmask or supported_state.avx_zmm_hi256 or supported_state.avx_hi16_zmm) {
        std.debug.assert(supported_state.avx_opmask and supported_state.avx_zmm_hi256 and supported_state.avx_hi16_zmm);
        xcr0.avx512 = .true;
    }
    x64.info.xsave.xcr0_value = xcr0;
    log.debug("state managed by XSAVE: {f}", .{xcr0});

    // set xcr0 on the bootstrap executor to allow capturing the required size of the XSAVE area
    xcr0.write();

    x64.info.xsave.xsave_area_size = x64.info.cpu_id.xsave.enabledStateSize().?;
    log.debug("size of XSAVE area: {f}", .{x64.info.xsave.xsave_area_size});
}

pub const CaptureSystemInformationOptions = struct {
    x2apic_enabled: bool,
};

/// Capture any system information that needs mmio.
///
/// For example, on x64 this should capture APIC and ACPI information.
pub fn captureSystemInformation(options: CaptureSystemInformationOptions) !void {
    const madt_acpi_table = AcpiTable(kernel.acpi.tables.MADT).get(0) orelse return error.NoMADT;
    defer madt_acpi_table.deinit();
    const madt = madt_acpi_table.table;

    const fadt_acpi_table = AcpiTable(kernel.acpi.tables.FADT).get(0) orelse return error.NoFADT;
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
pub fn configureGlobalSystemFeatures() void {
    if (x64.info.have_pic) {
        log.debug("disabling pic", .{});
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
///
/// This function is called in a few different contexts and must leave the system in a reasonable state for each of them:
///  - By the bootstrap executor after calling `captureEarlySystemInformation`
///  - By the bootstrap executor after calling `captureSystemInformation`
///  - By every executor after `captureSystemInformation` has been called
pub fn configurePerExecutorSystemFeatures() void {
    if (x64.info.cpu_id.rdtscp) {
        x64.registers.IA32_TSC_AUX.write(@intFromEnum(Task.Current.get().knownExecutor().id));
    }

    // TODO: be more thorough with setting up these registers

    // CR0
    {
        var cr0 = x64.registers.Cr0.read();

        if (!cr0.protected_mode_enable) @panic("protected mode not enabled");
        if (!cr0.paging) @panic("paging not enabled");

        cr0.monitor_coprocessor = true;
        cr0.emulate_coprocessor = false;
        cr0.task_switched = true; // disable SSE instructions in the kernel
        cr0.write_protect = true;

        cr0.write();
    }

    // CR4
    {
        var cr4 = x64.registers.Cr4.read();

        if (!cr4.physical_address_extension) @panic("physical address extension not enabled");

        cr4.time_stamp_disable = false;
        cr4.debugging_extensions = true;
        cr4.machine_check_exception = x64.info.cpu_id.mce;
        cr4.page_global = true;
        cr4.performance_monitoring_counter = true;
        cr4.os_fxsave = true;
        cr4.unmasked_exception_support = true;
        cr4.usermode_instruction_prevention = x64.info.cpu_id.umip;
        cr4.level_5_paging = false;
        cr4.fsgsbase = x64.info.cpu_id.fsgsbase;
        cr4.pcid = false; // TODO

        if (!x64.info.cpu_id.xsave.supported) @panic("XSAVE not supported");
        cr4.osxsave = true;

        cr4.supervisor_mode_execution_prevention = x64.info.cpu_id.smep;
        cr4.supervisor_mode_access_prevention = x64.info.cpu_id.smap;

        cr4.write();
    }

    // EFER
    {
        var efer = x64.registers.EFER.read();

        if (!efer.long_mode_active or !efer.long_mode_enable) @panic("not in long mode");

        if (!x64.info.cpu_id.syscall_sysret) @panic("syscall/sysret not supported");
        efer.syscall_enable = true;

        efer.no_execute_enable = x64.info.cpu_id.execute_disable;

        efer.write();
    }

    // SYSCALL/SYSRET
    {
        x64.registers.IA32_SFMASK.write(.{
            .clear_enable_interrupts = true,
            .clear_direction = true,
        });

        x64.registers.IA32_STAR.write(.{
            .syscall_target_eip_32bit = 0, // 32-bit mode not supported
            .syscall_cs_ss = .kernel_code,
            .sysret_cs_ss = .user_code_32bit,
        });

        x64.registers.IA32_LSTAR.write(@intFromPtr(&x64.user.syscallEntry));
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

    // XCr0
    {
        x64.instructions.enableSSEUsage();
        x64.info.xsave.xcr0_value.write();
        x64.instructions.disableSSEUsage();
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
        .name = arch.init.InitOutput.Output.Name.fromSlice("debugcon") catch unreachable,
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
            fn remapFn(_: *anyopaque) !void {
                return;
            }
        }.remapFn,
        .state = undefined,
    };
};
