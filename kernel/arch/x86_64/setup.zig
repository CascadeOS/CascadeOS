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
    for (0..x86_64.interrupts.number_of_handlers) |vector_number| {
        const vector = @intToEnum(x86_64.interrupts.IdtVector, vector_number);

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

pub fn captureSystemInformation() void {
    x86_64.cpuid.capture();
}

pub fn configureSystemFeatures() void {
    core.panic("UNIMPLEMENTED `configureSystemFeatures`"); // TODO: Implement `configureSystemFeatures`.
}
