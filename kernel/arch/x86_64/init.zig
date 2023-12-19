// SPDX-License-Identifier: MIT

const arch_info = x86_64.arch_info;
const ArchProcessor = x86_64.ArchProcessor;
const core = @import("core");
const cpuid = x86_64.cpuid;
const info = kernel.info;
const instructions = x86_64.instructions;
const interrupts = x86_64.interrupts;
const kernel = @import("kernel");
const Processor = kernel.Processor;
const registers = x86_64.registers;
const SerialPort = x86_64.serial.SerialPort;
const std = @import("std");
const task = kernel.task;
const VirtualRange = kernel.VirtualRange;
const x86_64 = @import("x86_64.zig");

const log = kernel.debug.log.scoped(.init_x86_64);

pub const EarlyOutputWriter = SerialPort.Writer;
var early_output_serial_port: ?SerialPort = null; // TODO: Put in init_data section

pub fn setupEarlyOutput() linksection(info.init_code) void {
    early_output_serial_port = SerialPort.init(.COM1, .Baud115200);
}

pub fn getEarlyOutputWriter() ?SerialPort.Writer { // TODO: Put in init_code section
    return if (early_output_serial_port) |output| output.writer() else null;
}

var bootstrap_interrupt_stack align(16) linksection(info.init_data) = [_]u8{0} ** task.Stack.usable_stack_size.bytes;
var bootstrap_double_fault_stack align(16) linksection(info.init_data) = [_]u8{0} ** task.Stack.usable_stack_size.bytes;
var bootstrap_non_maskable_interrupt_stack align(16) linksection(info.init_data) = [_]u8{0} ** task.Stack.usable_stack_size.bytes;

pub fn prepareBootstrapProcessor(bootstrap_processor: *Processor) linksection(info.init_code) void {
    bootstrap_processor.arch = .{
        .double_fault_stack = task.Stack.fromRangeNoGuard(VirtualRange.fromSlice(
            u8,
            @as([]u8, &bootstrap_double_fault_stack),
        )),
        .non_maskable_interrupt_stack = task.Stack.fromRangeNoGuard(VirtualRange.fromSlice(
            u8,
            @as([]u8, &bootstrap_non_maskable_interrupt_stack),
        )),
    };

    bootstrap_processor.arch.tss.setPrivilegeStack(.kernel, bootstrap_processor.idle_stack);
}

/// Prepares the provided Processor for use.
///
/// **WARNING**: This function will panic if the processor cannot be prepared.
pub fn prepareProcessor(processor: *Processor) linksection(info.init_code) void {
    processor.arch = .{
        .double_fault_stack = task.Stack.create(true) catch core.panic("unable to create double fault stack"),
        .non_maskable_interrupt_stack = task.Stack.create(true) catch core.panic("unable to create non-mackable interrupt stack"),
    };

    processor.arch.tss.setPrivilegeStack(.kernel, processor.idle_stack);
}

pub fn loadProcessor(processor: *Processor) linksection(info.init_code) void {
    const arch: *ArchProcessor = &processor.arch;

    arch.gdt.load();

    arch.tss.setInterruptStack(.double_fault, arch.double_fault_stack);
    arch.tss.setInterruptStack(.non_maskable_interrupt, arch.non_maskable_interrupt_stack);

    arch.gdt.setTss(&arch.tss);

    interrupts.loadIdt();

    registers.KERNEL_GS_BASE.write(@intFromPtr(processor));
}

pub fn earlyArchInitialization() linksection(info.init_code) void {
    log.debug("initializing idt", .{});
    interrupts.initIdt();

    log.debug("disabling pic", .{});
    disablePic();
}

/// Captures x86_64 system information.
pub fn captureSystemInformation() linksection(info.init_code) void {
    log.debug("capturing cpuid information", .{});
    cpuid.capture();
}

/// Configures x86_64 system features.
pub fn configureSystemFeatures() linksection(info.init_code) void {
    // CR0
    {
        var cr0 = registers.Cr0.read();

        if (!cr0.paging) core.panic("paging not enabled");

        cr0.write_protect = true;

        cr0.write();
        log.debug("CR0 set", .{});
    }

    // EFER
    {
        var efer = registers.EFER.read();

        if (!efer.long_mode_active or !efer.long_mode_enable) core.panic("not in long mode");

        if (arch_info.has_syscall) efer.syscall_enable = true;
        if (arch_info.has_execute_disable) efer.no_execute_enable = true;

        efer.write();

        log.debug("EFER set", .{});
    }
}

const portWriteU8 = instructions.portWriteU8;

fn disablePic() linksection(info.init_code) void {
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
