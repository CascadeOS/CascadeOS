// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const x86_64 = @import("x86_64.zig");

const log = kernel.log.scoped(.setup_x86_64);

pub const EarlyOutputWriter = x86_64.serial.SerialPort.Writer;
var early_output_serial_port: x86_64.serial.SerialPort = undefined;

pub fn setupEarlyOutput() void {
    early_output_serial_port = x86_64.serial.SerialPort.init(.COM1, .Baud115200);
}

pub inline fn getEarlyOutputWriter() x86_64.serial.SerialPort.Writer {
    return early_output_serial_port.writer();
}

var gdt: x86_64.Gdt = .{};
var tss: x86_64.Tss = .{};

const page_size = core.Size.from(4, .kib);
const kernel_stack_size = page_size.multiply(4);

var exception_stack align(16) = [_]u8{0} ** kernel_stack_size.bytes;
var double_fault_stack align(16) = [_]u8{0} ** kernel_stack_size.bytes;
var interrupt_stack align(16) = [_]u8{0} ** kernel_stack_size.bytes;
var non_maskable_interrupt_stack align(16) = [_]u8{0} ** kernel_stack_size.bytes;

pub fn earlyArchInitialization() void {
    log.debug("loading gdt", .{});
    gdt.load();

    log.debug("preparing interrupt and exception stacks", .{});
    tss.setInterruptStack(.exception, &exception_stack);
    tss.setInterruptStack(.double_fault, &double_fault_stack);
    tss.setInterruptStack(.interrupt, &interrupt_stack);
    tss.setInterruptStack(.non_maskable_interrupt, &non_maskable_interrupt_stack);

    log.debug("loading tss", .{});
    gdt.setTss(&tss);

    log.debug("loading idt", .{});
    x86_64.interrupts.loadIdt();

    log.debug("mapping idt vectors to the prepared stacks", .{});
    mapIdtHandlers();
}

fn mapIdtHandlers() void {
    for (0..x86_64.interrupts.number_of_handlers) |vector_number| {
        const vector: x86_64.interrupts.IdtVector = @enumFromInt(vector_number);

        if (vector == .double_fault) {
            x86_64.interrupts.setVectorStack(vector, .double_fault);
            continue;
        }

        if (vector == .non_maskable_interrupt) {
            x86_64.interrupts.setVectorStack(vector, .non_maskable_interrupt);
            continue;
        }

        if (vector.isException()) {
            x86_64.interrupts.setVectorStack(vector, .exception);
            continue;
        }

        x86_64.interrupts.setVectorStack(vector, .interrupt);
    }
}

/// Captures x86_64 system information.
pub fn captureSystemInformation() void {
    log.debug("capturing cpuid information", .{});
    x86_64.cpuid.capture();
}

/// Configures x86_64 system features.
pub fn configureSystemFeatures() void {
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
