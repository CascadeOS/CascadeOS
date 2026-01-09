// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const Handler = arch.interrupts.Interrupt.Handler;
const kernel = @import("kernel");
const Task = kernel.Task;
const Thread = kernel.user.Thread;
const core = @import("core");

const x64 = @import("../x64.zig");
const Idt = @import("Idt.zig");
const interrupt_handlers = @import("handlers.zig");

const log = kernel.debug.log.scoped(.interrupt);

export fn interruptDispatch(interrupt_frame: *InterruptFrame) callconv(.c) void {
    switch (interrupt_frame.cs.selector) {
        .kernel_code => {},
        .user_code, .user_code_32bit => x64.instructions.disableSSEUsage(),
        else => unreachable,
    }
    defer {
        switch (interrupt_frame.cs.selector) {
            .user_code, .user_code_32bit => {
                const per_thread: *x64.user.PerThread = .from(.from(Task.Current.get().task));
                x64.instructions.enableSSEUsage();
                per_thread.extended_state.load();
            },
            .kernel_code => {},
            else => unreachable,
        }
    }

    const state_before_interrupt = Task.Current.onInterruptEntry();
    defer state_before_interrupt.onInterruptExit();

    var handler = globals.handlers[interrupt_frame.vector_number.full];
    handler.setTemplatedArgs(.{ .{ .arch_specific = interrupt_frame }, state_before_interrupt });
    handler.call();

    x64.instructions.disableInterrupts();
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

    pub fn allocate(
        interrupt_handler: Handler,
    ) arch.interrupts.Interrupt.AllocateError!Interrupt {
        const allocation = globals.interrupt_arena.allocate(1, .instant_fit) catch {
            return error.InterruptAllocationFailed;
        };

        const interrupt_number: u8 = @intCast(allocation.base);

        globals.handlers[interrupt_number] = interrupt_handler;

        // TODO: maybe we should use `mfence` instead of this junk that probably doesn't work
        const byte_slice: []u8 = std.mem.asBytes(&globals.handlers[interrupt_number]);
        _ = @atomicStore(u8, &byte_slice.ptr[0], byte_slice.ptr[0], .release);

        const interrupt: Interrupt = @enumFromInt(interrupt_number);
        log.debug("allocated interrupt {}", .{interrupt});

        return interrupt;
    }

    pub fn deallocate(interrupt: Interrupt) void {
        log.debug("deallocating interrupt {}", .{interrupt});

        const interrupt_number = @intFromEnum(interrupt);

        globals.handlers[interrupt_number] = .prepare(interrupt_handlers.unhandledInterrupt, .{});

        // TODO: maybe we should use `mfence` instead of this junk that probably doesn't work
        const byte_slice: []u8 = std.mem.asBytes(&globals.handlers[interrupt_number]);
        _ = @atomicStore(u8, &byte_slice.ptr[0], byte_slice.ptr[0], .release);

        globals.interrupt_arena.deallocate(.{ .base = interrupt_number, .len = 1 });
    }

    pub fn route(interrupt: Interrupt, external_interrupt: u32) arch.interrupts.Interrupt.RouteError!void {
        log.debug("routing interrupt {} to {}", .{ interrupt, external_interrupt });

        try x64.ioapic.routeInterrupt(@intCast(external_interrupt), interrupt);
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

    pub inline fn from(interrupt_frame: arch.interrupts.InterruptFrame) *InterruptFrame {
        return interrupt_frame.arch_specific;
    }

    /// Returns the context that the interrupt was triggered from.
    pub fn contextSS(interrupt_frame: *const InterruptFrame) kernel.Context.Type {
        return switch (interrupt_frame.cs.selector) {
            .kernel_code => return .kernel,
            .user_code, .user_code_32bit => .user,
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

const globals = struct {
    var idt: Idt = .{};
    var handlers: [Idt.number_of_handlers]Handler = handlers: {
        @setEvalBranchQuota(4 * Idt.number_of_handlers);

        var temp_handlers: [Idt.number_of_handlers]Handler = undefined;

        for (0..Idt.number_of_handlers) |i| {
            const interrupt: Interrupt = @enumFromInt(i);

            temp_handlers[i] = if (interrupt.isException())
                .prepare(interrupt_handlers.unhandledException, .{})
            else
                .prepare(interrupt_handlers.unhandledInterrupt, .{});
        }

        break :handlers temp_handlers;
    };
    var interrupt_arena: kernel.mem.resource_arena.Arena(.none) = undefined; // initialized by `init.initializeInterrupts`
};

pub const init = struct {
    const init_log = kernel.debug.log.scoped(.interrupt_init);

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
    pub fn initializeInterruptRouting() void {
        globals.interrupt_arena.init(
            .{
                .name = kernel.mem.resource_arena.Name.fromSlice("interrupts") catch unreachable,
                .quantum = 1,
            },
        ) catch |err| {
            std.debug.panic("failed to initialize interrupt arena: {t}", .{err});
        };

        globals.interrupt_arena.addSpan(
            Interrupt.first_available_interrupt,
            Interrupt.last_available_interrupt - Interrupt.first_available_interrupt,
        ) catch |err| {
            std.debug.panic("failed to add interrupt span: {t}", .{err});
        };
    }

    /// Switch away from the initial interrupt handlers installed by `initInterrupts` to the standard
    /// system interrupt handlers.
    pub fn loadStandardInterruptHandlers() void {
        globals.handlers[@intFromEnum(Interrupt.non_maskable_interrupt)] = .prepare(interrupt_handlers.nonMaskableInterruptHandler, .{});
        globals.handlers[@intFromEnum(Interrupt.page_fault)] = .prepare(interrupt_handlers.pageFaultHandler, .{});
        globals.handlers[@intFromEnum(Interrupt.flush_request)] = .prepare(interrupt_handlers.flushRequestHandler, .{});
        globals.handlers[@intFromEnum(Interrupt.per_executor_periodic)] = .prepare(interrupt_handlers.perExecutorPeriodicHandler, .{});
    }

    pub fn loadIdt() void {
        globals.idt.load();
    }

    const RawInterruptHandler = *const fn () callconv(.naked) void;

    const raw_interrupt_handlers: [Idt.number_of_handlers]RawInterruptHandler = .{
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_0" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_1" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_2" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_3" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_4" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_5" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_6" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_7" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_8" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_9" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_10" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_11" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_12" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_13" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_14" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_15" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_16" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_17" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_18" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_19" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_20" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_21" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_22" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_23" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_24" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_25" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_26" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_27" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_28" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_29" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_30" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_31" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_32" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_33" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_34" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_35" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_36" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_37" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_38" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_39" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_40" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_41" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_42" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_43" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_44" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_45" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_46" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_47" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_48" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_49" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_50" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_51" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_52" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_53" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_54" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_55" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_56" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_57" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_58" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_59" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_60" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_61" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_62" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_63" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_64" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_65" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_66" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_67" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_68" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_69" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_70" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_71" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_72" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_73" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_74" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_75" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_76" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_77" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_78" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_79" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_80" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_81" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_82" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_83" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_84" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_85" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_86" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_87" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_88" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_89" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_90" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_91" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_92" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_93" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_94" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_95" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_96" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_97" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_98" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_99" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_100" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_101" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_102" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_103" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_104" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_105" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_106" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_107" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_108" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_109" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_110" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_111" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_112" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_113" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_114" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_115" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_116" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_117" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_118" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_119" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_120" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_121" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_122" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_123" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_124" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_125" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_126" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_127" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_128" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_129" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_130" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_131" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_132" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_133" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_134" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_135" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_136" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_137" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_138" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_139" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_140" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_141" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_142" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_143" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_144" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_145" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_146" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_147" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_148" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_149" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_150" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_151" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_152" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_153" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_154" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_155" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_156" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_157" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_158" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_159" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_160" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_161" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_162" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_163" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_164" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_165" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_166" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_167" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_168" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_169" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_170" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_171" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_172" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_173" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_174" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_175" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_176" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_177" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_178" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_179" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_180" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_181" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_182" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_183" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_184" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_185" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_186" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_187" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_188" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_189" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_190" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_191" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_192" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_193" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_194" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_195" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_196" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_197" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_198" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_199" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_200" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_201" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_202" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_203" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_204" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_205" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_206" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_207" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_208" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_209" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_210" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_211" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_212" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_213" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_214" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_215" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_216" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_217" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_218" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_219" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_220" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_221" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_222" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_223" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_224" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_225" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_226" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_227" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_228" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_229" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_230" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_231" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_232" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_233" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_234" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_235" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_236" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_237" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_238" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_239" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_240" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_241" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_242" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_243" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_244" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_245" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_246" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_247" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_248" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_249" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_250" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_251" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_252" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_253" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_254" }),
        @extern(RawInterruptHandler, .{ .name = "_interrupt_handler_255" }),
    };
};
