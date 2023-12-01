// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const x86_64 = @import("x86_64.zig");

const log = kernel.log.scoped(.init);

pub const EarlyOutputWriter = x86_64.serial.SerialPort.Writer;
var early_output_serial_port: ?x86_64.serial.SerialPort = null; // TODO: Put in init_data section

pub fn setupEarlyOutput() linksection(kernel.info.init_code) void {
    early_output_serial_port = x86_64.serial.SerialPort.init(.COM1, .Baud115200);
}

pub fn getEarlyOutputWriter() ?x86_64.serial.SerialPort.Writer { // TODO: Put in init_code section
    return if (early_output_serial_port) |output| output.writer() else null;
}

var bootstrap_interrupt_stack align(16) linksection(kernel.info.init_data) = [_]u8{0} ** kernel.Stack.usable_stack_size.bytes;
var bootstrap_double_fault_stack align(16) linksection(kernel.info.init_data) = [_]u8{0} ** kernel.Stack.usable_stack_size.bytes;
var bootstrap_non_maskable_interrupt_stack align(16) linksection(kernel.info.init_data) = [_]u8{0} ** kernel.Stack.usable_stack_size.bytes;

pub fn prepareBootstrapProcessor(bootstrap_processor: *kernel.Processor) linksection(kernel.info.init_code) void {
    bootstrap_processor._arch = .{
        .double_fault_stack = kernel.Stack.fromRange(kernel.VirtualRange.fromSlice(
            @as([]u8, &bootstrap_double_fault_stack),
        )),
        .non_maskable_interrupt_stack = kernel.Stack.fromRange(kernel.VirtualRange.fromSlice(
            @as([]u8, &bootstrap_non_maskable_interrupt_stack),
        )),
    };

    bootstrap_processor._arch.tss.setPrivilegeStack(.ring0, bootstrap_processor.idle_stack);
}

/// Prepares the provided Processor for use.
///
/// **WARNING**: This function will panic if the processor cannot be prepared.
pub fn prepareProcessor(processor: *kernel.Processor) linksection(kernel.info.init_code) void {
    processor._arch = .{
        .double_fault_stack = kernel.Stack.create() catch core.panic("unable to create double fault stack"),
        .non_maskable_interrupt_stack = kernel.Stack.create() catch core.panic("unable to create non-mackable interrupt stack"),
    };

    processor._arch.tss.setPrivilegeStack(.ring0, processor.idle_stack);
}

pub fn loadProcessor(processor: *kernel.Processor) linksection(kernel.info.init_code) void {
    const arch: *x86_64.ArchProcessor = processor.arch();

    arch.gdt.load();

    arch.tss.setInterruptStack(.double_fault, arch.double_fault_stack);
    arch.tss.setInterruptStack(.non_maskable_interrupt, arch.non_maskable_interrupt_stack);

    arch.gdt.setTss(&arch.tss);

    x86_64.interrupts.loadIdt();

    x86_64.registers.KERNEL_GS_BASE.write(@intFromPtr(processor));
}

pub fn earlyArchInitialization() linksection(kernel.info.init_code) void {
    log.debug("initializing idt", .{});
    x86_64.interrupts.initIdt();
}

/// Captures x86_64 system information.
pub fn captureSystemInformation() linksection(kernel.info.init_code) void {
    log.debug("capturing cpuid information", .{});
    x86_64.cpuid.capture();
}

/// Configures x86_64 system features.
pub fn configureSystemFeatures() linksection(kernel.info.init_code) void {
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

        if (x86_64.info.has_syscall) efer.syscall_enable = true;
        if (x86_64.info.has_execute_disable) efer.no_execute_enable = true;

        efer.write();

        log.debug("EFER set", .{});
    }
}
