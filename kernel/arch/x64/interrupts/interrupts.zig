// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub fn allocateInterrupt(
    context: *kernel.Context,
    interrupt_handler: arch.interrupts.Interrupt.Handler,
    arg1: ?*anyopaque,
    arg2: ?*anyopaque,
) arch.interrupts.Interrupt.AllocateError!Interrupt {
    const allocation = globals.interrupt_arena.allocate(context, 1, .instant_fit) catch {
        return error.InterruptAllocationFailed;
    };

    const interrupt_number: u8 = @intCast(allocation.base);

    globals.handlers[interrupt_number] = .{
        .interrupt_handler = interrupt_handler,
        .arg1 = arg1,
        .arg2 = arg2,
    };

    return @enumFromInt(interrupt_number);
}

pub fn deallocateInterrupt(interrupt: Interrupt, context: *kernel.Context) void {
    const interrupt_number = @intFromEnum(interrupt);

    globals.handlers[interrupt_number] = .{
        .interrupt_handler = interrupt_handlers.unhandledInterrupt,
    };

    globals.interrupt_arena.deallocate(context, .{
        .base = interrupt_number,
        .len = 1,
    });
}

pub fn routeInterrupt(interrupt: Interrupt, external_interrupt: u32) arch.interrupts.Interrupt.RouteError!void {
    try x64.ioapic.routeInterrupt(@intCast(external_interrupt), interrupt);
}

export fn interruptDispatch(interrupt_frame: *InterruptFrame) callconv(.c) void {
    const context, const restorer = kernel.Context.onInterruptEntry();
    defer restorer.exit(context);
    globals.handlers[interrupt_frame.vector_number.full].call(context, interrupt_frame);
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

    /// Checks if the given interrupt vector pushes an error code.
    pub fn hasErrorCode(vector: Interrupt) bool {
        return switch (@intFromEnum(vector)) {
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

    /// Checks if the given interrupt vector is an exception.
    pub fn isException(vector: Interrupt) bool {
        if (@intFromEnum(vector) <= @intFromEnum(Interrupt._reserved8)) {
            return vector != Interrupt.non_maskable_interrupt;
        }
        return false;
    }
};

pub const InterruptFrame = extern struct {
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
        selector: x64.Gdt.Selector,
    },
    rflags: x64.registers.RFlags,
    rsp: u64,
    ss: extern union {
        full: u64,
        selector: x64.Gdt.Selector,
    },

    /// Returns the environment that the interrupt was triggered from.
    pub fn environment(
        interrupt_frame: *const InterruptFrame,
        context: *kernel.Context,
    ) kernel.Environment {
        return switch (interrupt_frame.cs.selector) {
            .kernel_code => return .kernel,
            .user_code => return .{ .user = context.task().environment.user },
            else => unreachable,
        };
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
    interrupt_handler: arch.interrupts.Interrupt.Handler,
    arg1: ?*anyopaque = null,
    arg2: ?*anyopaque = null,

    inline fn call(handler: *const Handler, context: *kernel.Context, interrupt_frame: *InterruptFrame) void {
        handler.interrupt_handler(
            context,
            .{ .arch_specific = interrupt_frame },
            handler.arg1,
            handler.arg2,
        );
    }
};

const Idt = @import("Idt.zig");

const globals = struct {
    var idt: Idt = .{};
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
        for (raw_interrupt_handlers, 0..) |raw_handler, i| {
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
    pub fn initializeInterruptRouting(context: *kernel.Context) void {
        globals.interrupt_arena.init(
            context,
            .{
                .name = kernel.mem.resource_arena.Name.fromSlice("interrupts") catch unreachable,
                .quantum = 1,
            },
        ) catch |err| {
            std.debug.panic("failed to initialize interrupt arena: {t}", .{err});
        };

        globals.interrupt_arena.addSpan(
            context,
            Interrupt.first_available_interrupt,
            Interrupt.last_available_interrupt - Interrupt.first_available_interrupt,
        ) catch |err| {
            std.debug.panic("failed to add interrupt span: {t}", .{err});
        };
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

    const raw_interrupt_handlers: [Idt.number_of_handlers](*const fn () callconv(.naked) void) = blk: {
        @setEvalBranchQuota(Idt.number_of_handlers * 210);

        var raw_interrupt_handlers_temp: [Idt.number_of_handlers](*const fn () callconv(.naked) void) = undefined;

        for (0..Idt.number_of_handlers) |interrupt_number| {
            const name = std.fmt.comptimePrint(
                "_interrupt_handler_{d}",
                .{interrupt_number},
            );

            raw_interrupt_handlers_temp[interrupt_number] = @extern(*const fn () callconv(.naked) void, .{
                .name = name,
            });
        }

        break :blk raw_interrupt_handlers_temp;
    };
};

const arch = @import("arch");
const kernel = @import("kernel");
const x64 = @import("../x64.zig");

const core = @import("core");
const interrupt_handlers = @import("handlers.zig");
const std = @import("std");
