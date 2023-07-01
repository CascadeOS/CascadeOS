// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const x86_64 = @import("x86_64.zig");

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

    /// Set by hardware to indicate that the sign bit of the result of the last signed integer
    /// operation differs from the source operands.
    overflow: bool,

    /// Specifies the privilege level required for executing I/O address-space instructions.
    iopl: u2,

    /// Used by `iret` in hardware task switch mode to determine if current task is nested.
    nested: bool,

    _reserved4: u1,

    /// Allows to restart an instruction following an instrucion breakpoint.
    @"resume": bool,

    /// Enable the virtual-8086 mode.
    virtual_8086: bool,

    /// Enable automatic alignment checking if CR0.AM is set. Only works if CPL is 3.
    alignment_check: bool,

    /// Virtual image of the INTERRUPT_FLAG bit.
    ///
    /// Used when virtual-8086 mode extensions (CR4.VME) or protected-mode virtual
    /// interrupts (CR4.PVI) are activated.
    virtual_interrupt: bool,

    /// Indicates that an external, maskable interrupt is pending.
    ///
    /// Used when virtual-8086 mode extensions (CR4.VME) or protected-mode virtual
    /// interrupts (CR4.PVI) are activated.
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
    /// Note: does not protect reserved bits, that is left up to the caller
    pub inline fn write(self: RFlags) void {
        asm volatile ("pushq %[val]; popfq"
            :
            : [val] "r" (@as(u64, @bitCast(self))),
            : "flags"
        );
    }

    pub const format = core.formatStructIgnoreReserved;

    comptime {
        core.testing.expectSize(@This(), @sizeOf(u64));
    }
};

pub const Cr0 = packed struct(u64) {
    // TODO: Add field level documentation

    protected_mode_enable: bool,

    monitor_coprocessor: bool,

    emulate_coprocessor: bool,

    task_switched: bool,

    extension_type: bool,

    numeric_error: bool,

    _reserved6_15: u10,

    write_protect: bool,

    _reserved17: u1,

    alignment_mask: bool,

    _reserved19_28: u10,

    not_write_through: bool,

    cache_disable: bool,

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

    pub const format = core.formatStructIgnoreReserved;
};

pub const Cr3 = struct {
    /// Reads the CR3 register and returns the page table address.
    pub inline fn readAddress() kernel.PhysicalAddress {
        return kernel.PhysicalAddress.fromInt(asm ("mov %%cr3, %[value]"
            : [value] "=r" (-> u64),
        ) & 0xFFFF_FFFF_FFFF_F000);
    }

    /// Writes the CR3 register with the given page table address.
    pub inline fn writeAddress(address: kernel.PhysicalAddress) void {
        asm volatile ("mov %[address], %%cr3"
            :
            : [address] "r" (address.value & 0xFFFF_FFFF_FFFF_F000),
            : "memory"
        );
    }
};

/// Extended Feature Enable Register (EFER)
pub const EFER = packed struct(u64) {
    // TODO: Add field level documentation

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
        msr.write(@as(u64, @bitCast(self)));
    }

    const msr = MSR(u64, 0xC0000080);

    pub const format = core.formatStructIgnoreReserved;
};

pub fn MSR(comptime T: type, comptime register: u32) type {
    return struct {
        pub inline fn read() T {
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

        pub inline fn write(value: T) void {
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
    };
}
