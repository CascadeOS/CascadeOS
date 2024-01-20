// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");
const x86_64 = @import("x86_64.zig");
const SerialPort = @import("SerialPort.zig");

const log = kernel.debug.log.scoped(.init_x86_64);

pub const initLocalInterruptController = x86_64.apic.init.initApicOnProcessor;

pub const EarlyOutputWriter = SerialPort.Writer;
var early_output_serial_port: ?SerialPort = null; // TODO: Put in init_data section

pub fn setupEarlyOutput() linksection(kernel.info.init_code) void {
    early_output_serial_port = SerialPort.init(.COM1, .Baud115200);
}

pub fn getEarlyOutputWriter() ?SerialPort.Writer { // TODO: Put in init_code section
    return if (early_output_serial_port) |output| output.writer() else null;
}

var bootstrap_interrupt_stack align(16) linksection(kernel.info.init_data) = [_]u8{0} ** kernel.Stack.usable_stack_size.value;
var bootstrap_double_fault_stack align(16) linksection(kernel.info.init_data) = [_]u8{0} ** kernel.Stack.usable_stack_size.value;
var bootstrap_non_maskable_interrupt_stack align(16) linksection(kernel.info.init_data) = [_]u8{0} ** kernel.Stack.usable_stack_size.value;

pub fn prepareBootstrapProcessor(bootstrap_processor: *kernel.Processor) linksection(kernel.info.init_code) void {
    bootstrap_processor.arch = .{
        .lapic_id = 0,

        .double_fault_stack = kernel.Stack.fromRangeNoGuard(kernel.VirtualRange.fromSlice(
            u8,
            @as([]u8, &bootstrap_double_fault_stack),
        )),
        .non_maskable_interrupt_stack = kernel.Stack.fromRangeNoGuard(kernel.VirtualRange.fromSlice(
            u8,
            @as([]u8, &bootstrap_non_maskable_interrupt_stack),
        )),
    };

    bootstrap_processor.arch.tss.setPrivilegeStack(.kernel, bootstrap_processor.idle_stack);
}

/// Prepares the provided kernel.Processor for use.
///
/// **WARNING**: This function will panic if the processor cannot be prepared.
pub fn prepareProcessor(processor: *kernel.Processor, processor_descriptor: kernel.boot.ProcessorDescriptor) linksection(kernel.info.init_code) void {
    processor.arch = .{
        .lapic_id = processor_descriptor.lapicId(),

        .double_fault_stack = kernel.Stack.create(true) catch core.panic("unable to create double fault stack"),
        .non_maskable_interrupt_stack = kernel.Stack.create(true) catch core.panic("unable to create non-mackable interrupt stack"),
    };

    processor.arch.tss.setPrivilegeStack(.kernel, processor.idle_stack);
}

pub fn loadProcessor(processor: *kernel.Processor) linksection(kernel.info.init_code) void {
    const arch: *x86_64.ArchProcessor = &processor.arch;

    arch.gdt.load();

    arch.tss.setInterruptStack(.double_fault, arch.double_fault_stack);
    arch.tss.setInterruptStack(.non_maskable_interrupt, arch.non_maskable_interrupt_stack);

    arch.gdt.setTss(&arch.tss);

    x86_64.interrupts.init.loadIdt();

    x86_64.registers.KERNEL_GS_BASE.write(@intFromPtr(processor));
}

pub fn earlyArchInitialization() linksection(kernel.info.init_code) void {
    log.debug("initializing idt", .{});
    x86_64.interrupts.init.initIdt();
}

/// Captures x86_64 system information.
pub fn captureSystemInformation() linksection(kernel.info.init_code) void {
    log.debug("capturing cpuid information", .{});
    x86_64.cpuid.capture();

    const madt = kernel.acpi.init.getTable(kernel.acpi.MADT) orelse core.panic("unable to get MADT");
    const fadt = kernel.acpi.init.getTable(kernel.acpi.FADT) orelse core.panic("unable to get FADT");

    log.debug("capturing FADT information", .{});
    captureFADTInformation(fadt);

    log.debug("capturing MADT information", .{});
    captureMADTInformation(madt);

    log.debug("capturing APIC information", .{});
    x86_64.apic.init.captureApicInformation(fadt, madt);
}

fn captureMADTInformation(madt: *const kernel.acpi.MADT) linksection(kernel.info.init_code) void {
    x86_64.arch_info.have_pic = madt.flags.PCAT_COMPAT;
    log.debug("have pic: {}", .{x86_64.arch_info.have_pic});
}

fn captureFADTInformation(fadt: *const kernel.acpi.FADT) linksection(kernel.info.init_code) void {
    const flags = fadt.IA_PC_BOOT_ARCH;

    x86_64.arch_info.have_ps2_controller = flags.@"8042";
    log.debug("have ps2 controller: {}", .{x86_64.arch_info.have_ps2_controller});

    x86_64.arch_info.msi_supported = !flags.msi_not_supported;
    log.debug("message signaled interrupts supported: {}", .{x86_64.arch_info.msi_supported});

    x86_64.arch_info.have_cmos_rtc = !flags.cmos_rtc_not_present;
    log.debug("have cmos rtc: {}", .{x86_64.arch_info.have_cmos_rtc});
}

/// Configures x86_64 system features.
pub fn configureGlobalSystemFeatures() linksection(kernel.info.init_code) void {
    if (x86_64.arch_info.have_pic) {
        log.debug("disabling pic", .{});
        disablePic();
    }
}

pub fn configureSystemFeaturesForCurrentProcessor(processor: *kernel.Processor) linksection(kernel.info.init_code) void {
    core.debugAssert(processor == x86_64.getProcessor());

    if (x86_64.arch_info.rdtscp) {
        x86_64.registers.IA32_TSC_AUX.write(@intFromEnum(processor.id));
    }

    // CR0
    {
        var cr0 = x86_64.registers.Cr0.read();

        if (!cr0.paging) core.panic("paging not enabled");

        cr0.write_protect = true;

        cr0.write();
        log.debug("CR0 set", .{});
    }

    // EFER
    {
        var efer = x86_64.registers.EFER.read();

        if (!efer.long_mode_active or !efer.long_mode_enable) core.panic("not in long mode");

        if (x86_64.arch_info.syscall) efer.syscall_enable = true;
        if (x86_64.arch_info.execute_disable) efer.no_execute_enable = true;

        efer.write();

        log.debug("EFER set", .{});
    }
}

const portWriteU8 = x86_64.instructions.portWriteU8;

fn disablePic() linksection(kernel.info.init_code) void {
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

    // Mask all x86_64.interrupts
    portWriteU8(PRIMARY_DATA_PORT, 0xFF);
    portWriteU8(0x80, 0); // wait
    portWriteU8(SECONDARY_DATA_PORT, 0xFF);
    portWriteU8(0x80, 0); // wait
}
