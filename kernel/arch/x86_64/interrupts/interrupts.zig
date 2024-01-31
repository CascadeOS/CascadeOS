// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");
const x86_64 = @import("../x86_64.zig");

const Idt = @import("Idt.zig");
const fixed_handlers = @import("fixed_handlers.zig");

pub const number_of_handlers = Idt.number_of_handlers;

const log = kernel.debug.log.scoped(.interrupts_x86_64);

var idt: Idt = .{};
const raw_handlers = makeRawHandlers();
var handlers = [_]InterruptHandler{fixed_handlers.unhandledInterrupt} ** number_of_handlers;

pub const InterruptHandler = *const fn (interrupt_frame: *InterruptFrame) void;

/// Sets the interrupt stack for the given interrupt vector.
fn setVectorStack(vector: IdtVector, stack_selector: InterruptStackSelector) void {
    idt.handlers[@intFromEnum(vector)].setStack(@intFromEnum(stack_selector));
}

pub const InterruptStackSelector = enum(u3) {
    double_fault,
    non_maskable_interrupt,
};

/// Creates an array of raw interrupt handlers, one for each vector.
fn makeRawHandlers() [number_of_handlers](*const fn () callconv(.Naked) void) {
    var raw_handlers_temp: [number_of_handlers](*const fn () callconv(.Naked) void) = undefined;

    comptime var i = 0;
    inline while (i < number_of_handlers) : (i += 1) {
        const vector_number: u8 = @intCast(i);
        const idt_vector: IdtVector = @enumFromInt(vector_number);

        // if the cpu does not push an error code, we push a dummy error code to ensure the stack
        // is always aligned in the same way for every vector
        const error_code_asm = if (comptime !idt_vector.hasErrorCode()) "push $0\n" else "";
        const vector_number_asm = std.fmt.comptimePrint("push ${d}", .{vector_number});
        const data_selector_asm = std.fmt.comptimePrint("mov ${d}, %%ax", .{x86_64.Gdt.kernel_data_selector});

        const rawInterruptHandler = struct {
            fn rawInterruptHandler() callconv(.Naked) void {
                asm volatile (error_code_asm ++
                        vector_number_asm ++ "\n" ++
                        \\push %%rax
                        \\push %%rbx
                        \\push %%rcx
                        \\push %%rdx
                        \\push %%rbp
                        \\push %%rsi
                        \\push %%rdi
                        \\push %%r8
                        \\push %%r9
                        \\push %%r10
                        \\push %%r11
                        \\push %%r12
                        \\push %%r13
                        \\push %%r14
                        \\push %%r15
                        \\mov %%ds, %%rax
                        \\push %%rax
                        \\mov %%es, %%rax
                        \\push %%rax
                        \\mov %%rsp, %%rdi
                    ++ "\n" ++ data_selector_asm ++ "\n" ++
                        \\mov %%ax, %%es
                        \\mov %%ax, %%ds
                        \\call interruptHandler
                        \\pop %%rax
                        \\mov %%rax, %%es
                        \\pop %%rax
                        \\mov %%rax, %%ds
                        \\pop %%r15
                        \\pop %%r14
                        \\pop %%r13
                        \\pop %%r12
                        \\pop %%r11
                        \\pop %%r10
                        \\pop %%r9
                        \\pop %%r8
                        \\pop %%rdi
                        \\pop %%rsi
                        \\pop %%rbp
                        \\pop %%rdx
                        \\pop %%rcx
                        \\pop %%rbx
                        \\pop %%rax
                        \\add $16, %%rsp
                        \\iretq
                );
            }
        }.rawInterruptHandler;

        raw_handlers_temp[vector_number] = rawInterruptHandler;
    }

    return raw_handlers_temp;
}

pub const InterruptFrame = extern struct {
    es: u64,
    ds: u64,
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rdi: u64,
    rsi: u64,
    rbp: u64,
    rdx: u64,
    rcx: u64,
    rbx: u64,
    rax: u64,
    padded_vector_number: u64,
    error_code: u64,
    rip: u64,
    cs: u64,
    rflags: x86_64.registers.RFlags,
    rsp: u64,
    ss: u64,

    /// Gets the interrupt vector for this interrupt frame.
    pub fn getIdtVector(self: *const InterruptFrame) IdtVector {
        return @enumFromInt(@as(u8, @intCast(self.padded_vector_number)));
    }

    /// Checks if this interrupt occurred in kernel mode.
    pub inline fn isKernel(self: *const InterruptFrame) bool {
        return self.cs == x86_64.Gdt.kernel_code_selector;
    }

    /// Checks if this interrupt occurred in user mode.
    pub inline fn isUser(self: *const InterruptFrame) bool {
        return self.cs == x86_64.Gdt.user_code_selector;
    }

    pub fn print(
        value: *const InterruptFrame,
        writer: anytype,
    ) !void {
        const padding = "  ";

        try writer.writeAll("InterruptFrame{\n");

        try writer.print(comptime padding ++ "Error Code: {},\n", .{value.error_code});
        try writer.print(comptime padding ++ "Vector Number: {},\n", .{value.vector_number});

        try writer.print(comptime padding ++ "cs: {},\n", .{value.cs});
        try writer.print(comptime padding ++ "ss: {},\n", .{value.ss});
        try writer.print(comptime padding ++ "ds: {},\n", .{value.ds});
        try writer.print(comptime padding ++ "es: {},\n", .{value.es});
        try writer.print(comptime padding ++ "rsp: 0x{x},\n", .{value.rsp});
        try writer.print(comptime padding ++ "rip: 0x{x},\n", .{value.rip});
        try writer.print(comptime padding ++ "rax: 0x{x},\n", .{value.rax});
        try writer.print(comptime padding ++ "rbx: 0x{x},\n", .{value.rbx});
        try writer.print(comptime padding ++ "rcx: 0x{x},\n", .{value.rcx});
        try writer.print(comptime padding ++ "rdx: 0x{x},\n", .{value.rdx});
        try writer.print(comptime padding ++ "rbp: 0x{x},\n", .{value.rbp});
        try writer.print(comptime padding ++ "rsi: 0x{x},\n", .{value.rsi});
        try writer.print(comptime padding ++ "rdi: 0x{x},\n", .{value.rdi});
        try writer.print(comptime padding ++ "r8: 0x{x},\n", .{value.r8});
        try writer.print(comptime padding ++ "r9: 0x{x},\n", .{value.r9});
        try writer.print(comptime padding ++ "r10: 0x{x},\n", .{value.r10});
        try writer.print(comptime padding ++ "r11: 0x{x},\n", .{value.r11});
        try writer.print(comptime padding ++ "r12: 0x{x},\n", .{value.r12});
        try writer.print(comptime padding ++ "r13: 0x{x},\n", .{value.r13});
        try writer.print(comptime padding ++ "r14: 0x{x},\n", .{value.r14});
        try writer.print(comptime padding ++ "r15: 0x{x},\n", .{value.r15});

        try writer.print(comptime padding ++ "{},\n", .{value.rflags});

        try writer.writeAll("}");
    }

    pub inline fn format(
        value: *const InterruptFrame,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        return print(value, writer);
    }
};

export fn interruptHandler(interrupt_frame: *InterruptFrame) void {
    handlers[@as(u8, @intCast(interrupt_frame.padded_vector_number))](interrupt_frame);

    // ensure interrupts are disabled when restoring the state before iret
    disableInterrupts();
}

pub const IdtVector = enum(u8) {
    divide = 0,
    debug = 1,
    non_maskable_interrupt = 2,
    breakpoint = 3,
    overflow = 4,
    bound_range = 5,
    invalid_opcode = 6,
    device_not_available = 7,
    double_fault = 8,
    coprocessor_segment_overrun = 9,
    invalid_tss = 10,
    segment_not_present = 11,
    stack_fault = 12,
    general_protection = 13,
    page_fault = 14,
    _reserved1 = 15,
    x87_floating_point = 16,
    alignment_check = 17,
    machine_check = 18,
    simd_floating_point = 19,
    virtualization = 20,
    control_protection = 21,
    _reserved2 = 22,
    _reserved3 = 23,
    _reserved4 = 24,
    _reserved5 = 25,
    _reserved6 = 26,
    _reserved7 = 27,
    hypervisor_injection = 28,
    vmm_communication = 29,
    security = 30,
    _reserved8 = 31,

    pic_pit = 32,
    pic_keyboard = 33,
    pic_cascade = 34,
    pic_com2 = 35,
    pic_com1 = 36,
    pic_lpt2 = 37,
    pic_floppy = 38,
    pic_lpt1 = 39,
    pic_rtc = 40,
    pic_free1 = 41,
    pic_free2 = 42,
    pic_free3 = 43,
    pic_ps2mouse = 44,
    pic_fpu = 45,
    pic_primary_ata = 46,
    pic_secondary_ata = 47,

    scheduler = 48,

    spurious_interrupt = 255,

    _,

    /// Checks if the given interrupt vector is an exception.
    pub fn isException(self: IdtVector) bool {
        if (@intFromEnum(self) <= @intFromEnum(IdtVector._reserved8)) {
            return self != IdtVector.non_maskable_interrupt;
        }
        return false;
    }

    /// Checks if the given interrupt vector pushes an error code.
    pub fn hasErrorCode(self: IdtVector) bool {
        return switch (@intFromEnum(self)) {
            // Exceptions
            0x00...0x07 => false,
            0x08 => true,
            0x09 => false,
            0x0A...0x0E => true,
            0x0F...0x10 => false,
            0x11 => true,
            0x12...0x14 => false,
            //0x15 ... 0x1D => unreachable,
            0x1E => true,
            //0x1F          => unreachable,

            // Other interrupts
            else => false,
        };
    }
};

/// Are interrupts enabled?
pub inline fn interruptsEnabled() bool {
    return x86_64.registers.RFlags.read().interrupt;
}

/// Enable interrupts.
pub inline fn enableInterrupts() void {
    asm volatile ("sti");
}

/// Disable interrupts.
pub inline fn disableInterrupts() void {
    asm volatile ("cli");
}

/// Disable interrupts and put the CPU to sleep.
pub fn disableInterruptsAndHalt() noreturn {
    while (true) {
        asm volatile ("cli; hlt");
    }
}

pub const setTaskPriority = x86_64.apic.setTaskPriority;
pub const panicInterruptOtherCores = x86_64.apic.panicInterruptOtherCores;

pub const init = struct {
    /// Load the IDT on this core.
    pub fn loadIdt() linksection(kernel.info.init_code) void {
        idt.load();
    }

    /// Initialize the IDT with raw handlers and correct stacks.
    pub fn initIdt() linksection(kernel.info.init_code) void {
        log.debug("mapping idt entries to raw handlers", .{});
        for (raw_handlers, 0..) |raw_handler, i| {
            idt.handlers[i].init(
                x86_64.Gdt.kernel_code_selector,
                .interrupt,
                raw_handler,
            );
        }

        setFixedHandlers();

        setVectorStack(.double_fault, .double_fault);
        setVectorStack(.non_maskable_interrupt, .non_maskable_interrupt);
    }

    fn setFixedHandlers() linksection(kernel.info.init_code) void {
        handlers[@intFromEnum(IdtVector.divide)] = fixed_handlers.divideErrorException;
        handlers[@intFromEnum(IdtVector.debug)] = fixed_handlers.debugException;
        handlers[@intFromEnum(IdtVector.non_maskable_interrupt)] = fixed_handlers.nonMaskableInterrupt;
        handlers[@intFromEnum(IdtVector.breakpoint)] = fixed_handlers.breakpointException;
        handlers[@intFromEnum(IdtVector.overflow)] = fixed_handlers.overflowException;
        handlers[@intFromEnum(IdtVector.bound_range)] = fixed_handlers.boundRangeExceededException;
        handlers[@intFromEnum(IdtVector.invalid_opcode)] = fixed_handlers.invalidOpcodeException;
        handlers[@intFromEnum(IdtVector.device_not_available)] = fixed_handlers.deviceNotAvailableException;
        handlers[@intFromEnum(IdtVector.double_fault)] = fixed_handlers.doubleFaultException;
        handlers[@intFromEnum(IdtVector.invalid_tss)] = fixed_handlers.invalidTSSException;
        handlers[@intFromEnum(IdtVector.segment_not_present)] = fixed_handlers.segmentNotPresentException;
        handlers[@intFromEnum(IdtVector.stack_fault)] = fixed_handlers.stackFaultException;
        handlers[@intFromEnum(IdtVector.general_protection)] = fixed_handlers.generalProtectionException;
        handlers[@intFromEnum(IdtVector.page_fault)] = fixed_handlers.pageFaultException;
        handlers[@intFromEnum(IdtVector.x87_floating_point)] = fixed_handlers.x87FPUFloatingPointException;
        handlers[@intFromEnum(IdtVector.alignment_check)] = fixed_handlers.alignmentCheckException;
        handlers[@intFromEnum(IdtVector.machine_check)] = fixed_handlers.machineCheckException;
        handlers[@intFromEnum(IdtVector.simd_floating_point)] = fixed_handlers.simdFloatingPointException;
        handlers[@intFromEnum(IdtVector.virtualization)] = fixed_handlers.virtualizationException;
        handlers[@intFromEnum(IdtVector.control_protection)] = fixed_handlers.controlProtectionException;
        handlers[@intFromEnum(IdtVector.hypervisor_injection)] = fixed_handlers.hypervisorInjectionException;
        handlers[@intFromEnum(IdtVector.vmm_communication)] = fixed_handlers.vmmCommunicationException;
        handlers[@intFromEnum(IdtVector.security)] = fixed_handlers.securityException;

        handlers[@intFromEnum(IdtVector.scheduler)] = fixed_handlers.scheduler;
    }
};
