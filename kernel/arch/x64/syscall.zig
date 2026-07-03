// SPDX-License-Identifier: BSD-3-Clause
// SPDX-FileCopyrightText: CascadeOS Contributors

const cascade = @import("cascade");
const arch = @import("arch");
const user_cascade = @import("user_cascade");

const std = @import("std");

const x64 = @import("x64.zig");

export fn syscallDispatch(frame: *Frame) callconv(.c) void {
    errdefer comptime unreachable;

    x64.Executor.current.disableSSEUsage();

    const current_task: cascade.Task.Current = .get();
    current_task.task.interrupt_disable_count.store(1, .monotonic);

    frame.setReturnValue(
        cascade.user.onSyscall(
            current_task,
            .{ .arch_specific = frame },
        ),
    );

    x64.Executor.current.disableInterrupts();
    current_task.task.interrupt_disable_count.store(0, .monotonic);

    const x64_thread: *x64.Thread = .from(.from(current_task.task));
    x64.Executor.current.enableSSEUsage();
    x64_thread.extended_state.load();
}

pub fn entry() callconv(.naked) noreturn {
    asm volatile (std.fmt.comptimePrint(
            \\.cfi_sections .debug_frame
            \\
            \\.cfi_undefined %rip
            \\.cfi_undefined %rsp
            \\
            \\swapgs
            \\
            \\mov %rsp, %gs:{[user_rsp_scratch_offset]}      // save the user rsp
            \\mov %gs:{[kernel_stack_pointer_offset]}, %rsp  // load the kernel rsp
            \\.cfi_def_cfa %rsp, 0
            \\
            \\sub $8, %rsp                                   // reserve space for the user rsp
            \\.cfi_adjust_cfa_offset 8
            \\push %rcx                                      // user rip
            \\.cfi_adjust_cfa_offset 8
            \\push %r11                                      // user rflags
            \\.cfi_adjust_cfa_offset 8
            \\
            \\mov %gs:{[user_rsp_scratch_offset]}, %r11
            \\mov %r11, 16(%rsp)                             // store the user rsp in reserved space
            \\
            \\push %rax
            \\.cfi_adjust_cfa_offset 8
            \\push %rbx
            \\.cfi_adjust_cfa_offset 8
            \\push %rdx
            \\.cfi_adjust_cfa_offset 8
            \\push %rbp
            \\.cfi_adjust_cfa_offset 8
            \\push %rsi
            \\.cfi_adjust_cfa_offset 8
            \\push %rdi
            \\.cfi_adjust_cfa_offset 8
            \\push %r8
            \\.cfi_adjust_cfa_offset 8
            \\push %r9
            \\.cfi_adjust_cfa_offset 8
            \\push %r10
            \\.cfi_adjust_cfa_offset 8
            \\push %r12
            \\.cfi_adjust_cfa_offset 8
            \\push %r13
            \\.cfi_adjust_cfa_offset 8
            \\push %r14
            \\.cfi_adjust_cfa_offset 8
            \\push %r15
            \\.cfi_adjust_cfa_offset 8
            \\
            \\xor %ebp, %ebp
            \\mov %rsp, %rdi
            \\call syscallDispatch
            \\
            \\pop %r15
            \\.cfi_adjust_cfa_offset -8
            \\pop %r14
            \\.cfi_adjust_cfa_offset -8
            \\pop %r13
            \\.cfi_adjust_cfa_offset -8
            \\pop %r12
            \\.cfi_adjust_cfa_offset -8
            \\pop %r10
            \\.cfi_adjust_cfa_offset -8
            \\pop %r9
            \\.cfi_adjust_cfa_offset -8
            \\pop %r8
            \\.cfi_adjust_cfa_offset -8
            \\pop %rdi
            \\.cfi_adjust_cfa_offset -8
            \\pop %rsi
            \\.cfi_adjust_cfa_offset -8
            \\pop %rbp
            \\.cfi_adjust_cfa_offset -8
            \\pop %rdx
            \\.cfi_adjust_cfa_offset -8
            \\pop %rbx
            \\.cfi_adjust_cfa_offset -8
            \\pop %rax
            \\.cfi_adjust_cfa_offset -8
            \\
            \\pop %r11 // user rflags
            \\.cfi_adjust_cfa_offset -8
            \\pop %rcx // user rip
            \\.cfi_adjust_cfa_offset -8
            \\pop %rsp // user rsp
            \\.cfi_undefined %rsp
            \\
            \\swapgs
            \\sysretq
        , .{
            .user_rsp_scratch_offset = @offsetOf(cascade.Task, "arch_specific") + @offsetOf(x64.Task, "user_rsp_scratch"),
            .kernel_stack_pointer_offset = @offsetOf(cascade.Task, "stack") + @offsetOf(cascade.Task.Stack, "top_stack_pointer"),
        }));
}

pub const Frame = extern struct {
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rdi: u64,
    rsi: u64,
    rbp: u64,
    rdx: u64,
    rbx: u64,
    rax: u64,

    /// r11
    rflags: x64.registers.RFlags,
    /// rcx
    rip: cascade.VirtualAddress,
    rsp: cascade.VirtualAddress,

    /// Get the syscall this frame represents.
    pub fn syscall(frame: *const Frame) ?user_cascade.Syscall {
        return std.enums.fromInt(user_cascade.Syscall, frame.rax);
    }

    /// Get an argument from this frame.
    pub fn arg(frame: *const Frame, comptime argument: arch.SyscallFrame.Arg) u64 {
        return switch (argument) {
            .one => frame.rdi,
            .two => frame.rsi,
            .three => frame.rdx,
            .four => frame.rbx,
            .five => frame.r8,
            .six => frame.r9,
            .seven => frame.r10,
            .eight => frame.r12,
            .nine => frame.r13,
            .ten => frame.r14,
            .eleven => frame.r15,
            .twelve => frame.rbp,
        };
    }

    /// Set the return value of this syscall frame.
    pub inline fn setReturnValue(frame: *Frame, value: i64) void {
        frame.rax = @bitCast(value);
    }

    pub fn print(value: *const Frame, writer: *std.Io.Writer, indent: usize) !void {
        const new_indent = indent + 2;

        try writer.writeAll("SyscallFrame{\n");

        try writer.splatByteAll(' ', new_indent);
        if (value.syscall()) |s|
            try writer.print("syscall:   {t},\n", .{s})
        else
            try writer.print("invalid syscall:   {d},\n", .{value.rdi});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("arg1/rdi:  0x{x:0>16}, arg2/rsi:  0x{x:0>16},\n", .{ value.arg(.one), value.arg(.two) });

        try writer.splatByteAll(' ', new_indent);
        try writer.print("arg3/rdx:  0x{x:0>16}, arg4/rbx:   0x{x:0>16},\n", .{ value.arg(.three), value.arg(.four) });

        try writer.splatByteAll(' ', new_indent);
        try writer.print("arg5/r8:   0x{x:0>16}, arg6/r9:  0x{x:0>16},\n", .{ value.arg(.five), value.arg(.six) });

        try writer.splatByteAll(' ', new_indent);
        try writer.print("arg7/r10:  0x{x:0>16}, arg8/r12:  0x{x:0>16},\n", .{ value.arg(.seven), value.arg(.eight) });

        try writer.splatByteAll(' ', new_indent);
        try writer.print("arg9/r13:  0x{x:0>16}, arg10/r14: 0x{x:0>16},\n", .{ value.arg(.nine), value.arg(.ten) });

        try writer.splatByteAll(' ', new_indent);
        try writer.print("arg11/r15: 0x{x:0>16}, arg12/rbp: 0x{x:0>16},\n", .{ value.arg(.eleven), value.arg(.twelve) });

        try writer.splatByteAll(' ', new_indent);
        try writer.print("rsp:       0x{x:0>16}, rip:       0x{x:0>16},\n", .{ value.rsp.value, value.rip.value });

        try writer.splatByteAll(' ', new_indent);
        try writer.writeAll("rflags: ");
        try value.rflags.print(writer, new_indent);
        try writer.writeAll(",\n");

        try writer.splatByteAll(' ', indent);
        try writer.writeByte('}');
    }

    pub inline fn format(value: *const Frame, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return print(value, writer, 0);
    }
};
