// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const Task = cascade.Task;
const core = @import("core");

const x64 = @import("x64.zig");

pub const RFlags = packed struct(u64) {
    /// Set by hardware if last arithmetic operation generated a carry out of the most-significant bit of the result.
    carry: bool,

    _reserved1: u1,

    /// Set by hardware if last result has an even number of 1 bits (only for some operations).
    parity: bool,

    _reserved2: u1,

    /// Set by hardware if last arithmetic operation generated a carry out of bit 3 of the result.
    auxiliary_carry: bool,

    _reserved3: u1,

    /// Set by hardware if last arithmetic operation resulted in a zero value.
    zero: bool,

    /// Set by hardware if last arithmetic operation resulted in a negative value.
    sign: bool,

    /// Enable single-step mode for debugging.
    trap: bool,

    /// Enable interrupts.
    enable_interrupts: bool,

    /// Determines the order in which strings are processed.
    direction: Direction,

    /// Set by hardware to indicate that the sign bit of the result of the last signed integer operation differs from
    /// the source operands.
    overflow: bool,

    /// Specifies the privilege level required for executing I/O address-space instructions.
    iopl: x64.PrivilegeLevel,

    /// Used by `iret` in hardware task switch mode to determine if current task is nested.
    nested: bool,

    _reserved4: u1,

    /// Allows to restart an instruction following an instrucion breakpoint.
    @"resume": bool,

    /// Enable the virtual-8086 mode.
    virtual_8086: bool,

    /// Enable automatic alignment checking if CR0.AM is set.
    ///
    /// Only works if CPL is 3.
    alignment_check: bool,

    /// Virtual image of the INTERRUPT_FLAG bit.
    ///
    /// Used when virtual-8086 mode extensions (CR4.VME) or protected-mode virtual interrupts (CR4.PVI) are activated.
    virtual_interrupt: bool,

    /// Indicates that an external, maskable interrupt is pending.
    ///
    /// Used when virtual-8086 mode extensions (CR4.VME) or protected-mode virtual interrupts (CR4.PVI) are activated.
    virtual_interrupt_pending: bool,

    /// Processor feature identification flag.
    ///
    /// If this flag is modifiable, the CPU supports CPUID.
    id: bool,

    _reserved5: u42,

    pub const Direction = enum(u1) {
        up = 0,
        down = 1,
    };

    /// Returns the current value of the RFLAGS register.
    pub inline fn read() RFlags {
        return @bitCast(asm ("pushfq; popq %[ret]"
            : [ret] "=r" (-> u64),
        ));
    }

    /// Writes the RFLAGS register.
    ///
    /// Note: does not protect reserved bits, that is left up to the caller
    pub inline fn write(rflags: RFlags) void {
        asm volatile ("pushq %[val]; popfq"
            :
            : [val] "r" (@as(u64, @bitCast(rflags))),
            : .{ .flags = true });
    }

    pub fn print(rflags: RFlags, writer: *std.Io.Writer, indent: usize) !void {
        const new_indent = indent + 2;

        try writer.writeAll("RFlags{\n");

        try writer.splatByteAll(' ', new_indent);
        try writer.print("carry: {},\n", .{rflags.carry});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("parity: {},\n", .{rflags.parity});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("auxiliary_carry: {},\n", .{rflags.auxiliary_carry});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("zero: {},\n", .{rflags.zero});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("sign: {},\n", .{rflags.sign});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("trap: {},\n", .{rflags.trap});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("enable_interrupts: {},\n", .{rflags.enable_interrupts});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("direction: {},\n", .{rflags.direction});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("overflow: {},\n", .{rflags.overflow});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("iopl: {t},\n", .{rflags.iopl});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("nested: {},\n", .{rflags.nested});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("resume: {},\n", .{rflags.@"resume"});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("virtual_8086: {},\n", .{rflags.virtual_8086});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("alignment_check: {},\n", .{rflags.alignment_check});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("virtual_interrupt: {},\n", .{rflags.virtual_interrupt});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("virtual_interrupt_pending: {},\n", .{rflags.virtual_interrupt_pending});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("id: {},\n", .{rflags.id});

        try writer.splatByteAll(' ', indent);
        try writer.writeAll("}");
    }

    pub inline fn format(
        rflags: RFlags,
        writer: *std.Io.Writer,
    ) !void {
        return print(rflags, writer, 0);
    }

    comptime {
        core.testing.expectSize(RFlags, @sizeOf(u64));
    }
};

pub const Cr0 = packed struct(u64) {
    /// Enables protected mode.
    protected_mode_enable: bool,

    /// Enables monitoring of the coprocessor.
    monitor_coprocessor: bool,

    /// Force all x87 and MMX instructions to cause an `#NE` exception.
    emulate_coprocessor: bool,

    /// Automatically set to 1 on _hardware_ task switch.
    task_switched: bool,

    /// Indicates support of 387DX math coprocessor instructions.
    extension_type: bool,

    /// Enables the native (internal) error reporting mechanism for x87 FPU errors.
    numeric_error: bool,

    _reserved6_15: u10,

    /// Controls whether supervisor-level writes to read-only pages are inhibited.
    write_protect: bool,

    _reserved17: u1,

    /// Enables automatic usermode alignment checking if `RFlags.alignment_mask` is also set.
    alignment_mask: bool,

    _reserved19_28: u10,

    /// Ignored, should always be unset.
    not_write_through: bool,

    /// Disables some processor caches, specifics are model-dependent.
    cache_disable: bool,

    /// Enables paging.
    paging: bool,

    _reserved32_63: u32,

    pub fn read() Cr0 {
        return @bitCast(asm ("mov %%cr0, %[value]"
            : [value] "=r" (-> u64),
        ));
    }

    pub fn write(cr0: Cr0) void {
        asm volatile ("mov %[value], %%cr0"
            :
            : [value] "r" (@as(u64, @bitCast(cr0))),
        );
    }
};

/// Stores the linear address that was accessed to result in the last page fault.
pub const Cr2 = struct {
    /// Read the page fault linear address from the CR2 register.
    pub inline fn readAddress() core.VirtualAddress {
        return core.VirtualAddress.fromInt(asm ("mov %%cr2, %[value]"
            : [value] "=r" (-> u64),
        ));
    }
};

pub const Cr3 = struct {
    /// Reads the CR3 register and returns the page table address.
    pub inline fn readAddress() core.PhysicalAddress {
        return core.PhysicalAddress.fromInt(asm ("mov %%cr3, %[value]"
            : [value] "=r" (-> u64),
        ) & 0xFFFF_FFFF_FFFF_F000);
    }

    /// Writes the CR3 register with the given page table address.
    pub inline fn writeAddress(address: core.PhysicalAddress) void {
        asm volatile ("mov %[address], %%cr3"
            :
            : [address] "r" (address.value & 0xFFFF_FFFF_FFFF_F000),
            : .{ .memory = true });
    }
};

pub const Cr4 = packed struct(u64) {
    /// Enables hardware-supported performance enhancements for software running in virtual-8086 mode.
    virtual_8086_mode_extensions: bool,

    /// Enables support for protected-mode virtual interrupts.
    protected_mode_virtual_interrupts: bool,

    /// When set, only privilege-level 0 can execute the `RDTSC` or `RDTSCP` instructions.
    time_stamp_disable: bool,

    /// Enables I/O breakpoint capability and enforces treatment of `DR4` and `DR5` registers as reserved.
    debugging_extensions: bool,

    /// Enables 4-MByte pages with 32-bit paging when `true`; restricts 32-bit paging to pages of 4 KBytes when `false`.
    page_size_extension: bool,

    /// Enables physical address extensions and 2MB physical frames.
    ///
    /// Required in long mode.
    physical_address_extension: bool,

    /// Enables the machine-check exception mechanism.
    machine_check_exception: bool,

    /// Enables the global page feature, allowing some page translations to be marked as global.
    page_global: bool,

    /// Allows software running at any privilege level to use the `RDPMC` instruction.
    performance_monitoring_counter: bool,

    /// Enables the use of legacy SSE instructions; allows using `FXSAVE`/`FXRSTOR` for saving processor state of
    /// 128-bit media instructions.
    os_fxsave: bool,

    /// Enables the SIMD floating-point exception (`#XF`) for handling unmasked 256-bit and 128-bit media floating-point
    /// errors.
    unmasked_exception_support: bool,

    /// Prevents the execution of the `SGDT`, `SIDT`, `SLDT`, `SMSW`, and `STR` instructions by user-mode software.
    usermode_instruction_prevention: bool,

    /// Enables 5-level paging on supported CPUs.
    level_5_paging: bool,

    /// Enables VMX instructions.
    ///
    /// Intel only.
    virtual_machine_extensions: bool,

    /// Enables SMX instructions.
    ///
    /// Intel only.
    safer_mode_extensions: bool,

    _reserved15: u1,

    /// Enables software running in 64-bit mode at any privilege level to read and write the FS.base and GS.base hidden
    /// segment register state.
    fsgsbase: bool,

    /// Enables process-context identifiers.
    pcid: bool,

    /// Enables extended processor state management instructions, including `XGETBV` and `XSAVE`.
    osxsave: bool,

    /// Enables the Key Locker feature.
    ///
    /// Intel only.
    key_locker: bool,

    /// Prevents the execution of instructions that reside in pages accessible by user-mode software when the processor
    /// is in supervisor-mode.
    supervisor_mode_execution_prevention: bool,

    /// Enables restrictions for supervisor-mode software when reading data from user-mode pages.
    supervisor_mode_access_prevention: bool,

    /// Enables protection keys for user-mode pages.
    ///
    /// Also enables access to the PKRU register (via the `RDPKRU`/`WRPKRU`
    /// instructions) to set user-mode protection key access controls.
    protection_key_user: bool,

    /// Enables Control-flow Enforcement Technology
    ///
    /// This enables the shadow stack feature, ensuring return addresses read via `RET` and `IRET` have not been
    /// corrupted.
    control_flow_enforcement: bool,

    /// Enables protection keys for supervisor-mode pages.
    ///
    /// Intel only.
    protection_key_supervisor: bool,

    /// Enables user interrupts when `true`, including user-interrupt delivery, user-interrupt notification
    /// identification and the user-interrupt instructions.
    ///
    /// Intel only.
    user_interrupt: bool,

    _reserved26_27: u2,

    /// When set, enables LAM (linear-address masking) for supervisor pointers.
    ///
    /// Intel only.
    supervisor_lam: bool,

    _reserved29_63: u35,

    pub fn read() Cr4 {
        return @bitCast(asm ("mov %%cr4, %[value]"
            : [value] "=r" (-> u64),
        ));
    }

    pub fn write(cr4: Cr4) void {
        asm volatile ("mov %[value], %%cr4"
            :
            : [value] "r" (@as(u64, @bitCast(cr4))),
        );
    }
};

pub const XCr0 = packed struct(u64) {
    /// x87 FPU state
    ///
    /// Must always be `true`
    x87: bool,

    /// 128-bit SSE state
    sse: bool,

    /// 256-bit SSE (AVX) state
    ///
    /// If `true` then `sse` must be `true`
    avx: bool,

    /// Intel Only
    mpx: MPX,

    avx512: AVX512,

    /// Intel Processor Trace
    ///
    /// Intel Only
    pt: bool,

    pkru: bool,

    _reserved0: u7,

    /// Intel Only
    amx: AMX,

    _reserved1: u43,

    /// Lightweight Profiling
    ///
    /// AMD Only
    lwp: bool,

    _reserved2: u1,

    pub const MPX = enum(u2) {
        false = 0b00,
        true = 0b11,
    };

    pub const AVX512 = enum(u3) {
        false = 0b000,
        true = 0b111,
    };

    pub const AMX = enum(u2) {
        false = 0b00,
        true = 0b11,
    };

    pub fn read() XCr0 {
        var lo: u32 = undefined;
        var hi: u32 = undefined;

        asm ("xgetbv"
            : [hi] "={edx}" (hi),
              [lo] "={eax}" (lo),
            : [_] "{ecx}" (0),
        );

        return @bitCast(
            @as(u64, hi) << 32 |
                @as(u64, lo),
        );
    }

    pub fn write(xcr0: XCr0) void {
        const raw: u64 = @bitCast(xcr0);

        asm volatile ("xsetbv"
            :
            : [_] "{ecx}" (0),
              [hi] "{edx}" (@as(u32, @truncate(raw >> 32))),
              [lo] "{eax}" (@as(u32, @truncate(raw))),
        );
    }

    pub fn print(xcr0: XCr0, writer: *std.Io.Writer, indent: usize) !void {
        const new_indent = indent + 2;

        try writer.writeAll("XCr0{\n");

        try writer.splatByteAll(' ', new_indent);
        try writer.print("x87: {},\n", .{xcr0.x87});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("sse: {},\n", .{xcr0.sse});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("avx: {},\n", .{xcr0.avx});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("mpx: {t},\n", .{xcr0.mpx});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("avx512: {t},\n", .{xcr0.avx512});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("pt: {},\n", .{xcr0.pt});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("pkru: {},\n", .{xcr0.pkru});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("amx: {t},\n", .{xcr0.amx});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("lwp: {},\n", .{xcr0.lwp});

        try writer.splatByteAll(' ', indent);
        try writer.writeAll("}");
    }

    pub inline fn format(
        xcr0: XCr0,
        writer: *std.Io.Writer,
    ) !void {
        return print(xcr0, writer, 0);
    }

    comptime {
        core.testing.expectSize(XCr0, @sizeOf(u64));
    }
};

/// Extended Feature Enable Register (EFER)
pub const EFER = packed struct(u64) {
    syscall_enable: bool,

    _reserved1_7: u7,

    long_mode_enable: bool,

    _reserved9: u1,

    long_mode_active: bool,

    no_execute_enable: bool,

    secure_virtual_machine_enable: bool,

    long_mode_segment_limit_enable: bool,

    fast_fxsave_fxrstor: bool,

    translation_cache_extension: bool,

    _reserved16: u1,

    mcommit_instruction_enable: bool,

    interruptible_wb_enable: bool,

    _reserved19: u1,

    upper_address_ingore_enable: bool,

    automatic_ibrs_enable: bool,

    _reserved22_63: u42,

    pub inline fn read() EFER {
        return @bitCast(msr.read());
    }

    pub inline fn write(efer: EFER) void {
        msr.write(@bitCast(efer));
    }

    const msr = MSR(u64, 0xC0000080);
};

/// MTRR Capability Register (MTRRCAP)
pub const IA32_MTRRCAP = packed struct(u64) {
    /// Indicates the number of variable ranges implemented on the processor.
    number_of_variable_range_registers: u8,

    /// Fixed range MTRRs (IA32_MTRR_FIX64K_00000 through IA32_MTRR_FIX4K_0F8000) are supported when `true`; no fixed
    /// range registers are supported when `false`.
    fixed_range_registers_supported: bool,

    _reserved9: u1,

    /// The write-combining (WC) memory type is supported when `true`; the WC type is not supported when `false`.
    write_combining_supported: bool,

    /// The system-management range register (SMRR) interface is supported when `true`; the SMRR interface is not
    /// supported when `false`.
    system_management_range_register_supported: bool,

    _reserved12_63: u52,

    pub inline fn read() IA32_MTRRCAP {
        return @bitCast(msr.read());
    }

    const msr = MSR(u64, 0xFE);
};

pub const PAT = packed struct(u64) {
    entry0: MemoryType,

    _reserved3_7: u5,

    entry1: MemoryType,

    _reserved11_15: u5,

    entry2: MemoryType,

    _reserved19_23: u5,

    entry3: MemoryType,

    _reserved27_31: u5,

    entry4: MemoryType,

    _reserved35_39: u5,

    entry5: MemoryType,

    _reserved43_47: u5,

    entry6: MemoryType,

    _reserved51_55: u5,

    entry7: MemoryType,

    _reserved59_63: u5,

    pub const MemoryType = enum(u3) {
        unchacheable = 0x0,
        write_combining = 0x1,
        write_through = 0x4,
        write_protected = 0x5,
        write_back = 0x6,
        uncached = 0x7,
    };

    pub inline fn read() PAT {
        return @bitCast(msr.read());
    }

    pub inline fn write(value: PAT) void {
        msr.write(@bitCast(value));
    }

    pub fn print(pat: PAT, writer: *std.Io.Writer, indent: usize) !void {
        const new_indent = indent + 2;

        try writer.writeAll("PAT{\n");

        try writer.splatByteAll(' ', new_indent);
        try writer.print("entry0: {t},\n", .{pat.entry0});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("entry1: {t},\n", .{pat.entry1});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("entry2: {t},\n", .{pat.entry2});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("entry3: {t},\n", .{pat.entry3});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("entry4: {t},\n", .{pat.entry4});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("entry5: {t},\n", .{pat.entry5});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("entry6: {t},\n", .{pat.entry6});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("entry7: {t},\n", .{pat.entry7});

        try writer.splatByteAll(' ', indent);
        try writer.writeByte('}');
    }

    pub inline fn format(
        pat: PAT,
        writer: *std.Io.Writer,
    ) !void {
        return pat.print(pat, writer, 0);
    }

    const msr = MSR(u64, 0x277);
};

pub const DR0 = DebugAddressRegister(.DR0);
pub const DR1 = DebugAddressRegister(.DR1);
pub const DR2 = DebugAddressRegister(.DR2);
pub const DR3 = DebugAddressRegister(.DR3);

/// Debug-Status Register (DR6)
///
/// Debug status is loaded into DR6 when an enabled debug condition is encountered that causes a #DB exception.
///
/// `breakpoint_register_access_detected`, `single_step`, and `task_switch` are not cleared by the processor and must be
/// cleared by software after the contents have been read.
pub const DR6 = packed struct(u64) {
    breakpoint_0: bool,
    breakpoint_1: bool,
    breakpoint_2: bool,
    breakpoint_3: bool,

    _reserved4_10: u7,

    /// The processor set this to `false` if #DB was generated due to a bus lock.
    ///
    /// Other sources of #DB do not modify this bit.
    bus_lock_detected: bool,

    _reserved_12: u1,

    /// The processor sets this bit to 1 if software accesses any debug register (DR0–DR7) while the general-detect
    /// condition is enabled (`DR7.general_detect = true`).
    breakpoint_register_access_detected: bool,

    /// The processor sets this bit to 1 if the #DB exception occurs as a result of single-step mode
    /// (`RFlags.trap = true`).
    ///
    /// Single-step mode has the highest-priority among debug exceptions.
    ///
    /// Other status bits within the DR6 register can be set by the processor along with the BS bit.
    single_step: bool,

    /// The processor sets this bit to 1 if the #DB exception occurred as a result of task switch to a task with a
    /// TSS T-bit set to 1.
    task_switch: bool,

    _reserved16_31: u16,

    _reserved32_63: u32,

    pub fn read() DR6 {
        return @bitCast(asm ("mov %%dr6, %[value]"
            : [value] "=r" (-> u64),
        ));
    }

    pub fn write(dr6: DR6) void {
        asm volatile ("mov %[value], %%dr6"
            :
            : [value] "r" (@as(u64, @bitCast(dr6))),
        );
    }
};

/// Debug-Control Register (DR7)
///
/// DR7 is used to establish the breakpoint conditions for the address-breakpoint registers (DR0–DR3) and to enable
/// debug exceptions for each address-breakpoint register individually.
///
/// DR7 is also used to enable the general detect breakpoint condition.
pub const DR7 = packed struct(u64) {
    /// When `true` debug exceptions occur when the corresponding address-breakpoint register (DR0) detects a breakpoint
    /// condition while executing the current task.
    ///
    /// Cleared to `false` by the processor when a hardware task-switch occurs.
    local_exact_breakpoint_0: bool,

    /// When `true` debug exceptions occur when the corresponding address-breakpoint register (DR0) detects a breakpoint
    /// condition while executing any task.
    ///
    /// These bits are never cleared to `false` by the processor.
    global_exact_breakpoint_0: bool,

    /// When `true` debug exceptions occur when the corresponding address-breakpoint register (DR1) detects a breakpoint
    /// condition while executing the current task.
    ///
    /// Cleared to `false` by the processor when a hardware task-switch occurs.
    local_exact_breakpoint_1: bool,

    /// When `true` debug exceptions occur when the corresponding address-breakpoint register (DR1) detects a breakpoint
    /// condition while executing any task.
    ///
    /// These bits are never cleared to `false` by the processor.
    global_exact_breakpoint_1: bool,

    /// When `true` debug exceptions occur when the corresponding address-breakpoint register (DR2) detects a breakpoint
    /// condition while executing the current task.
    ///
    /// Cleared to `false` by the processor when a hardware task-switch occurs.
    local_exact_breakpoint_2: bool,

    /// When `true` debug exceptions occur when the corresponding address-breakpoint register (DR2) detects a breakpoint
    /// condition while executing any task.
    ///
    /// These bits are never cleared to `false` by the processor.
    global_exact_breakpoint_2: bool,

    /// When `true` debug exceptions occur when the corresponding address-breakpoint register (DR3) detects a breakpoint
    /// condition while executing the current task.
    ///
    /// Cleared to `false` by the processor when a hardware task-switch occurs.
    local_exact_breakpoint_3: bool,

    /// When `true` debug exceptions occur when the corresponding address-breakpoint register (DR3) detects a breakpoint
    /// condition while executing any task.
    ///
    /// These bits are never cleared to `false` by the processor.
    global_exact_breakpoint_3: bool,

    /// This bit is ignored by implementations of the AMD64 architecture.
    local_exact_breakpoint: bool,

    /// This bit is ignored by implementations of the AMD64 architecture.
    global_exact_breakpoint: bool,

    _reserved10: u1,

    _reserved11_12: u2,

    /// Software sets this to `true` to cause a debug exception to occur when an attempt is made to execute a MOV DRn
    /// instruction to any debug register (DR0–DR7).
    ///
    /// This bit is set to `false` by the processor when the #DB handler is entered, allowing the handler to read and
    /// write the DRn registers.
    ///
    /// The #DB exception occurs before executing the instruction, and `DR6.breakpoint_register_access_detected` is set
    /// to `true` by the processor.
    ///
    /// Software debuggers can use this bit to prevent the currently-executing program from interfering with the debug
    /// operation.
    general_detect: bool,

    _reserved14_15: u2,

    /// Control the breakpoint conditions used by the DR0 register.
    type_breakpoint_0: BreakpointType,
    length_breakpoint_0: Length,

    /// Control the breakpoint conditions used by the DR1 register.
    type_breakpoint_1: BreakpointType,
    length_breakpoint_1: Length,

    /// Control the breakpoint conditions used by the DR2 register.
    type_breakpoint_2: BreakpointType,
    length_breakpoint_2: Length,

    /// Control the breakpoint conditions used by the DR3 register.
    type_breakpoint_3: BreakpointType,
    length_breakpoint_3: Length,

    _reserved_32_63: u32,

    pub const BreakpointType = enum(u2) {
        /// Only on instruction execution.
        ///
        /// The `length` field for the register using this type must be set to `.byte`.
        /// Setting to any other value produces undefined results.
        instruction_execution = 0b00,

        /// Only on data write.
        data_write = 0b01,

        /// Effect depends on the value of `CR4[DE]` as follows:
        /// - `CR4[DE] = 0` - Condition is undefined.
        /// - `CR4[DE] = 1` - Only on I/O read or I/O write.
        io_read_write = 0b10,

        /// Only on data read or data write.
        read_write = 0b11,
    };

    pub const Length = enum(u2) {
        /// 1 byte.
        byte = 0b00,

        /// 2 bytes, address must be 2 byte aligned.
        word = 0b01,

        /// 4 bytes, address must be 4 byte aligned.
        dword = 0b10,

        /// 8 bytes, address must be 8 byte aligned.
        qword = 0b11,
    };

    pub fn read() DR7 {
        return @bitCast(asm ("mov %%dr7, %[value]"
            : [value] "=r" (-> u64),
        ));
    }

    pub fn write(dr7: DR7) void {
        asm volatile ("mov %[value], %%dr7"
            :
            : [value] "r" (@as(u64, @bitCast(dr7))),
        );
    }
};

/// Processors based on Nehalem microarchitecture provide an auxiliary TSC register, IA32_TSC_AUX that is designed to
/// be used in conjunction with IA32_TSC.
///
/// IA32_TSC_AUX provides a 32-bit field that is initialized by privileged software with a signature value
/// (for example, a logical processor ID).
///
/// The primary usage of IA32_TSC_AUX in conjunction with IA32_TSC is to allow software to read the 64-bit time stamp in
/// IA32_TSC and signature value in IA32_TSC_AUX with the instruction RDTSCP in an atomic operation.
///
/// RDTSCP returns the 64-bit time stamp in EDX:EAX and the 32-bit TSC_AUX signature value in ECX.
///
/// The atomicity of RDTSCP ensures that no context switch can occur between the reads of the TSC and TSC_AUX values.
pub const IA32_TSC_AUX = MSR(u64, 0xC0000103);

pub const KERNEL_GS_BASE = MSR(u64, 0xC0000102);

pub inline fn readMSR(comptime T: type, register: u32) T {
    switch (T) {
        u64 => {
            var low: u32 = undefined;
            var high: u32 = undefined;
            asm ("rdmsr"
                : [low] "={eax}" (low),
                  [high] "={edx}" (high),
                : [register] "{ecx}" (register),
            );
            return (@as(u64, high) << 32) | @as(u64, low);
        },
        u32 => {
            return asm ("rdmsr"
                : [low] "={eax}" (-> u32),
                : [register] "{ecx}" (register),
                : .{ .edx = true });
        },
        else => @compileError("read not implemented for " ++ @typeName(T)),
    }
}

pub inline fn writeMSR(comptime T: type, register: u32, value: T) void {
    switch (T) {
        u64 => {
            asm volatile ("wrmsr"
                :
                : [reg] "{ecx}" (register),
                  [low] "{eax}" (@as(u32, @truncate(value))),
                  [high] "{edx}" (@as(u32, @truncate(value >> 32))),
            );
        },
        u32 => {
            asm volatile ("wrmsr"
                :
                : [reg] "{ecx}" (register),
                  [low] "{eax}" (value),
                  [high] "{edx}" (@as(u32, 0)),
            );
        },
        else => @compileError("write not implemented for " ++ @typeName(T)),
    }
}

pub fn MSR(comptime T: type, comptime register: u32) type {
    return struct {
        pub inline fn read() T {
            return readMSR(T, register);
        }

        pub inline fn write(value: T) void {
            writeMSR(T, register, value);
        }
    };
}

fn DebugAddressRegister(comptime register: enum { DR0, DR1, DR2, DR3 }) type {
    return struct {
        pub fn read() core.VirtualAddress {
            return switch (register) {
                .DR0 => .fromInt(asm ("mov %%dr0, %[value]"
                    : [value] "=r" (-> u64),
                )),
                .DR1 => .fromInt(asm ("mov %%dr1, %[value]"
                    : [value] "=r" (-> u64),
                )),
                .DR2 => .fromInt(asm ("mov %%dr2, %[value]"
                    : [value] "=r" (-> u64),
                )),
                .DR3 => .fromInt(asm ("mov %%dr3, %[value]"
                    : [value] "=r" (-> u64),
                )),
            };
        }

        pub fn write(address: core.VirtualAddress) void {
            switch (register) {
                .DR0 => asm volatile ("mov %[address], %%dr0"
                    :
                    : [address] "r" (address.value),
                ),
                .DR1 => asm volatile ("mov %[address], %%dr1"
                    :
                    : [address] "r" (address.value),
                ),
                .DR2 => asm volatile ("mov %[address], %%dr2"
                    :
                    : [address] "r" (address.value),
                ),
                .DR3 => asm volatile ("mov %[address], %%dr3"
                    :
                    : [address] "r" (address.value),
                ),
            }
        }
    };
}
