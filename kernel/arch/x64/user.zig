// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const cascade = @import("cascade");
const arch = @import("arch");
const kernel = @import("kernel");
const Task = kernel.Task;
const Process = kernel.user.Process;
const Thread = kernel.user.Thread;
const core = @import("core");

const log = kernel.debug.log.scoped(.user_x64);

const x64 = @import("x64.zig");

pub const PerThread = struct {
    extended_state: ExtendedState,

    /// Create the `PerThread` data of a thread.
    ///
    /// Non-architecture specific creation has already been performed but no initialization.
    ///
    /// This function is called in the `Thread` cache constructor.
    pub fn createThread(thread: *Thread) kernel.mem.cache.ConstructorError!void {
        const per_thread: *x64.user.PerThread = .from(thread);

        per_thread.* = .{
            .extended_state = .{
                .xsave_area = @alignCast(
                    globals.xsave_area_cache.allocate() catch return error.ItemConstructionFailed,
                ),
            },
        };
    }

    /// Destroy the `PerThread` data of a thread.
    ///
    /// Non-architecture specific destruction has not already been performed.
    ///
    /// This function is called in the `Thread` cache destructor.
    pub fn destroyThread(thread: *Thread) void {
        const per_thread: *x64.user.PerThread = .from(thread);

        globals.xsave_area_cache.deallocate(per_thread.extended_state.xsave_area);
    }

    /// Initialize the `PerThread` data of a thread.
    ///
    /// All non-architecture specific initialization has already been performed.
    ///
    /// This function is called in `Thread.internal.create`.
    pub fn initializeThread(thread: *Thread) void {
        const per_thread: *x64.user.PerThread = .from(thread);
        per_thread.extended_state.zero();
    }

    pub fn from(thread: *Thread) *PerThread {
        return &thread.arch_specific;
    }

    pub const ExtendedState = struct {
        fs_base: usize = undefined,
        gs_base: usize = undefined,
        xsave_area: []align(64) u8,

        /// Where is the extended state currently stored
        state: State = .memory,

        pub const State = enum {
            registers,
            memory,
        };

        fn zero(extended_state: *ExtendedState) void {
            extended_state.fs_base = 0;
            extended_state.gs_base = 0;
            @memset(extended_state.xsave_area, 0);
            extended_state.state = .memory;
        }

        /// Save the extended state into memory if it is currently stored in the registers.
        ///
        /// Caller must ensure SSE is enabled before calling; see `x64.instructions.enableSSEUsage`
        pub fn save(extended_state: *ExtendedState) void {
            switch (extended_state.state) {
                .memory => {},
                .registers => {
                    extended_state.fs_base = x64.registers.FS_BASE.read();
                    extended_state.gs_base = x64.registers.KERNEL_GS_BASE.read();
                    switch (x64.info.xsave.method) {
                        .xsaveopt => {
                            @branchHint(.likely); // modern machines support xsaveopt
                            x64.instructions.xsaveopt(
                                extended_state.xsave_area,
                                x64.info.xsave.xcr0_value,
                            );
                        },
                        .xsave => x64.instructions.xsave(
                            extended_state.xsave_area,
                            x64.info.xsave.xcr0_value,
                        ),
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
                    x64.registers.FS_BASE.write(extended_state.fs_base);
                    x64.registers.KERNEL_GS_BASE.write(extended_state.gs_base);
                    x64.instructions.xrstor(
                        extended_state.xsave_area,
                        x64.info.xsave.xcr0_value,
                    );
                    extended_state.state = .registers;
                },
                .registers => {},
            }
        }
    };
};

/// Enter userspace for the first time in the current task.
pub fn enterUserspace(options: arch.user.EnterUserspaceOptions) noreturn {
    const per_thread: *x64.user.PerThread = .from(.from(Task.Current.get().task));
    if (core.is_debug) std.debug.assert(per_thread.extended_state.state == .memory);

    const frame: EnterUserspaceFrame = .{
        .rip = options.entry_point,
        .rsp = options.stack_pointer,
    };

    x64.instructions.disableInterrupts();

    x64.instructions.enableSSEUsage();
    per_thread.extended_state.load();

    asm volatile (
        \\mov %[frame], %rsp
        \\xor %eax, %eax
        \\xor %ebx, %ebx
        \\xor %ecx, %ecx
        \\xor %edx, %edx
        \\xor %esi, %esi
        \\xor %edi, %edi
        \\xor %ebp, %ebp
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
    rip: core.VirtualAddress,
    cs: extern union {
        full: u64,
        selector: x64.Gdt.Selector,
    } = .{ .selector = .user_code },
    rflags: x64.registers.RFlags = user_rflags,
    rsp: core.VirtualAddress,
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

pub const SyscallFrame = extern struct {
    /// arg11
    r15: u64,
    /// arg10
    r14: u64,
    /// arg9
    r13: u64,
    /// arg8
    r12: u64,
    /// arg7
    r10: u64,
    /// arg5
    r9: u64,
    /// arg4
    r8: u64,
    /// syscall number
    rdi: u64,
    /// arg1
    rsi: u64,
    /// arg12
    rbp: u64,
    /// arg2
    rdx: u64,
    /// arg6
    rbx: u64,
    /// arg3
    rax: u64,

    /// r11
    rflags: x64.registers.RFlags,
    /// rcx
    rip: u64,
    rsp: u64,

    pub inline fn from(syscall_frame: arch.user.SyscallFrame) *SyscallFrame {
        return &syscall_frame.arch_specific;
    }

    pub inline fn syscall(syscall_frame: *const SyscallFrame) ?cascade.Syscall {
        return std.enums.fromInt(cascade.Syscall, syscall_frame.rdi);
    }

    pub inline fn arg(syscall_frame: *const SyscallFrame, comptime argument: arch.user.SyscallFrame.Arg) usize {
        return switch (argument) {
            .one => syscall_frame.rsi,
            .two => syscall_frame.rdx,
            .three => syscall_frame.rax,
            .four => syscall_frame.r8,
            .five => syscall_frame.r9,
            .six => syscall_frame.rbx,
            .seven => syscall_frame.r10,
            .eight => syscall_frame.r12,
            .nine => syscall_frame.r13,
            .ten => syscall_frame.r14,
            .eleven => syscall_frame.r15,
            .twelve => syscall_frame.rbp,
        };
    }

    pub fn print(
        value: *const SyscallFrame,
        writer: *std.Io.Writer,
        indent: usize,
    ) !void {
        const new_indent = indent + 2;

        try writer.writeAll("SyscallFrame{\n");

        try writer.splatByteAll(' ', new_indent);
        if (value.syscall()) |s|
            try writer.print("syscall: {t},\n", .{s})
        else
            try writer.print("invalid syscall: {d},\n", .{value.rdi});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("arg1:  0x{x:0>16}, arg2:  0x{x:0>16},\n", .{ value.arg(.one), value.arg(.two) });

        try writer.splatByteAll(' ', new_indent);
        try writer.print("arg3:  0x{x:0>16}, arg4:  0x{x:0>16},\n", .{ value.arg(.three), value.arg(.four) });

        try writer.splatByteAll(' ', new_indent);
        try writer.print("arg5:  0x{x:0>16}, arg6:  0x{x:0>16},\n", .{ value.arg(.five), value.arg(.six) });

        try writer.splatByteAll(' ', new_indent);
        try writer.print("arg7:  0x{x:0>16}, arg8:  0x{x:0>16},\n", .{ value.arg(.seven), value.arg(.eight) });

        try writer.splatByteAll(' ', new_indent);
        try writer.print("arg9:  0x{x:0>16}, arg10: 0x{x:0>16},\n", .{ value.arg(.nine), value.arg(.ten) });

        try writer.splatByteAll(' ', new_indent);
        try writer.print("arg11: 0x{x:0>16}, arg12: 0x{x:0>16},\n", .{ value.arg(.eleven), value.arg(.twelve) });

        try writer.splatByteAll(' ', new_indent);
        try writer.print("rsp:   0x{x:0>16}, rip:   0x{x:0>16},\n", .{ value.rsp, value.rip });

        try writer.splatByteAll(' ', new_indent);
        try writer.writeAll("rflags: ");
        try value.rflags.print(writer, new_indent);
        try writer.writeAll(",\n");

        try writer.splatByteAll(' ', indent);
        try writer.writeByte('}');
    }

    pub inline fn format(
        value: *const SyscallFrame,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        return print(value, writer, 0);
    }
};

export fn syscallDispatch(syscall_frame: *SyscallFrame) callconv(.c) void {
    x64.instructions.disableSSEUsage();
    defer {
        const per_thread: *x64.user.PerThread = .from(.from(Task.Current.get().task));
        x64.instructions.enableSSEUsage();
        per_thread.extended_state.load();
    }

    kernel.user.onSyscall(.{ .arch_specific = syscall_frame });

    x64.instructions.disableInterrupts();
}

pub fn syscallEntry() callconv(.naked) noreturn {
    asm volatile (std.fmt.comptimePrint(
            \\swapgs
            \\
            \\mov %rsp, %gs:{[user_rsp_scratch_offset]}      // save the user rsp
            \\mov %gs:{[kernel_stack_pointer_offset]}, %rsp  // load the kernel rsp
            \\
            \\sub $8, %rsp                                   // reserve space for the user rsp
            \\push %rcx                                      // user rip
            \\push %r11                                      // user rflags
            \\
            \\mov %gs:{[user_rsp_scratch_offset]}, %r11
            \\mov %r11, 16(%rsp)                             // store the user rsp in reserved space
            \\
            \\push %rax
            \\push %rbx
            \\push %rdx
            \\push %rbp
            \\push %rsi
            \\push %rdi
            \\push %r8
            \\push %r9
            \\push %r10
            \\push %r12
            \\push %r13
            \\push %r14
            \\push %r15
            \\
            \\cld
            \\xor %ebp, %ebp
            \\mov %rsp, %rdi
            \\call syscallDispatch
            \\
            \\pop %r15
            \\pop %r14
            \\pop %r13
            \\pop %r12
            \\pop %r10
            \\pop %r9
            \\pop %r8
            \\pop %rdi
            \\pop %rsi
            \\pop %rbp
            \\pop %rdx
            \\pop %rbx
            \\pop %rax
            \\
            \\pop %r11 // user rflags
            \\pop %rcx // user rip
            \\pop %rsp // user rsp
            \\
            \\swapgs
            \\sysretq
        , .{
            .user_rsp_scratch_offset = @offsetOf(kernel.Task, "arch_specific") + @offsetOf(x64.PerTask, "user_rsp_scratch"),
            .kernel_stack_pointer_offset = @offsetOf(Task, "stack") + @offsetOf(Task.Stack, "top_stack_pointer"),
        }));
}

const globals = struct {
    /// Initialized during `init.initialize`.
    var xsave_area_cache: kernel.mem.cache.RawCache = undefined;
};

pub const init = struct {
    const init_log = kernel.debug.log.scoped(.thread_init);

    /// Perform any per-achitecture initialization needed for userspace processes/threads.
    pub fn initialize() !void {
        init_log.debug("initializing xsave area cache", .{});
        globals.xsave_area_cache.init(.{
            .name = try .fromSlice("xsave"),
            .size = x64.info.xsave.xsave_area_size.value,
            .alignment = .fromByteUnits(64),
        });
    }
};
