// SPDX-License-Identifier: BSD-3-Clause
// SPDX-FileCopyrightText: CascadeOS Contributors

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const core = @import("core");

const interrupt_handlers = @import("interrupt_handlers.zig");
const x64 = @import("x64.zig");

const log = cascade.debug.log.scoped(.interrupt);

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

    pub fn from(value: usize) arch.Interrupt.FromError!Interrupt {
        return @enumFromInt(std.math.cast(u8, value) orelse return error.InvalidInterrupt);
    }

    pub fn to(interrupt: Interrupt) usize {
        return @intFromEnum(interrupt);
    }

    const first_available_interrupt = @intFromEnum(Interrupt.per_executor_periodic) + 1;
    const last_available_interrupt = @intFromEnum(Interrupt.flush_request) - 1;

    pub fn allocate(handler: arch.Interrupt.Handler) arch.Interrupt.AllocateError!Interrupt {
        const allocation = globals.interrupt_arena.allocate(1, .instant_fit) catch {
            return error.InterruptAllocationFailed;
        };

        const interrupt_number: u8 = @intCast(allocation.base);

        globals.handlers[interrupt_number] = handler;
        x64.mfence();

        const interrupt: Interrupt = @enumFromInt(interrupt_number);
        log.debug("allocated interrupt {}", .{interrupt});

        return interrupt;
    }

    pub fn deallocate(interrupt: Interrupt) void {
        log.debug("deallocating interrupt {}", .{interrupt});

        const interrupt_number = @intFromEnum(interrupt);

        globals.handlers[interrupt_number] = .{
            .eoi = .after,
            .call = .prepare(interrupt_handlers.unhandledInterrupt, .{}),
        };
        x64.mfence();

        globals.interrupt_arena.deallocate(.{ .base = interrupt_number, .len = 1 });
    }

    /// Checks if the given interrupt vector is an exception.
    fn isException(interrupt: Interrupt) bool {
        if (@intFromEnum(interrupt) <= @intFromEnum(Interrupt._reserved8)) {
            return interrupt != Interrupt.non_maskable_interrupt;
        }
        return false;
    }

    pub const StackSelector = enum(u3) {
        double_fault,
        non_maskable_interrupt,
    };

    pub const Frame = extern struct {
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
        rip: cascade.VirtualAddress,
        cs: extern union {
            full: u64,
            selector: x64.Gdt.Selector,
        },
        rflags: x64.registers.RFlags,
        rsp: cascade.VirtualAddress,
        ss: extern union {
            full: u64,
            selector: x64.Gdt.Selector,
        },

        pub inline fn from(interrupt_frame: arch.Interrupt.Frame) *Frame {
            return interrupt_frame.arch_specific;
        }

        /// Provides the context this interrupt was triggered from.
        pub fn fillContext(interrupt_frame: *const Frame, cpu_context: *std.debug.cpu_context.Native) void {
            cpu_context.gprs.set(.rax, interrupt_frame.rax);
            cpu_context.gprs.set(.rdx, interrupt_frame.rdx);
            cpu_context.gprs.set(.rcx, interrupt_frame.rcx);
            cpu_context.gprs.set(.rbx, interrupt_frame.rbx);
            cpu_context.gprs.set(.rsi, interrupt_frame.rsi);
            cpu_context.gprs.set(.rdi, interrupt_frame.rdi);
            cpu_context.gprs.set(.rbp, interrupt_frame.rbp);
            cpu_context.gprs.set(.rsp, interrupt_frame.rsp.value);
            cpu_context.gprs.set(.r8, interrupt_frame.r8);
            cpu_context.gprs.set(.r9, interrupt_frame.r9);
            cpu_context.gprs.set(.r10, interrupt_frame.r10);
            cpu_context.gprs.set(.r11, interrupt_frame.r11);
            cpu_context.gprs.set(.r12, interrupt_frame.r12);
            cpu_context.gprs.set(.r13, interrupt_frame.r13);
            cpu_context.gprs.set(.r14, interrupt_frame.r14);
            cpu_context.gprs.set(.r15, interrupt_frame.r15);
            cpu_context.gprs.set(.rip, interrupt_frame.rip.value);
        }

        /// Returns the instruction pointer of the context this interrupt was triggered from.
        pub fn getInstructionPointer(interrupt_frame: *const Frame) cascade.VirtualAddress {
            return interrupt_frame.rip;
        }

        /// Sets the instruction pointer that should be used when returning from the interrupt.
        pub fn setInstructionPointer(interrupt_frame: *Frame, instruction_pointer: cascade.VirtualAddress) void {
            interrupt_frame.rip = instruction_pointer;
        }

        /// Returns the context that the interrupt was triggered from.
        pub fn context(interrupt_frame: *const Frame) cascade.Context.Type {
            return switch (interrupt_frame.cs.selector) {
                .kernel_code => return .kernel,
                .user_code, .user_code_32bit => .user,
                else => unreachable,
            };
        }

        pub fn print(interrupt_frame: *const Frame, writer: *std.Io.Writer, indent: usize) !void {
            const new_indent = indent + 2;

            try writer.writeAll("InterruptFrame{\n");

            try writer.splatByteAll(' ', new_indent);
            try writer.print("interrupt: {t},\n", .{interrupt_frame.vector_number.interrupt});

            try writer.splatByteAll(' ', new_indent);
            try writer.print("error code: {},\n", .{interrupt_frame.error_code});

            try writer.splatByteAll(' ', new_indent);
            try writer.print("cs: {t}, ss: {t},\n", .{ interrupt_frame.cs.selector, interrupt_frame.ss.selector });

            try writer.splatByteAll(' ', new_indent);
            try writer.print("rsp: 0x{x:0>16}, rip: 0x{x:0>16},\n", .{ interrupt_frame.rsp.value, interrupt_frame.rip.value });

            try writer.splatByteAll(' ', new_indent);
            try writer.print("rax: 0x{x:0>16}, rbx: 0x{x:0>16},\n", .{ interrupt_frame.rax, interrupt_frame.rbx });

            try writer.splatByteAll(' ', new_indent);
            try writer.print("rcx: 0x{x:0>16}, rdx: 0x{x:0>16},\n", .{ interrupt_frame.rcx, interrupt_frame.rdx });

            try writer.splatByteAll(' ', new_indent);
            try writer.print("rbp: 0x{x:0>16}, rsi: 0x{x:0>16},\n", .{ interrupt_frame.rbp, interrupt_frame.rsi });

            try writer.splatByteAll(' ', new_indent);
            try writer.print("rdi: 0x{x:0>16}, r8:  0x{x:0>16},\n", .{ interrupt_frame.rdi, interrupt_frame.r8 });

            try writer.splatByteAll(' ', new_indent);
            try writer.print("r9:  0x{x:0>16}, r10: 0x{x:0>16},\n", .{ interrupt_frame.r9, interrupt_frame.r10 });

            try writer.splatByteAll(' ', new_indent);
            try writer.print("r11: 0x{x:0>16}, r12: 0x{x:0>16},\n", .{ interrupt_frame.r11, interrupt_frame.r12 });

            try writer.splatByteAll(' ', new_indent);
            try writer.print("r13: 0x{x:0>16}, r14: 0x{x:0>16},\n", .{ interrupt_frame.r13, interrupt_frame.r14 });

            try writer.splatByteAll(' ', new_indent);
            try writer.print("r15: 0x{x:0>16},\n", .{interrupt_frame.r15});

            try writer.splatByteAll(' ', new_indent);
            try writer.writeAll("rflags: ");
            try interrupt_frame.rflags.print(writer, new_indent);
            try writer.writeAll(",\n");

            try writer.splatByteAll(' ', indent);
            try writer.writeByte('}');
        }

        pub inline fn format(interrupt_frame: *const Frame, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            return print(interrupt_frame, writer, 0);
        }
    };

    pub const External = enum(u32) {
        _,

        pub fn from(value: usize) arch.Interrupt.External.ExternalFromError!External {
            return @enumFromInt(std.math.cast(u32, value) orelse return error.InvalidExternalInterrupt);
        }

        /// Get the EOI type for the given external interrupt if known.
        pub fn eoiType(external_interrupt: External) ?arch.Interrupt.Handler.EOI {
            return x64.ioapic.eoiType(external_interrupt);
        }

        /// Route this external interrupt to the given interrupt.
        ///
        /// Routing the same external interrupt multiple times is undefined behavior.
        pub fn route(external_interrupt: External, interrupt: Interrupt) arch.Interrupt.External.RouteError!void {
            log.debug("routing interrupt {} to {}", .{ external_interrupt, interrupt });
            try x64.ioapic.route(external_interrupt, interrupt);
        }
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
                .setStack(@intFromEnum(StackSelector.double_fault));

            globals.idt.handlers[@intFromEnum(Interrupt.non_maskable_interrupt)]
                .setStack(@intFromEnum(StackSelector.non_maskable_interrupt));
        }

        /// Prepare interrupt allocation and routing.
        pub fn initializeInterruptRouting() void {
            globals.interrupt_arena.init(
                .{
                    .name = cascade.mem.resource_arena.Name.fromSlice("interrupts") catch unreachable,
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

        /// Switch away from the initial interrupt handlers installed by `initializeEarlyInterrupts` to the standard
        /// system interrupt handlers.
        pub fn loadStandardInterruptHandlers() void {
            globals.handlers[@intFromEnum(Interrupt.non_maskable_interrupt)] = .{
                .eoi = .none,
                .call = .prepare(interrupt_handlers.nonMaskableInterruptHandler, .{}),
            };
            globals.handlers[@intFromEnum(Interrupt.page_fault)] = .{
                .eoi = .none,
                .call = .prepare(interrupt_handlers.pageFaultHandler, .{}),
            };
            globals.handlers[@intFromEnum(Interrupt.flush_request)] = .{
                .eoi = .after,
                .call = .prepare(interrupt_handlers.flushRequestHandler, .{}),
            };
            globals.handlers[@intFromEnum(Interrupt.per_executor_periodic)] = .{
                .eoi = .before,
                .call = .prepare(interrupt_handlers.perExecutorPeriodicHandler, .{}),
            };
            globals.handlers[@intFromEnum(Interrupt.spurious_interrupt)] = .{
                .eoi = .none,
                .call = .prepare(interrupt_handlers.spuriousInterruptHandler, .{}),
            };
        }

        pub fn loadIdt() void {
            globals.idt.load();
        }

        const RawInterruptHandler = *const fn () callconv(.naked) void;

        const raw_interrupt_handlers: [Idt.number_of_handlers]RawInterruptHandler = .{
            @extern(RawInterruptHandler, .{ .name = "interruptHandler0" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler1" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler2" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler3" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler4" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler5" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler6" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler7" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler8" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler9" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler10" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler11" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler12" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler13" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler14" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler15" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler16" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler17" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler18" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler19" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler20" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler21" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler22" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler23" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler24" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler25" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler26" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler27" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler28" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler29" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler30" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler31" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler32" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler33" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler34" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler35" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler36" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler37" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler38" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler39" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler40" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler41" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler42" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler43" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler44" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler45" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler46" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler47" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler48" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler49" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler50" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler51" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler52" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler53" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler54" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler55" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler56" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler57" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler58" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler59" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler60" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler61" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler62" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler63" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler64" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler65" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler66" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler67" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler68" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler69" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler70" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler71" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler72" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler73" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler74" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler75" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler76" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler77" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler78" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler79" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler80" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler81" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler82" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler83" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler84" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler85" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler86" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler87" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler88" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler89" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler90" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler91" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler92" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler93" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler94" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler95" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler96" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler97" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler98" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler99" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler100" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler101" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler102" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler103" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler104" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler105" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler106" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler107" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler108" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler109" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler110" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler111" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler112" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler113" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler114" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler115" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler116" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler117" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler118" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler119" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler120" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler121" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler122" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler123" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler124" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler125" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler126" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler127" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler128" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler129" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler130" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler131" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler132" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler133" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler134" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler135" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler136" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler137" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler138" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler139" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler140" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler141" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler142" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler143" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler144" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler145" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler146" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler147" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler148" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler149" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler150" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler151" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler152" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler153" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler154" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler155" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler156" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler157" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler158" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler159" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler160" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler161" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler162" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler163" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler164" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler165" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler166" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler167" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler168" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler169" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler170" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler171" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler172" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler173" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler174" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler175" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler176" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler177" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler178" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler179" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler180" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler181" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler182" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler183" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler184" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler185" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler186" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler187" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler188" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler189" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler190" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler191" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler192" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler193" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler194" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler195" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler196" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler197" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler198" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler199" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler200" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler201" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler202" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler203" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler204" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler205" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler206" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler207" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler208" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler209" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler210" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler211" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler212" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler213" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler214" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler215" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler216" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler217" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler218" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler219" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler220" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler221" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler222" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler223" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler224" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler225" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler226" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler227" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler228" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler229" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler230" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler231" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler232" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler233" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler234" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler235" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler236" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler237" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler238" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler239" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler240" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler241" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler242" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler243" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler244" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler245" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler246" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler247" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler248" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler249" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler250" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler251" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler252" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler253" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler254" }),
            @extern(RawInterruptHandler, .{ .name = "interruptHandler255" }),
        };
    };
};

export fn interruptDispatch(interrupt_frame: *Interrupt.Frame) callconv(.c) void {
    const state_before_interrupt = cascade.Task.Current.onInterruptEntry();
    defer state_before_interrupt.onInterruptExit();

    switch (interrupt_frame.cs.selector) {
        .kernel_code => {},
        .user_code, .user_code_32bit => x64.Executor.current.disableSSEUsage(),
        else => unreachable,
    }
    defer switch (interrupt_frame.cs.selector) {
        .user_code, .user_code_32bit => {
            const x64_thread: *x64.Thread = .from(.from(cascade.Task.Current.get().task));
            x64.Executor.current.enableSSEUsage();
            x64_thread.extended_state.load();
        },
        .kernel_code => {},
        else => unreachable,
    };

    var handler = globals.handlers[interrupt_frame.vector_number.full];
    handler.call.setTemplatedArgs(.{ .{ .arch_specific = interrupt_frame }, state_before_interrupt });

    switch (handler.eoi) {
        .none => handler.call.call(),
        .after => {
            handler.call.call();
            x64.apic.eoi();
        },
        .before => {
            x64.apic.eoi();
            handler.call.call();
        },
    }

    x64.Executor.current.disableInterrupts();
}

const globals = struct {
    var idt: Idt = .{};
    var handlers: [Idt.number_of_handlers]arch.Interrupt.Handler = handlers: {
        @setEvalBranchQuota(4 * Idt.number_of_handlers);

        var temp_handlers: [Idt.number_of_handlers]arch.Interrupt.Handler = undefined;

        for (0..Idt.number_of_handlers) |i| {
            const interrupt: Interrupt = @enumFromInt(i);

            if (interrupt == .page_fault) {
                temp_handlers[i] = .{
                    .eoi = .none,
                    .call = .prepare(interrupt_handlers.earlyPageFaultHandler, .{}),
                };
                continue;
            }

            if (interrupt == .spurious_interrupt) {
                temp_handlers[i] = .{
                    .eoi = .none,
                    .call = .prepare(interrupt_handlers.spuriousInterruptHandler, .{}),
                };
                continue;
            }

            if (interrupt.isException()) {
                temp_handlers[i] = .{
                    .eoi = .none,
                    .call = .prepare(interrupt_handlers.unhandledException, .{}),
                };
            } else {
                temp_handlers[i] = .{
                    .eoi = .after,
                    .call = .prepare(interrupt_handlers.unhandledInterrupt, .{}),
                };
            }
        }

        break :handlers temp_handlers;
    };
    var interrupt_arena: cascade.mem.resource_arena.Arena(.none) = undefined; // initialized by `init.initializeInterruptRouting`
};

const Idt = struct {
    handlers: [number_of_handlers]Entry align(16) = std.mem.zeroes([number_of_handlers]Entry),

    /// The number of interrupt handlers in the IDT.
    pub const number_of_handlers = 256;

    pub const Entry = extern struct {
        /// Low 16-bits of ISR address
        pointer_low: u16,

        /// The code selector to switch to when the interrupt is recieved.
        code_selector: x64.Gdt.Selector,

        options: Options,

        /// Middle 16-bits of ISR address
        pointer_middle: u16,

        /// Upper 32-bits of ISR address
        pointer_high: u32,

        _reserved: u32 = 0,

        pub const Options = packed struct(u16) {
            /// Offset into the Interrupt Stack Table, zero means not used.
            ist: u3 = 0,

            _reserved1: u5 = 0,

            gate_type: GateType,

            _reserved2: u1 = 0,

            /// Defines the privilege levels which are allowed to access this interrupt via the INT instruction.
            ///
            /// Hardware interrupts ignore this mechanism.
            privilege_level: x64.PrivilegeLevel = .ring0,

            present: bool,
        };

        pub const GateType = enum(u4) {
            /// Interrupts are automatically disabled upon entry and reenabled upon IRET
            interrupt = 0xE,

            trap = 0xF,
        };

        pub fn init(
            entry: *Entry,
            code_selector: x64.Gdt.Selector,
            gate_type: GateType,
            handler: *const fn () callconv(.naked) void,
        ) void {
            entry.* = .{
                .pointer_low = undefined,
                .code_selector = code_selector,
                .options = .{
                    .gate_type = gate_type,
                    .present = true,
                },
                .pointer_middle = undefined,
                .pointer_high = undefined,
            };
            entry.setHandler(handler);
        }

        /// Sets the interrupt handler for this interrupt.
        pub fn setHandler(entry: *Entry, handler: *const fn () callconv(.naked) void) void {
            const address = @intFromPtr(handler);
            entry.pointer_low = @truncate(address);
            entry.pointer_middle = @truncate(address >> 16);
            entry.pointer_high = @truncate(address >> 32);
        }

        /// Sets the interrupt stack table (IST) index for this interrupt.
        pub fn setStack(entry: *Entry, interrupt_stack: u3) void {
            entry.options.ist = interrupt_stack +% 1;
        }

        comptime {
            core.testing.expectSize(Entry, core.Size.of(u64).multiplyScalar(2));
        }
    };

    pub fn load(idt: *const Idt) void {
        const Idtr = packed struct(u80) {
            limit: u16,
            address: u64,
        };

        const idtr = Idtr{
            .address = @intFromPtr(idt),
            .limit = @sizeOf(Idt) - 1,
        };

        asm volatile (
            \\  lidt (%[idtr_address])
            :
            : [idtr_address] "r" (&idtr),
        );
    }
};
