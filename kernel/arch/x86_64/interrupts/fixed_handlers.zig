// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");
const x86_64 = @import("../x86_64.zig");

const log = kernel.debug.log.scoped(.interrupt);

/// Occurs when dividing any number by 0 using the DIV or IDIV instruction, or when the division result is too
/// large to be represented in the destination.
///
/// The saved instruction pointer points to the DIV or IDIV instruction which caused the exception.
pub fn divideErrorException(interrupt_frame: *const x86_64.interrupts.InterruptFrame) void {
    _ = interrupt_frame;

    core.panic("divide error exception");
}

/// The Debug exception occurs on the following conditions:
/// - Instruction execution.
/// - Instruction single stepping.
/// - Data read.
/// - Data write.
/// - I/O read.
/// - I/O write.
/// - Task switch.
/// - Debug-register access, or general detect fault (debug register access when DR7.GD=1).
/// - Executing the INT1 instruction (opcode 0F1h)
///
/// When the exception is a fault, the saved instruction pointer points to the instruction which caused the
/// exception.
///
/// When the exception is a trap, the saved instruction pointer points to the instruction after the instruction
/// which caused the exception.
pub fn debugException(interrupt_frame: *const x86_64.interrupts.InterruptFrame) void {
    _ = interrupt_frame;

    core.panic("debug exception");
}

/// The nonmaskable interrupt (NMI) is generated externally by asserting the processor’s NMI pin or through an NMI
/// request set by the I/O APIC to the local APIC. This interrupt causes the NMI interrupt handler to be called.
///
/// When a core panics it send a NMI IPI to all other cores.
pub fn nonMaskableInterrupt(interrupt_frame: *const x86_64.interrupts.InterruptFrame) void {
    _ = interrupt_frame;

    if (kernel.debug.hasAProcessorPanicked()) {
        // we have received a panic nmi
        kernel.arch.interrupts.disableInterruptsAndHalt();
        unreachable;
    }

    core.panic("non-maskable interrupt");
}

/// Occurs at the execution of the INT3 instruction.
///
/// The saved instruction pointer points to the byte after the INT3 instruction.
pub fn breakpointException(interrupt_frame: *const x86_64.interrupts.InterruptFrame) void {
    _ = interrupt_frame;

    core.panic("breakpoint exception");
}

/// Raised when the INTO instruction is executed while the overflow bit in RFLAGS is set to 1.
///
/// The saved instruction pointer points to the instruction after the INTO instruction.
pub fn overflowException(interrupt_frame: *const x86_64.interrupts.InterruptFrame) void {
    _ = interrupt_frame;

    core.panic("overflow exception");
}

/// Can occur when the BOUND instruction is executed.
///
/// The BOUND instruction compares an array index with the lower and upper bounds of an array.
///
/// When the index is out of bounds, the Bound Range Exceeded exception occurs.
///
/// The saved instruction pointer points to the BOUND instruction which caused the exception.
pub fn boundRangeExceededException(interrupt_frame: *const x86_64.interrupts.InterruptFrame) void {
    _ = interrupt_frame;

    core.panic("bound range exceeded exception");
}

/// The Invalid Opcode exception occurs when the processor tries to execute an invalid or undefined opcode,
/// or an instruction with invalid prefixes.
///
/// It also occurs in other cases, such as:
/// - The instruction length exceeds 15 bytes, but this only occurs with redundant prefixes.
/// - The instruction tries to access a non-existent control register (for example, mov cr6, eax).
/// - The UD instruction is executed.
///
/// The saved instruction pointer points to the instruction which caused the exception.
pub fn invalidOpcodeException(interrupt_frame: *const x86_64.interrupts.InterruptFrame) void {
    _ = interrupt_frame;

    core.panic("invalid opcode exception");
}

/// Occurs when an FPU instruction is attempted but there is no FPU.
///
/// The saved instruction pointer points to the instruction that caused the exception.
pub fn deviceNotAvailableException(interrupt_frame: *const x86_64.interrupts.InterruptFrame) void {
    _ = interrupt_frame;

    core.panic("device not available exception");
}

/// Occurs when an exception is unhandled or when an exception occurs while the CPU is trying to call an exception
/// handler.
///
/// The saved instruction pointer is undefined. A double fault cannot be recovered. The faulting process must be
/// terminated.
pub fn doubleFaultException(interrupt_frame: *const x86_64.interrupts.InterruptFrame) noreturn {
    _ = interrupt_frame;

    core.panic("double fault exception");
}

/// Occurs when an invalid segment selector is referenced as part of a task switch, or as a result of a control
/// transfer through a gate descriptor, which results in an invalid stack-segment reference using an SS selector in
/// the TSS.
pub fn invalidTSSException(interrupt_frame: *const x86_64.interrupts.InterruptFrame) void {
    _ = interrupt_frame;

    core.panic("invalid tss exception");
}

/// Occurs when trying to load a segment or gate which has its `Present` bit set to 0.
///
/// The saved instruction pointer points to the instruction which caused the exception.
pub fn segmentNotPresentException(interrupt_frame: *const x86_64.interrupts.InterruptFrame) void {
    _ = interrupt_frame;

    core.panic("segment not present exception");
}

/// The Stack-Segment Fault occurs when:
/// - Loading a stack-segment referencing a segment descriptor which is not present.
/// - Any PUSH or POP instruction or any instruction using ESP or EBP as a base register is executed, while the
/// stack address is not in canonical form.
/// - When the stack-limit check fails.
///
/// The saved instruction pointer points to the instruction which caused the exception, unless the fault occurred
/// because of loading a non-present stack segment during a hardware task switch, in which case it points to the
/// next instruction of the new task.
pub fn stackFaultException(interrupt_frame: *const x86_64.interrupts.InterruptFrame) void {
    _ = interrupt_frame;

    core.panic("stack fault exception");
}

/// A General Protection Fault may occur for various reasons.
///
/// The most common are:
/// - Segment error (privilege, type, limit, read/write rights).
/// - Executing a privileged instruction while CPL != 0.
/// - Writing a 1 in a reserved register field or writing invalid value combinations (e.g. CR0 with PE=0 and PG=1).
/// - Referencing or accessing a null-descriptor.
///
/// The saved instruction pointer points to the instruction which caused the exception.
pub fn generalProtectionException(interrupt_frame: *const x86_64.interrupts.InterruptFrame) void {
    _ = interrupt_frame;

    core.panic("general protection exception");
}

/// A Page Fault occurs when:
///
/// - A page directory or table entry is not present in physical memory.
/// - Attempting to load the instruction TLB with a translation for a non-executable page.
/// - A protection check (privileges, read/write) failed.
/// - A reserved bit in the page directory or table entries is set to 1.
///
/// The saved instruction pointer points to the instruction which caused the exception.
pub fn pageFaultException(interrupt_frame: *const x86_64.interrupts.InterruptFrame) void {
    if (interrupt_frame.isKernel()) {
        const faulting_address = x86_64.Cr2.readAddress();
        const fault = x86_64.PageFaultErrorCode.fromErrorCode(interrupt_frame.error_code);

        core.panicFmt("kernel page fault @ {} - {}", .{ faulting_address, fault });
    }

    core.panic("page fault exception");
}

/// Occurs when the FWAIT or WAIT instruction, or any waiting floating-point instruction is executed, and the
/// following conditions are true:
/// - CR0.NE is 1;
/// - an unmasked x87 floating point exception is pending (i.e. the exception bit in the x87 floating point
/// status-word register is set to 1).
///
/// The saved instruction pointer points to the instruction which is about to be executed when the exception
/// occurred.
///
/// The x87 instruction pointer register contains the address of the last instruction which caused the exception.
pub fn x87FPUFloatingPointException(interrupt_frame: *const x86_64.interrupts.InterruptFrame) void {
    _ = interrupt_frame;

    core.panic("x87 FPU floating point exception");
}

/// Occurs when alignment checking is enabled and an unaligned memory data reference is performed.
///
/// Alignment checking is only performed in CPL 3.
///
/// Alignment checking is disabled by default. To enable it, set the CR0.AM and RFLAGS.AC bits both to 1.
///
/// The saved instruction pointer points to the instruction which caused the exception.
pub fn alignmentCheckException(interrupt_frame: *const x86_64.interrupts.InterruptFrame) void {
    _ = interrupt_frame;

    core.panic("alignment check exception");
}

/// The Machine Check exception is model specific and processor implementations are not required to support it.
///
/// It uses model-specific registers to provide error information.
///
/// Ddisabled by default, to enable set CR4.MCE bit to 1.
///
/// Machine check exceptions occur when the processor detects internal errors, such as bad memory, bus errors,
/// cache errors, etc.
///
/// The value of the saved instruction pointer depends on the implementation and the exception.
pub fn machineCheckException(interrupt_frame: *const x86_64.interrupts.InterruptFrame) noreturn {
    _ = interrupt_frame;

    core.panic("machine check exception");
}

/// Occurs when an unmasked 128-bit media floating-point exception occurs and the CR4.OSXMMEXCPT bit is set to 1.
///
/// If the OSXMMEXCPT flag is not set, then SIMD floating-point exceptions will cause an Undefined Opcode exception
/// instead of this.
///
/// The saved instruction pointer points to the instruction which caused the exception.
pub fn simdFloatingPointException(interrupt_frame: *const x86_64.interrupts.InterruptFrame) void {
    _ = interrupt_frame;

    core.panic("SIMD floating point exception");
}

/// Virtualization Exception
///
/// Intel Only
pub fn virtualizationException(interrupt_frame: *const x86_64.interrupts.InterruptFrame) void {
    _ = interrupt_frame;

    core.panic("virtualization exception");
}

/// A #CP exception is generated when shadow stacks are enabled (CR4.CET=1) and any of the following situations occur:
/// - For RET or IRET instructions, the return addresses on the shadow stack and the data stack do not match.
/// - An invalid supervisor shadow stack token is encountered by the CALL, RET, IRET, SETSSBSY or RSTORSSP instructions
/// or during the delivery of an interrupt or exception.
/// - For inter-privilege RET and IRET instructions, the SSP is not 8-byte aligned, or the previous SSP from shadow
/// stack is not 4-byte aligned or, in legacy or compatibility mode, is not less than 4GB.
/// - A task switch initiated by IRET where the incoming SSP is not aligned to 4 bytes or is not less than 4GB.
pub fn controlProtectionException(interrupt_frame: *const x86_64.interrupts.InterruptFrame) void {
    _ = interrupt_frame;

    core.panic("control protection exception");
}

/// The hypervisor injection exception may be injected by the hypervisor into a secure guest VM to notify the VM of
/// pending events.
///
/// AMD Only.
pub fn hypervisorInjectionException(interrupt_frame: *const x86_64.interrupts.InterruptFrame) void {
    _ = interrupt_frame;

    core.panic("hypervisor injection exception");
}

/// The VMM communication exception is generated when certain events occur inside a secure guest VM.
///
/// AMD Only.
pub fn vmmCommunicationException(interrupt_frame: *const x86_64.interrupts.InterruptFrame) void {
    _ = interrupt_frame;

    core.panic("vmm communication exception");
}

/// The security exception is generated by security-sensitive events under SVM.
///
/// AMD Only.
pub fn securityException(interrupt_frame: *const x86_64.interrupts.InterruptFrame) void {
    _ = interrupt_frame;

    core.panic("security exception");
}

pub fn scheduler(interrupt_frame: *const x86_64.interrupts.InterruptFrame) void {
    _ = interrupt_frame;

    x86_64.apic.eoi();

    const held = kernel.scheduler.lock.lock();
    defer held.unlock();
    kernel.scheduler.schedule(true);
}

/// Handles unhandled interrupts by printing the vector and then panicking.
pub fn unhandledInterrupt(interrupt_frame: *const x86_64.interrupts.InterruptFrame) void {
    const interrupt = interrupt_frame.vector_number.interrupt;

    core.assert(!interrupt.isException());

    core.panicFmt("interrupt: {}", .{interrupt}) catch unreachable;
}
