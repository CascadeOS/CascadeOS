// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const x86_64 = @import("../x86_64.zig");

const Idt = @import("Idt.zig");

pub const number_of_handlers = Idt.number_of_handlers;

const log = kernel.log.scoped(.interrupts_x86_64);

var idt: Idt = undefined;
const raw_handlers = makeRawHandlers();
var handlers = [_]InterruptHandler{unhandledInterrupt} ** number_of_handlers;

/// This function will load the IDT and fill the entries with raw handlers.
pub fn loadIdt() void {
    idt.load();

    log.debug("mapping idt entries to raw handlers", .{});
    for (raw_handlers, 0..) |raw_handler, i| {
        idt.handlers[i].init(
            x86_64.Gdt.kernel_code_selector,
            .interrupt,
            raw_handler,
        );
    }
}

pub const InterruptStackSelector = enum(u3) {
    exception = 0,
    double_fault = 1,
    interrupt = 2,
    non_maskable_interrupt = 3,
};

pub const InterruptHandler = *const fn (interrupt_frame: *InterruptFrame) void;

pub fn setVectorStack(vector: IdtVector, stack_selector: InterruptStackSelector) void {
    idt.handlers[@enumToInt(vector)].setStack(@enumToInt(stack_selector));
}

/// Handles all interrupts by printing the vector and then panicking.
fn unhandledInterrupt(interrupt_frame: *const InterruptFrame) void {
    const idt_vector = interrupt_frame.getIdtVector();

    // TODO: print specific things for each exception, especially page fault https://github.com/CascadeOS/CascadeOS/issues/32
    if (idt_vector.isException()) {
        core.panicFmt("exception {s}", .{@tagName(idt_vector)}) catch unreachable;
    }

    core.panicFmt("interrupt {d}", .{@enumToInt(idt_vector)}) catch unreachable;
}

/// Creates an array of raw interrupt handlers, one for each vector.
fn makeRawHandlers() [number_of_handlers](*const fn () callconv(.Naked) void) {
    var raw_handlers_temp: [number_of_handlers](*const fn () callconv(.Naked) void) = undefined;

    comptime var i = 0;
    inline while (i < number_of_handlers) : (i += 1) {
        const vector_number = @intCast(u8, i);
        const idt_vector = @intToEnum(IdtVector, vector_number);

        // if the cpu does not push an error code, we push a dummy error code to ensure the stack
        // is always aligned in the same way for every vector
        const need_to_push_dummy_error_code = comptime !idt_vector.hasErrorCode();

        const error_code_asm = if (need_to_push_dummy_error_code) "push $0\n" else "";
        const vector_number_asm = std.fmt.comptimePrint("push ${d}", .{vector_number});
        const data_selector_asm = std.fmt.comptimePrint("mov ${d}, %%ax", .{x86_64.Gdt.kernel_data_selector});

        // we need to ensure that we have the same stack position upon `iret` as upon entry
        // as we might push an error code the amount we need to bump the stack pointer by can change.
        const pop_error_code_and_vector_asm = std.fmt.comptimePrint(
            "add ${d}, %%rsp",
            .{if (need_to_push_dummy_error_code) 2 * @sizeOf(usize) else @sizeOf(usize)},
        );

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
                    ++ "\n" ++ pop_error_code_and_vector_asm ++ "\n" ++
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

    pub fn getIdtVector(self: *const InterruptFrame) IdtVector {
        return @intToEnum(IdtVector, @intCast(u8, self.padded_vector_number));
    }

    pub inline fn isKernel(self: *const InterruptFrame) bool {
        return self.cs == x86_64.Gdt.kernel_code_selector;
    }

    pub inline fn isUser(self: *const InterruptFrame) bool {
        return self.cs == x86_64.Gdt.user_code_selector;
    }

    pub fn format(
        value: *const InterruptFrame,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        const padding = "  ";

        try writer.writeAll("InterruptFrame{\n");

        try writer.print(padding ++ "Error Code: {},\n", .{value.error_code});
        try writer.print(padding ++ "Vector Number: {},\n", .{value.vector_number});

        try writer.print(padding ++ "cs: {},\n", .{value.cs});
        try writer.print(padding ++ "ss: {},\n", .{value.ss});
        try writer.print(padding ++ "ds: {},\n", .{value.ds});
        try writer.print(padding ++ "es: {},\n", .{value.es});
        try writer.print(padding ++ "rsp: 0x{x},\n", .{value.rsp});
        try writer.print(padding ++ "rip: 0x{x},\n", .{value.rip});
        try writer.print(padding ++ "rax: 0x{x},\n", .{value.rax});
        try writer.print(padding ++ "rbx: 0x{x},\n", .{value.rbx});
        try writer.print(padding ++ "rcx: 0x{x},\n", .{value.rcx});
        try writer.print(padding ++ "rdx: 0x{x},\n", .{value.rdx});
        try writer.print(padding ++ "rbp: 0x{x},\n", .{value.rbp});
        try writer.print(padding ++ "rsi: 0x{x},\n", .{value.rsi});
        try writer.print(padding ++ "rdi: 0x{x},\n", .{value.rdi});
        try writer.print(padding ++ "r8: 0x{x},\n", .{value.r8});
        try writer.print(padding ++ "r9: 0x{x},\n", .{value.r9});
        try writer.print(padding ++ "r10: 0x{x},\n", .{value.r10});
        try writer.print(padding ++ "r11: 0x{x},\n", .{value.r11});
        try writer.print(padding ++ "r12: 0x{x},\n", .{value.r12});
        try writer.print(padding ++ "r13: 0x{x},\n", .{value.r13});
        try writer.print(padding ++ "r14: 0x{x},\n", .{value.r14});
        try writer.print(padding ++ "r15: 0x{x},\n", .{value.r15});

        try writer.print(padding ++ "{},\n", .{value.rflags});

        try writer.writeAll("}");
    }
};

export fn interruptHandler(interrupt_frame: *InterruptFrame) void {
    if (interrupt_frame.isUser()) {
        // interrupt is from user code
        asm volatile ("swapgs");
    }

    handlers[@intCast(u8, interrupt_frame.padded_vector_number)](interrupt_frame);

    x86_64.interrupts.disableInterrupts();

    if (interrupt_frame.isUser()) {
        // returning to user code
        asm volatile ("swapgs");
    }
}

pub const IdtVector = enum(u8) {
    /// Occurs when dividing any number by 0 using the DIV or IDIV instruction, or when the division result is too
    /// large to be represented in the destination.
    ///
    /// The saved instruction pointer points to the DIV or IDIV instruction which caused the exception.
    division = 0x00,

    /// The Debug exception occurs on the following conditions:
    /// - Instruction fetch breakpoint (Fault)
    /// - General detect condition (Fault)
    /// - Data read or write breakpoint (Trap)
    /// - I/O read or write breakpoint (Trap)
    /// - Single-step (Trap)
    /// - Task-switch (Trap)
    ///
    /// When the exception is a fault, the saved instruction pointer points to the instruction which caused the
    /// exception.
    /// When the exception is a trap, the saved instruction pointer points to the instruction after the instruction
    /// which caused the exception.
    debug = 0x01,

    /// Non-Maskable Interrupt
    non_maskable_interrupt = 0x02,

    /// Occurs at the execution of the INT3 instruction
    /// The saved instruction pointer points to the byte after the INT3 instruction.
    breakpoint = 0x03,

    /// Raised when the INTO instruction is executed while the overflow bit in RFLAGS is set to 1.
    /// The saved instruction pointer points to the instruction after the INTO instruction.
    overflow = 0x04,

    /// Can occur when the BOUND instruction is executed.
    /// The BOUND instruction compares an array index with the lower and upper bounds of an array.
    /// When the index is out of bounds, the Bound Range Exceeded exception occurs.
    /// The saved instruction pointer points to the BOUND instruction which caused the exception.
    bound_range = 0x05,

    /// The Invalid Opcode exception occurs when the processor tries to execute an invalid or undefined opcode,
    /// or an instruction with invalid prefixes. It also occurs in other cases, such as:
    /// - The instruction length exceeds 15 bytes, but this only occurs with redundant prefixes.
    /// - The instruction tries to access a non-existent control register (for example, mov cr6, eax).
    /// - The UD instruction is executed.
    ///
    /// The saved instruction pointer points to the instruction which caused the exception.
    invalid_opcode = 0x06,

    /// Occurs when an FPU instruction is attempted but there is no FPU.
    /// The saved instruction pointer points to the instruction that caused the exception.
    device_not_available = 0x07,

    /// Occurs when an exception is unhandled or when an exception occurs while the CPU is trying to call an exception
    /// handler.
    /// The saved instruction pointer is undefined. A double fault cannot be recovered. The faulting process must be
    /// terminated.
    double_fault = 0x08,

    /// Legacy
    coprocessor_segment_overrun = 0x09,

    /// Occurs when an invalid segment selector is referenced as part of a task switch, or as a result of a control
    /// transfer through a gate descriptor, which results in an invalid stack-segment reference using an SS selector in
    /// the TSS.
    ///
    /// When the exception occurred before loading the segment selectors from the TSS, the saved instruction pointer
    /// points to the instruction which caused the exception. Otherwise, and this is more common, it points to the
    /// first instruction in the new task.
    invalid_tss = 0x0A,

    /// Occurs when trying to load a segment or gate which has its `Present` bit set to 0.
    /// The saved instruction pointer points to the instruction which caused the exception.
    segment_not_present = 0x0B,

    /// The Stack-Segment Fault occurs when:
    /// - Loading a stack-segment referencing a segment descriptor which is not present.
    /// - Any PUSH or POP instruction or any instruction using ESP or EBP as a base register is executed, while the
    /// stack address is not in canonical form.
    /// - When the stack-limit check fails.
    ///
    /// The saved instruction pointer points to the instruction which caused the exception, unless the fault occurred
    /// because of loading a non-present stack segment during a hardware task switch, in which case it points to the
    /// next instruction of the new task.
    stack = 0x0C,

    /// A General Protection Fault may occur for various reasons. The most common are:
    /// - Segment error (privilege, type, limit, read/write rights).
    /// - Executing a privileged instruction while CPL != 0.
    /// - Writing a 1 in a reserved register field or writing invalid value combinations (e.g. CR0 with PE=0 and PG=1).
    /// - Referencing or accessing a null-descriptor.
    ///
    /// The saved instruction pointer points to the instruction which caused the exception.
    general_protection = 0x0D,

    /// A Page Fault occurs when:
    /// - A page directory or table entry is not present in physical memory.
    /// - Attempting to load the instruction TLB with a translation for a non-executable page.
    /// - A protection check (privileges, read/write) failed.
    /// - A reserved bit in the page directory or table entries is set to 1.
    ///
    /// The saved instruction pointer points to the instruction which caused the exception.
    page = 0x0E,

    _reserved1 = 0x0F,

    /// occurs when the FWAIT or WAIT instruction, or any waiting floating-point instruction is executed, and the
    /// following conditions are true:
    /// - CR0.NE is 1;
    /// - an unmasked x87 floating point exception is pending (i.e. the exception bit in the x87 floating point
    /// status-word register is set to 1).
    ///
    /// The saved instruction pointer points to the instruction which is about to be executed when the exception
    /// occurred.
    /// The x87 instruction pointer register contains the address of the last instruction which caused the exception.
    x87_floating_point = 0x10,

    /// Occurs when alignment checking is enabled and an unaligned memory data reference is performed.
    /// Alignment checking is only performed in CPL 3.
    ///
    /// Alignment checking is disabled by default. To enable it, set the CR0.AM and RFLAGS.AC bits both to 1.
    ///
    /// The saved instruction pointer points to the instruction which caused the exception.
    alignment_check = 0x11,

    /// The Machine Check exception is model specific and processor implementations are not required to support it.
    /// It uses model-specific registers to provide error information.
    /// It is disabled by default.
    /// To enable it, set the CR4.MCE bit to 1.
    ///
    /// Machine check exceptions occur when the processor detects internal errors, such as bad memory, bus errors,
    /// cache errors, etc.
    ///
    /// The value of the saved instruction pointer depends on the implementation and the exception.
    machine_check = 0x12,

    /// Occurs when an unmasked 128-bit media floating-point exception occurs and the CR4.OSXMMEXCPT bit is set to 1.
    /// If the OSXMMEXCPT flag is not set, then SIMD floating-point exceptions will cause an Undefined Opcode exception
    /// instead of this.
    ///
    /// The saved instruction pointer points to the instruction which caused the exception.
    simd_floating_point = 0x13,

    /// Virtualization Exception (Intel-only)
    virtualization = 0x14,

    /// Control Protection Exception
    control_protection = 0x15,

    _reserved2 = 0x16,
    _reserved3 = 0x17,
    _reserved4 = 0x18,
    _reserved5 = 0x19,
    _reserved6 = 0x1A,
    _reserved7 = 0x1B,

    /// Hypervisor Injection (AMD-only)
    hypervisor_injection = 0x1C,

    /// VMM Communication (AMD-only)
    vmm_communication = 0x1D,

    /// Security Exception
    security = 0x1E,

    _reserved8 = 0x1F,

    _,

    pub fn isException(self: IdtVector) bool {
        if (@enumToInt(self) <= @enumToInt(IdtVector._reserved8)) {
            return self != IdtVector.non_maskable_interrupt;
        }
        return false;
    }

    pub fn hasErrorCode(self: IdtVector) bool {
        return switch (@enumToInt(self)) {
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

/// Enable interrupts and put the CPU to sleep.
pub noinline fn enableInterruptsAndHalt() void {
    // TODO: The NMI handler will need to check if the IP is equal to __halt_addr and if so, it will need to skip the
    // hlt instruction. https://github.com/CascadeOS/CascadeOS/issues/33
    asm volatile (
        \\sti
        \\.globl __halt_addr
        \\__halt_addr:
        \\hlt
        \\
    );
}
