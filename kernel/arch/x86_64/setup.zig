// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const x86_64 = @import("x86_64.zig");

const limine = kernel.spec.limine;
const log = kernel.log.scoped(.setup_x86_64);

/// Entry point.
export fn _start() callconv(.Naked) noreturn {
    @call(.never_inline, kernel.setup.setup, .{});
    core.panic("setup returned");
}

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
    log.info("loading gdt", .{});
    gdt.load();

    log.info("fill the tss with interrupt/exception handling stacks", .{});
    tss.setInterruptStack(.exception, &exception_stack);
    tss.setInterruptStack(.double_fault, &double_fault_stack);
    tss.setInterruptStack(.interrupt, &interrupt_stack);
    tss.setInterruptStack(.non_maskable_interrupt, &non_maskable_interrupt_stack);

    log.info("loading tss", .{});
    gdt.setTss(&tss);

    log.info("loading idt", .{});
    x86_64.interrupts.loadIdt();

    log.debug("mapping idt handlers to correct stacks", .{});
    for (0..x86_64.Idt.number_of_handlers) |vector_number| {
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
