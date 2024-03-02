// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");
const x86_64 = @import("x86_64.zig");
const SerialPort = @import("SerialPort.zig");
const acpi = @import("acpi");

const log = kernel.debug.log.scoped(.init_x86_64);

pub const EarlyOutputWriter = SerialPort.Writer;
var early_output_serial_port: ?SerialPort = null;

pub fn setupEarlyOutput() void {
    early_output_serial_port = SerialPort.init(.COM1, .Baud115200);
}

pub fn getEarlyOutputWriter() ?SerialPort.Writer {
    return if (early_output_serial_port) |output| output.writer() else null;
}

var bootstrap_interrupt_stack align(16) = [_]u8{0} ** kernel.Stack.usable_stack_size.value;
var bootstrap_double_fault_stack align(16) = [_]u8{0} ** kernel.Stack.usable_stack_size.value;
var bootstrap_non_maskable_interrupt_stack align(16) = [_]u8{0} ** kernel.Stack.usable_stack_size.value;

pub fn prepareBootstrapProcessor(bootstrap_processor: *kernel.Processor) void {
    bootstrap_processor.arch = .{
        .lapic_id = 0,

        .double_fault_stack = kernel.Stack.fromRangeNoGuard(core.VirtualRange.fromSlice(
            u8,
            @as([]u8, &bootstrap_double_fault_stack),
        )),
        .non_maskable_interrupt_stack = kernel.Stack.fromRangeNoGuard(core.VirtualRange.fromSlice(
            u8,
            @as([]u8, &bootstrap_non_maskable_interrupt_stack),
        )),
    };

    bootstrap_processor.arch.tss.setPrivilegeStack(
        .ring0,
        bootstrap_processor.idle_stack.stack_pointer,
    );
}

/// Prepares the provided kernel.Processor for use.
///
/// **WARNING**: This function will panic if the processor cannot be prepared.
pub fn prepareProcessor(processor: *kernel.Processor, processor_descriptor: kernel.boot.ProcessorDescriptor) void {
    processor.arch = .{
        .lapic_id = processor_descriptor.lapicId(),

        .double_fault_stack = kernel.Stack.create(true) catch core.panic("unable to create double fault stack"),
        .non_maskable_interrupt_stack = kernel.Stack.create(true) catch core.panic("unable to create non-mackable interrupt stack"),
    };

    processor.arch.tss.setPrivilegeStack(
        .ring0,
        processor.idle_stack.stack_pointer,
    );
}

pub fn loadProcessor(processor: *kernel.Processor) void {
    const arch: *x86_64.ArchProcessor = &processor.arch;

    arch.gdt.load();

    arch.tss.setInterruptStack(
        @intFromEnum(x86_64.interrupts.InterruptStackSelector.double_fault),
        arch.double_fault_stack.stack_pointer,
    );
    arch.tss.setInterruptStack(
        @intFromEnum(x86_64.interrupts.InterruptStackSelector.non_maskable_interrupt),
        arch.non_maskable_interrupt_stack.stack_pointer,
    );

    arch.gdt.setTss(&arch.tss);

    x86_64.interrupts.init.loadIdt();

    x86_64.KERNEL_GS_BASE.write(@intFromPtr(processor));
}

pub fn earlyArchInitialization() void {
    log.debug("initializing idt", .{});
    x86_64.interrupts.init.initIdt();
}

/// Captures x86_64 system information.
pub fn captureSystemInformation() void {
    log.debug("capturing cpuid information", .{});
    x86_64.cpuid.capture();

    const madt = kernel.acpi.init.getTable(acpi.MADT) orelse core.panic("unable to get MADT");
    const fadt = kernel.acpi.init.getTable(acpi.FADT) orelse core.panic("unable to get FADT");

    log.debug("capturing FADT information", .{});
    captureFADTInformation(fadt);

    log.debug("capturing MADT information", .{});
    captureMADTInformation(madt);

    log.debug("capturing APIC information", .{});
    x86_64.apic.init.captureApicInformation(fadt, madt);
}

fn captureMADTInformation(madt: *const acpi.MADT) void {
    x86_64.arch_info.have_pic = madt.flags.PCAT_COMPAT;
    log.debug("have pic: {}", .{x86_64.arch_info.have_pic});
}

fn captureFADTInformation(fadt: *const acpi.FADT) void {
    const flags = fadt.IA_PC_BOOT_ARCH;

    x86_64.arch_info.have_ps2_controller = flags.@"8042";
    log.debug("have ps2 controller: {}", .{x86_64.arch_info.have_ps2_controller});

    x86_64.arch_info.msi_supported = !flags.msi_not_supported;
    log.debug("message signaled interrupts supported: {}", .{x86_64.arch_info.msi_supported});

    x86_64.arch_info.have_cmos_rtc = !flags.cmos_rtc_not_present;
    log.debug("have cmos rtc: {}", .{x86_64.arch_info.have_cmos_rtc});
}

/// Configures x86_64 system features.
pub fn configureGlobalSystemFeatures() void {
    if (x86_64.arch_info.have_pic) {
        log.debug("disabling pic", .{});
        x86_64.disablePic();
    }
}

pub fn configureSystemFeaturesForCurrentProcessor(processor: *kernel.Processor) void {
    core.debugAssert(processor == x86_64.getProcessor());

    if (x86_64.arch_info.rdtscp) {
        x86_64.IA32_TSC_AUX.write(@intFromEnum(processor.id));
    }

    // CR0
    {
        var cr0 = x86_64.Cr0.read();

        if (!cr0.paging) core.panic("paging not enabled");

        cr0.write_protect = true;

        cr0.write();
        log.debug("CR0 set", .{});
    }

    // EFER
    {
        var efer = x86_64.EFER.read();

        if (!efer.long_mode_active or !efer.long_mode_enable) core.panic("not in long mode");

        if (x86_64.arch_info.syscall) efer.syscall_enable = true;
        if (x86_64.arch_info.execute_disable) efer.no_execute_enable = true;

        efer.write();

        log.debug("EFER set", .{});
    }
}

/// Register any architectural time sources.
///
/// For example, on x86_64 this should register the TSC, HPET, PIT, etc.
pub fn registerArchitecturalTimeSources() void {
    x86_64.tsc.init.registerTimeSource();
    x86_64.apic.init.registerTimeSource();
    x86_64.hpet.init.registerTimeSource();

    // TODO: PIT, KVMCLOCK
}
