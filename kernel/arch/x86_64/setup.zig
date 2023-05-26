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

const StackSelector = enum(u3) {
    exception = 0,
    double_fault = 1,
    interrupt = 2,
    non_maskable_interrupt = 3,
};

pub fn earlyArchInitialization() void {
    log.info("loading gdt", .{});
    gdt.load();

    log.info("fill the tss with interrupt/exception handling stacks", .{});
    tss.setInterruptStack(@enumToInt(StackSelector.exception), &exception_stack);
    tss.setInterruptStack(@enumToInt(StackSelector.double_fault), &double_fault_stack);
    tss.setInterruptStack(@enumToInt(StackSelector.interrupt), &interrupt_stack);
    tss.setInterruptStack(@enumToInt(StackSelector.non_maskable_interrupt), &non_maskable_interrupt_stack);

    log.info("loading tss", .{});
    gdt.setTss(&tss);
}
