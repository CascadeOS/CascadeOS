// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

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
    interrupt: bool,

    /// Determines the order in which strings are processed.
    direction: bool,

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

    /// Returns the current value of the RFLAGS register.
    pub inline fn read() RFlags {
        return @bitCast(asm ("pushfq; popq %[ret]"
            : [ret] "=r" (-> u64),
        ));
    }

    /// Writes the RFLAGS register.
    ///
    /// Note: does not protect reserved bits, that is left up to the caller
    pub inline fn write(self: RFlags) void {
        asm volatile ("pushq %[val]; popfq"
            :
            : [val] "r" (@as(u64, @bitCast(self))),
            : "flags"
        );
    }

    pub fn print(self: RFlags, writer: std.io.AnyWriter, indent: usize) !void {
        const new_indent = indent + 2;

        try writer.writeAll("RFlags{\n");

        try writer.writeByteNTimes(' ', new_indent);
        try writer.print("carry: {},\n", .{self.carry});

        try writer.writeByteNTimes(' ', new_indent);
        try writer.print("parity: {},\n", .{self.parity});

        try writer.writeByteNTimes(' ', new_indent);
        try writer.print("auxiliary_carry: {},\n", .{self.auxiliary_carry});

        try writer.writeByteNTimes(' ', new_indent);
        try writer.print("zero: {},\n", .{self.zero});

        try writer.writeByteNTimes(' ', new_indent);
        try writer.print("sign: {},\n", .{self.sign});

        try writer.writeByteNTimes(' ', new_indent);
        try writer.print("trap: {},\n", .{self.trap});

        try writer.writeByteNTimes(' ', new_indent);
        try writer.print("interrupt: {},\n", .{self.interrupt});

        try writer.writeByteNTimes(' ', new_indent);
        try writer.print("direction: {},\n", .{self.direction});

        try writer.writeByteNTimes(' ', new_indent);
        try writer.print("overflow: {},\n", .{self.overflow});

        try writer.writeByteNTimes(' ', new_indent);
        try writer.print("iopl: {s},\n", .{@tagName(self.iopl)});

        try writer.writeByteNTimes(' ', new_indent);
        try writer.print("nested: {},\n", .{self.nested});

        try writer.writeByteNTimes(' ', new_indent);
        try writer.print("resume: {},\n", .{self.@"resume"});

        try writer.writeByteNTimes(' ', new_indent);
        try writer.print("virtual_8086: {},\n", .{self.virtual_8086});

        try writer.writeByteNTimes(' ', new_indent);
        try writer.print("alignment_check: {},\n", .{self.alignment_check});

        try writer.writeByteNTimes(' ', new_indent);
        try writer.print("virtual_interrupt: {},\n", .{self.virtual_interrupt});

        try writer.writeByteNTimes(' ', new_indent);
        try writer.print("virtual_interrupt_pending: {},\n", .{self.virtual_interrupt_pending});

        try writer.writeByteNTimes(' ', new_indent);
        try writer.print("id: {},\n", .{self.id});

        try writer.writeByteNTimes(' ', indent);
        try writer.writeAll("}");
    }

    pub inline fn format(
        self: RFlags,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        _ = fmt;
        return if (@TypeOf(writer) == std.io.AnyWriter)
            print(self, writer, 0)
        else
            print(self, writer.any(), 0);
    }

    fn __helpZls() void {
        RFlags.print(undefined, @as(std.fs.File.Writer, undefined), 0);
    }

    comptime {
        core.testing.expectSize(@This(), @sizeOf(u64));
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

    pub fn write(self: Cr0) void {
        asm volatile ("mov %[value], %%cr0"
            :
            : [value] "r" (@as(u64, @bitCast(self))),
        );
    }
};

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
            : "memory"
        );
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

    pub inline fn write(self: EFER) void {
        msr.write(@bitCast(self));
    }

    const msr = MSR(u64, 0xC0000080);
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
            asm volatile ("rdmsr"
                : [low] "={eax}" (low),
                  [high] "={edx}" (high),
                : [register] "{ecx}" (register),
            );
            return (@as(u64, high) << 32) | @as(u64, low);
        },
        u32 => {
            return asm volatile ("rdmsr"
                : [low] "={eax}" (-> u32),
                : [register] "{ecx}" (register),
                : "edx"
            );
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

comptime {
    std.testing.refAllDeclsRecursive(@This());
}

const core = @import("core");
const std = @import("std");

const x64 = @import("x64");
