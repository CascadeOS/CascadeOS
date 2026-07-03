// SPDX-License-Identifier: BSD-3-Clause
// SPDX-FileCopyrightText: CascadeOS Contributors

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const core = @import("core");

const x64 = @import("x64.zig");

const Thread = @This();

extended_state: ExtendedState,

pub inline fn from(thread: *cascade.user.Thread) *Thread {
    return &thread.arch_specific.arch_specific;
}

/// Create the arch specific data of a thread.
///
/// Non-architecture specific creation has already been performed but no initialization.
///
/// This function is called in the `cascade.user.Thread` cache constructor.
pub fn create(thread: *cascade.user.Thread) cascade.mem.cache.ConstructorError!void {
    const x64_thread: *Thread = .from(thread);
    x64_thread.* = .{
        .extended_state = .{
            .xsave_area = @alignCast(
                globals.xsave_area_cache.allocate() catch return error.ItemConstructionFailed,
            ),
        },
    };
}

/// Destroy the arch specific data of a thread.
///
/// Non-architecture specific destruction has not already been performed.
///
/// This function is called in the `cascade.user.Thread` cache destructor.
pub fn destroy(thread: *cascade.user.Thread) void {
    const x64_thread: *Thread = from(thread);
    globals.xsave_area_cache.deallocate(x64_thread.extended_state.xsave_area);
}

/// Initialize the arch specific data of a thread.
///
/// All non-architecture specific initialization has already been performed.
///
/// This function is called in `cascade.user.Thread.internal.create`.
pub fn initialize(thread: *cascade.user.Thread) void {
    const x64_thread: *Thread = from(thread);
    x64_thread.extended_state.zero();
}

pub const current = struct {
    /// Enter userspace for the first time in the current thread.
    ///
    /// Asserts that the current task is a user task.
    ///
    /// ***Caller Requirements***:
    ///  - This function must be called only once per thread.
    pub fn enterUserspace(options: arch.Thread.current.EnterUserspaceOptions) noreturn {
        const x64_thread: *x64.Thread = .from(.from(cascade.Task.Current.get().task));
        if (core.is_debug) std.debug.assert(x64_thread.extended_state.state == .memory);

        const frame: EnterUserspaceFrame = .{
            .rip = options.entry_point,
            .rsp = options.stack_pointer,
        };

        x64.Executor.current.disableInterrupts();
        x64.Executor.current.enableSSEUsage();
        x64_thread.extended_state.load();

        asm volatile (
            \\.cfi_sections .debug_frame
            \\
            \\mov %[frame], %rsp
            \\.cfi_undefined rip
            \\
            \\xor %ebp, %ebp
            \\xor %eax, %eax
            \\xor %ebx, %ebx
            \\xor %ecx, %ecx
            \\xor %edx, %edx
            \\xor %esi, %esi
            \\xor %edi, %edi
            \\xor %r8, %r8
            \\xor %r9, %r9
            \\xor %r10, %r10
            \\xor %r11, %r11
            \\xor %r12, %r12
            \\xor %r13, %r13
            \\xor %r14, %r14
            \\xor %r15, %r15
            \\swapgs
            \\iretq
            :
            : [frame] "r" (&frame),
        );
        unreachable;
    }

    const EnterUserspaceFrame = extern struct {
        rip: cascade.UserVirtualAddress,
        cs: extern union {
            full: u64,
            selector: x64.Gdt.Selector,
        } = .{ .selector = .user_code },
        rflags: x64.registers.RFlags = user_rflags,
        rsp: cascade.UserVirtualAddress,
        ss: extern union {
            full: u64,
            selector: x64.Gdt.Selector,
        } = .{ .selector = .user_data },

        const user_rflags: x64.registers.RFlags = .{
            .carry = false,
            ._reserved1 = 0,
            .parity = false,
            ._reserved2 = 0,
            .auxiliary_carry = false,
            ._reserved3 = 0,
            .zero = false,
            .sign = false,
            .trap = false,
            .enable_interrupts = true,
            .direction = .up,
            .overflow = false,
            .iopl = .ring0,
            .nested = false,
            ._reserved4 = 0,
            .@"resume" = false,
            .virtual_8086 = false,
            .alignment_check = false,
            .virtual_interrupt = false,
            .virtual_interrupt_pending = false,
            .id = false,
            ._reserved5 = 0,
        };
    };
};

const ExtendedState = struct {
    fs_base: u64 = undefined,
    gs_base: u64 = undefined,
    xsave_area: []align(64) u8,

    /// Where is the extended state currently stored
    state: State = .memory,

    pub const State = enum {
        registers,
        memory,
    };

    fn zero(extended_state: *ExtendedState) void {
        extended_state.* = .{
            .fs_base = 0,
            .gs_base = 0,
            .xsave_area = extended_state.xsave_area,
            .state = .memory,
        };

        @memset(extended_state.xsave_area, 0);
    }

    /// Save the extended state into memory if it is currently stored in the registers.
    ///
    /// Caller must ensure SSE is enabled before calling; see `x64.instructions.enableSSEUsage`
    pub fn save(extended_state: *ExtendedState) void {
        switch (extended_state.state) {
            .memory => {},
            .registers => {
                if (x64.info.cpu_id.fsgsbase) {
                    @branchHint(.likely); // modern machines support fsgsbase
                    extended_state.fs_base = asm ("rdfsbase %[fs]"
                        : [fs] "=r" (-> u64),
                    );
                } else {
                    extended_state.fs_base = x64.registers.FS_BASE.read();
                }

                extended_state.gs_base = x64.registers.KERNEL_GS_BASE.read();

                const raw_xcr0_value: u64 = @bitCast(x64.info.xsave.xcr0_value);

                switch (x64.info.xsave.method) {
                    .xsaveopt => {
                        @branchHint(.likely); // modern machines support xsaveopt
                        asm volatile ("xsaveopt64 %[xsave_area]"
                            :
                            : [xsave_area] "*p" (extended_state.xsave_area.ptr),
                              [hi] "{edx}" (@as(u32, @truncate(raw_xcr0_value >> 32))),
                              [lo] "{eax}" (@as(u32, @truncate(raw_xcr0_value))),
                            : .{ .memory = true });
                    },
                    .xsave => asm volatile ("xsave64 %[xsave_area]"
                        :
                        : [xsave_area] "*p" (extended_state.xsave_area.ptr),
                          [hi] "{edx}" (@as(u32, @truncate(raw_xcr0_value >> 32))),
                          [lo] "{eax}" (@as(u32, @truncate(raw_xcr0_value))),
                        : .{ .memory = true }),
                }

                extended_state.state = .memory;
            },
        }
    }

    /// Load the extended state into registers if it is currently stored in memory.
    ///
    /// Caller must ensure SSE is enabled before calling; see `x64.instructions.enableSSEUsage`
    pub fn load(extended_state: *ExtendedState) void {
        switch (extended_state.state) {
            .memory => {
                if (x64.info.cpu_id.fsgsbase) {
                    @branchHint(.likely); // modern machines support fsgsbase

                    asm volatile ("wrfsbase %[fs]"
                        :
                        : [fs] "r" (extended_state.fs_base),
                    );
                } else {
                    x64.registers.FS_BASE.write(extended_state.fs_base);
                }

                x64.registers.KERNEL_GS_BASE.write(extended_state.gs_base);

                const raw_xcr0_value: u64 = @bitCast(x64.info.xsave.xcr0_value);

                asm volatile ("xrstor64 %[xsave_area]"
                    :
                    : [xsave_area] "*p" (extended_state.xsave_area.ptr),
                      [hi] "{edx}" (@as(u32, @truncate(raw_xcr0_value >> 32))),
                      [lo] "{eax}" (@as(u32, @truncate(raw_xcr0_value))),
                );

                extended_state.state = .registers;
            },
            .registers => {},
        }
    }
};

const globals = struct {
    /// Initialized during `init.initialize`.
    var xsave_area_cache: cascade.mem.cache.RawCache = undefined;
};

pub const init = struct {
    const init_log = cascade.debug.log.scoped(.thread_init);

    /// Perform any per-achitecture initialization needed for userspace threads.
    pub fn initialize() !void {
        init_log.debug("initializing xsave area cache", .{});
        globals.xsave_area_cache.init(.{
            .name = try .fromSlice("xsave"),
            .size = x64.info.xsave.xsave_area_size,
            .alignment = .fromByteUnits(64),
        });
    }
};
