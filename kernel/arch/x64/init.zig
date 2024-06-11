// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const acpi = @import("acpi");

const log = kernel.log.scoped(.init_x64);

const x64 = @import("x64.zig");

var early_output_serial_port: ?x64.SerialPort = null;

/// Attempt to set up some form of early output.
pub fn setupEarlyOutput() void {
    early_output_serial_port = x64.SerialPort.init(.COM1, .Baud115200);
}

/// Acquire a writer for the early output setup by `setupEarlyOutput`.
pub fn getEarlyOutput() ?x64.SerialPort.Writer {
    return if (early_output_serial_port) |output| output.writer() else null;
}

var bootstrap_double_fault_stack: [kernel.config.kernel_stack_size.value]u8 align(16) = undefined;
var bootstrap_non_maskable_interrupt_stack: [kernel.config.kernel_stack_size.value]u8 align(16) = undefined;

/// Prepares the provided `Cpu` for the bootstrap CPU.
pub fn prepareBootstrapCpu(
    bootstrap_cpu: *kernel.Cpu,
) void {
    bootstrap_cpu.arch = .{
        .lapic_id = 0,

        .double_fault_stack = kernel.Stack.fromRange(
            core.VirtualRange.fromSlice(u8, &bootstrap_double_fault_stack),
            core.VirtualRange.fromSlice(u8, &bootstrap_double_fault_stack),
        ),
        .non_maskable_interrupt_stack = kernel.Stack.fromRange(
            core.VirtualRange.fromSlice(u8, &bootstrap_non_maskable_interrupt_stack),
            core.VirtualRange.fromSlice(u8, &bootstrap_non_maskable_interrupt_stack),
        ),
    };

    bootstrap_cpu.arch.tss.setPrivilegeStack(
        .ring0,
        bootstrap_cpu.idle_stack.stack_pointer,
    );
}

/// Prepares the provided kernel.Cpu for use.
///
/// **WARNING**: This function will panic if the cpu cannot be prepared.
pub inline fn prepareCpu(
    cpu: *kernel.Cpu,
    cpu_descriptor: kernel.boot.CpuDescriptor,
    allocateCpuStackFn: fn () anyerror!kernel.Stack,
) void {
    cpu.arch = .{
        .lapic_id = cpu_descriptor.lapicId(),

        .double_fault_stack = allocateCpuStackFn() catch core.panic("unable to create double fault stack"),
        .non_maskable_interrupt_stack = allocateCpuStackFn() catch core.panic("unable to create non-mackable interrupt stack"),
    };

    cpu.arch.tss.setPrivilegeStack(
        .ring0,
        cpu.idle_stack.stack_pointer,
    );
}

/// Load the provided `Cpu` as the current CPU.
pub fn loadCpu(cpu: *kernel.Cpu) void {
    const arch = &cpu.arch;

    arch.gdt.load();

    arch.tss.setInterruptStack(
        @intFromEnum(x64.interrupts.InterruptStackSelector.double_fault),
        arch.double_fault_stack.stack_pointer,
    );
    arch.tss.setInterruptStack(
        @intFromEnum(x64.interrupts.InterruptStackSelector.non_maskable_interrupt),
        arch.non_maskable_interrupt_stack.stack_pointer,
    );

    arch.gdt.setTss(&arch.tss);

    x64.interrupts.init.loadIdt();

    x64.KERNEL_GS_BASE.write(@intFromPtr(cpu));
}

/// Capture any system information that is required for the architecture.
///
/// For example, on x64 this should capture the CPUID information.
pub fn captureSystemInformation() !void {
    log.debug("capturing cpuid information", .{});
    try captureCPUIDInformation();

    const madt = kernel.acpi.init.getTable(acpi.MADT, 0) orelse core.panic("unable to get MADT");
    const fadt = kernel.acpi.init.getTable(acpi.FADT, 0) orelse core.panic("unable to get FADT");

    log.debug("capturing FADT information", .{});
    captureFADTInformation(fadt);

    log.debug("capturing MADT information", .{});
    captureMADTInformation(madt);

    log.debug("capturing APIC information", .{});
    x64.apic.init.captureApicInformation(fadt, madt);
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
pub fn configureGlobalSystemFeatures() void {
    if (x64.info.have_pic) {
        log.debug("disabling pic", .{});
        x64.disablePic();
    }
}

/// Register any architectural time sources.
///
/// For example, on x86_64 this should register the TSC, HPET, PIT, etc.
pub fn registerArchitecturalTimeSources() void {
    x64.tsc.init.registerTimeSource();
    // TODO: TSC, APIC, HPET, PIT, KVMCLOCK
}

pub fn configureSystemFeaturesForCurrentCpu(cpu: *kernel.Cpu) void {
    core.debugAssert(cpu == x64.getCpu());

    if (x64.info.cpu_id.rdtscp) {
        x64.IA32_TSC_AUX.write(@intFromEnum(cpu.id));
    }

    // CR0
    {
        var cr0 = x64.Cr0.read();

        if (!cr0.paging) core.panic("paging not enabled");

        cr0.write_protect = true;

        cr0.write();
        log.debug("CR0 set", .{});
    }

    // EFER
    {
        var efer = x64.EFER.read();

        if (!efer.long_mode_active or !efer.long_mode_enable) core.panic("not in long mode");

        if (x64.info.cpu_id.syscall_sysret) efer.syscall_enable = true;
        if (x64.info.cpu_id.execute_disable) efer.no_execute_enable = true;

        efer.write();

        log.debug("EFER set", .{});
    }
}
