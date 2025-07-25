// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub const disableInterruptsAndHalt = lib_x64.instructions.disableInterruptsAndHalt;
pub const disableInterrupts = lib_x64.instructions.disableInterrupts;
pub const enableInterrupts = lib_x64.instructions.enableInterrupts;
pub const areEnabled = lib_x64.instructions.interruptsEnabled;
pub const eoi = x64.apic.eoi;
pub const sendPanicIPI = x64.apic.sendPanicIPI;
pub const sendFlushIPI = x64.apic.sendFlushIPI;

pub fn allocateInterrupt(
    current_task: *kernel.Task,
    interrupt_handler: InterruptHandler,
    context1: ?*anyopaque,
    context2: ?*anyopaque,
) !Interrupt {
    const allocation = try globals.interrupt_arena.allocate(current_task, 1, .instant_fit);

    const interrupt_number: u8 = @intCast(allocation.base);

    globals.handlers[interrupt_number] = .{
        .interrupt_handler = interrupt_handler,
        .context1 = context1,
        .context2 = context2,
    };

    return @enumFromInt(interrupt_number);
}

pub fn deallocateInterrupt(current_task: *kernel.Task, interrupt: Interrupt) void {
    const interrupt_number = @intFromEnum(interrupt);

    globals.handlers[interrupt_number] = .{
        .interrupt_handler = interrupt_handlers.unhandledInterrupt,
    };

    globals.interrupt_arena.deallocate(current_task, .{
        .base = interrupt_number,
        .len = 1,
    });
}

pub fn routeInterrupt(external_interrupt: u32, interrupt: Interrupt) !void {
    try x64.ioapic.routeInterrupt(@intCast(external_interrupt), interrupt);
}

export fn interruptDispatch(interrupt_frame: *InterruptFrame) void {
    const current_task, const restorer = kernel.Task.onInterruptEntry();
    defer restorer.exit(current_task);
    globals.handlers[interrupt_frame.vector_number.full].call(current_task, interrupt_frame);
}

pub const Interrupt = enum(u8) {
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

    per_executor_periodic = 48,

    flush_request = 254,
    spurious_interrupt = 255,

    _,

    const first_available_interrupt = @intFromEnum(Interrupt.per_executor_periodic) + 1;
    const last_available_interrupt = @intFromEnum(Interrupt.spurious_interrupt) - 1;

    pub inline fn toInterruptVector(interrupt: Interrupt) lib_x64.InterruptVector {
        return @enumFromInt(@intFromEnum(interrupt));
    }

    pub inline fn hasErrorCode(interrupt: Interrupt) bool {
        return interrupt.toInterruptVector().hasErrorCode();
    }

    pub inline fn isException(interrupt: Interrupt) bool {
        return interrupt.toInterruptVector().isException();
    }
};

pub const ArchInterruptFrame = InterruptFrame;
pub const InterruptFrame = extern struct {
    es: extern union {
        full: u64,
        selector: Gdt.Selector,
    },
    ds: extern union {
        full: u64,
        selector: Gdt.Selector,
    },
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
    vector_number: extern union {
        full: u64,
        interrupt: Interrupt,
    },
    error_code: u64,
    rip: u64,
    cs: extern union {
        full: u64,
        selector: Gdt.Selector,
    },
    rflags: lib_x64.registers.RFlags,
    rsp: u64,
    ss: extern union {
        full: u64,
        selector: Gdt.Selector,
    },

    pub inline fn instructionPointer(interrupt_frame: *const InterruptFrame) usize {
        return interrupt_frame.rip;
    }

    pub inline fn context(interrupt_frame: *const InterruptFrame) kernel.Context.Type {
        return switch (interrupt_frame.cs.selector) {
            .kernel_code => return .kernel,
            .user_code => return .user,
            else => unreachable,
        };
    }

    pub inline fn createStackIterator(interrupt_frame: *const InterruptFrame) std.debug.StackIterator {
        return .init(null, interrupt_frame.rbp);
    }

    pub fn print(
        value: *const InterruptFrame,
        writer: *std.Io.Writer,
        indent: usize,
    ) !void {
        const new_indent = indent + 2;

        try writer.writeAll("InterruptFrame{\n");

        try writer.splatByteAll(' ', new_indent);
        try writer.print("interrupt: {t},\n", .{value.vector_number.interrupt});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("error code: {},\n", .{value.error_code});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("cs: {t}, ss: {t},\n", .{ value.cs.selector, value.ss.selector });

        try writer.splatByteAll(' ', new_indent);
        try writer.print("ds: {t}, es: {t},\n", .{ value.ds.selector, value.es.selector });

        try writer.splatByteAll(' ', new_indent);
        try writer.print("rsp: 0x{x:0>16}, rip: 0x{x:0>16},\n", .{ value.rsp, value.rip });

        try writer.splatByteAll(' ', new_indent);
        try writer.print("rax: 0x{x:0>16}, rbx: 0x{x:0>16},\n", .{ value.rax, value.rbx });

        try writer.splatByteAll(' ', new_indent);
        try writer.print("rcx: 0x{x:0>16}, rdx: 0x{x:0>16},\n", .{ value.rcx, value.rdx });

        try writer.splatByteAll(' ', new_indent);
        try writer.print("rbp: 0x{x:0>16}, rsi: 0x{x:0>16},\n", .{ value.rbp, value.rsi });

        try writer.splatByteAll(' ', new_indent);
        try writer.print("rdi: 0x{x:0>16}, r8:  0x{x:0>16},\n", .{ value.rdi, value.r8 });

        try writer.splatByteAll(' ', new_indent);
        try writer.print("r9:  0x{x:0>16}, r10: 0x{x:0>16},\n", .{ value.r9, value.r10 });

        try writer.splatByteAll(' ', new_indent);
        try writer.print("r11: 0x{x:0>16}, r12: 0x{x:0>16},\n", .{ value.r11, value.r12 });

        try writer.splatByteAll(' ', new_indent);
        try writer.print("r13: 0x{x:0>16}, r14: 0x{x:0>16},\n", .{ value.r13, value.r14 });

        try writer.splatByteAll(' ', new_indent);
        try writer.print("r15: 0x{x:0>16},\n", .{value.r15});

        try writer.splatByteAll(' ', new_indent);
        try writer.writeAll("rflags: ");
        try value.rflags.print(writer, new_indent);
        try writer.writeAll(",\n");

        try writer.splatByteAll(' ', indent);
        try writer.writeByte('}');
    }

    pub inline fn format(
        value: *const InterruptFrame,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        return print(value, writer, 0);
    }
};

pub const InterruptStackSelector = enum(u3) {
    double_fault,
    non_maskable_interrupt,
};

const Handler = struct {
    interrupt_handler: InterruptHandler,
    context1: ?*anyopaque = null,
    context2: ?*anyopaque = null,

    inline fn call(handler: *const Handler, current_task: *kernel.Task, interrupt_frame: *InterruptFrame) void {
        handler.interrupt_handler(
            current_task,
            .{ .arch = interrupt_frame },
            handler.context1,
            handler.context2,
        );
    }
};

const globals = struct {
    var idt: Idt = .{};
    const raw_interrupt_handlers = init.makeRawHandlers();
    var handlers: [Idt.number_of_handlers]Handler = handlers: {
        @setEvalBranchQuota(4 * Idt.number_of_handlers);

        var temp_handlers: [Idt.number_of_handlers]Handler = undefined;

        for (0..Idt.number_of_handlers) |i| {
            const interrupt: Interrupt = @enumFromInt(i);

            temp_handlers[i] = if (interrupt.isException()) .{
                .interrupt_handler = interrupt_handlers.unhandledException,
            } else .{
                .interrupt_handler = interrupt_handlers.unhandledInterrupt,
            };
        }

        break :handlers temp_handlers;
    };
    var interrupt_arena: kernel.mem.resource_arena.Arena(.none) = undefined; // initialized by `init.initializeInterrupts`
};

pub const init = struct {
    /// Ensure that any exceptions/faults that occur during early initialization are handled.
    ///
    /// The handler is not expected to do anything other than panic.
    pub fn initializeEarlyInterrupts() void {
        for (globals.raw_interrupt_handlers, 0..) |raw_handler, i| {
            globals.idt.handlers[i].init(
                .kernel_code,
                .interrupt,
                raw_handler,
            );
        }

        globals.idt.handlers[@intFromEnum(Interrupt.double_fault)]
            .setStack(@intFromEnum(InterruptStackSelector.double_fault));

        globals.idt.handlers[@intFromEnum(Interrupt.non_maskable_interrupt)]
            .setStack(@intFromEnum(InterruptStackSelector.non_maskable_interrupt));
    }

    /// Prepare interrupt allocation and routing.
    pub fn initializeInterruptRouting(current_task: *kernel.Task) !void {
        try globals.interrupt_arena.init(
            .{
                .name = try .fromSlice("interrupts"),
                .quantum = 1,
            },
        );

        try globals.interrupt_arena.addSpan(
            current_task,
            Interrupt.first_available_interrupt,
            Interrupt.last_available_interrupt - Interrupt.first_available_interrupt,
        );
    }

    /// Switch away from the initial interrupt handlers installed by `initInterrupts` to the standard
    /// system interrupt handlers.
    pub fn loadStandardInterruptHandlers() void {
        globals.handlers[@intFromEnum(Interrupt.non_maskable_interrupt)] = .{
            .interrupt_handler = interrupt_handlers.nonMaskableInterruptHandler,
        };
        globals.handlers[@intFromEnum(Interrupt.page_fault)] = .{
            .interrupt_handler = interrupt_handlers.pageFaultHandler,
        };
        globals.handlers[@intFromEnum(Interrupt.flush_request)] = .{
            .interrupt_handler = interrupt_handlers.flushRequestHandler,
        };
        globals.handlers[@intFromEnum(Interrupt.per_executor_periodic)] = .{
            .interrupt_handler = interrupt_handlers.perExecutorPeriodicHandler,
        };
    }

    pub fn loadIdt() void {
        globals.idt.load();
    }

    /// Creates an array of raw interrupt handlers, one for each vector.
    fn makeRawHandlers() [Idt.number_of_handlers](*const fn () callconv(.naked) void) {
        comptime {
            @setEvalBranchQuota(Idt.number_of_handlers * 520);

            var raw_handlers_temp: [Idt.number_of_handlers](*const fn () callconv(.naked) void) = undefined;

            var i = 0;
            while (i < Idt.number_of_handlers) : (i += 1) {
                const vector_number: u8 = @intCast(i);
                const interrupt: Interrupt = @enumFromInt(vector_number);

                // if the cpu does not push an error code, we push a dummy error code to ensure the stack
                // is always aligned in the same way for every vector
                const error_code_asm = if (!interrupt.hasErrorCode())
                    "push $0\n"
                else
                    "";
                const vector_number_asm = std.fmt.comptimePrint(
                    "push ${d}\n",
                    .{vector_number},
                );
                const data_selector_asm = std.fmt.comptimePrint(
                    "\nmov ${d}, %%ax\n",
                    .{@intFromEnum(Gdt.Selector.kernel_data)},
                );

                const rawInterruptHandler = struct {
                    fn rawInterruptHandler() callconv(.naked) void {
                        // zig fmt: off
                        asm volatile (error_code_asm ++ vector_number_asm ++
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
                            ++ data_selector_asm ++
                            \\mov %%ax, %%es
                            \\mov %%ax, %%ds
                            \\call interruptDispatch
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
                        // zig fmt: on
                    }
                }.rawInterruptHandler;

                raw_handlers_temp[vector_number] = rawInterruptHandler;
            }

            return raw_handlers_temp;
        }
    }
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const x64 = @import("../x64.zig");
const lib_x64 = @import("x64");
const Idt = lib_x64.Idt;
const Gdt = lib_x64.Gdt;
const InterruptHandler = kernel.arch.interrupts.InterruptHandler;
const interrupt_handlers = @import("handlers.zig");
