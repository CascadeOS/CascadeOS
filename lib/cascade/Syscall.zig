// SPDX-License-Identifier: 0BSD
// SPDX-FileCopyrightText: CascadeOS Contributors

const builtin = @import("builtin");

pub const Syscall = enum(u64) {
    /// Exit the current thread.
    ///
    /// ### Arguments
    /// none
    ///
    /// ### Errors
    /// none
    ///
    /// ### Return
    /// never
    thread_exit_current = 0,

    /// Output a debug message.
    ///
    /// This is not intended to be used by normal userspace programs and instead is intended for logs from system libraries like libc.
    ///
    /// The message is assumed to be UTF-8 encoded.
    ///
    /// If the message does not end with a newline, one will be appended.
    ///
    /// No guarantees are made about the destination of the message, the implementation may choose to discard it or send it to any number of
    /// destinations.
    ///
    /// Any errors encountered while writing the message are ignored and may cause the message to be truncated.
    ///
    /// ### Arguments
    /// - `arg1`: length of the message
    /// - `arg2`: pointer to the message
    ///
    /// ### Errors
    /// none
    ///
    /// ### Return
    /// undefined
    debug_print = 1,

    pub inline fn call0(
        syscall: Syscall,
    ) i64 {
        return switch (builtin.cpu.arch) {
            .aarch64 => @panic("TODO"),
            .riscv64 => @panic("TODO"),
            .x86_64 => asm volatile ("syscall"
                : [ret] "={rax}" (-> i64),
                : [syscall] "{rax}" (syscall),
                : .{ .rcx = true, .r11 = true, .memory = true }),
            else => |t| @compileError("unsupported architecture " ++ @tagName(t)),
        };
    }

    pub inline fn call1(
        syscall: Syscall,
        arg1: u64,
    ) i64 {
        return switch (builtin.cpu.arch) {
            .aarch64 => @panic("TODO"),
            .riscv64 => @panic("TODO"),
            .x86_64 => asm volatile ("syscall"
                : [ret] "={rax}" (-> i64),
                : [syscall] "{rax}" (syscall),
                  [arg1] "{rdi}" (arg1),
                : .{ .rcx = true, .r11 = true, .memory = true }),
            else => |t| @compileError("unsupported architecture " ++ @tagName(t)),
        };
    }

    pub inline fn call2(
        syscall: Syscall,
        arg1: u64,
        arg2: u64,
    ) i64 {
        return switch (builtin.cpu.arch) {
            .aarch64 => @panic("TODO"),
            .riscv64 => @panic("TODO"),
            .x86_64 => asm volatile ("syscall"
                : [ret] "={rax}" (-> i64),
                : [syscall] "{rax}" (syscall),
                  [arg1] "{rdi}" (arg1),
                  [arg2] "{rsi}" (arg2),
                : .{ .rcx = true, .r11 = true, .memory = true }),
            else => |t| @compileError("unsupported architecture " ++ @tagName(t)),
        };
    }

    pub inline fn call3(
        syscall: Syscall,
        arg1: u64,
        arg2: u64,
        arg3: u64,
    ) i64 {
        return switch (builtin.cpu.arch) {
            .aarch64 => @panic("TODO"),
            .riscv64 => @panic("TODO"),
            .x86_64 => asm volatile ("syscall"
                : [ret] "={rax}" (-> i64),
                : [syscall] "{rax}" (syscall),
                  [arg1] "{rdi}" (arg1),
                  [arg2] "{rsi}" (arg2),
                  [arg3] "{rdx}" (arg3),
                : .{ .rcx = true, .r11 = true, .memory = true }),
            else => |t| @compileError("unsupported architecture " ++ @tagName(t)),
        };
    }

    pub inline fn call4(
        syscall: Syscall,
        arg1: u64,
        arg2: u64,
        arg3: u64,
        arg4: u64,
    ) i64 {
        return switch (builtin.cpu.arch) {
            .aarch64 => @panic("TODO"),
            .riscv64 => @panic("TODO"),
            .x86_64 => asm volatile ("syscall"
                : [ret] "={rax}" (-> i64),
                : [syscall] "{rax}" (syscall),
                  [arg1] "{rdi}" (arg1),
                  [arg2] "{rsi}" (arg2),
                  [arg3] "{rdx}" (arg3),
                  [arg4] "{rbx}" (arg4),
                : .{ .rcx = true, .r11 = true, .memory = true }),
            else => |t| @compileError("unsupported architecture " ++ @tagName(t)),
        };
    }

    pub inline fn call5(
        syscall: Syscall,
        arg1: u64,
        arg2: u64,
        arg3: u64,
        arg4: u64,
        arg5: u64,
    ) i64 {
        return switch (builtin.cpu.arch) {
            .aarch64 => @panic("TODO"),
            .riscv64 => @panic("TODO"),
            .x86_64 => asm volatile ("syscall"
                : [ret] "={rax}" (-> i64),
                : [syscall] "{rax}" (syscall),
                  [arg1] "{rdi}" (arg1),
                  [arg2] "{rsi}" (arg2),
                  [arg3] "{rdx}" (arg3),
                  [arg4] "{rbx}" (arg4),
                  [arg5] "{r8}" (arg5),
                : .{ .rcx = true, .r11 = true, .memory = true }),
            else => |t| @compileError("unsupported architecture " ++ @tagName(t)),
        };
    }

    pub inline fn call6(
        syscall: Syscall,
        arg1: u64,
        arg2: u64,
        arg3: u64,
        arg4: u64,
        arg5: u64,
        arg6: u64,
    ) i64 {
        return switch (builtin.cpu.arch) {
            .aarch64 => @panic("TODO"),
            .riscv64 => @panic("TODO"),
            .x86_64 => asm volatile ("syscall"
                : [ret] "={rax}" (-> i64),
                : [syscall] "{rax}" (syscall),
                  [arg1] "{rdi}" (arg1),
                  [arg2] "{rsi}" (arg2),
                  [arg3] "{rdx}" (arg3),
                  [arg4] "{rbx}" (arg4),
                  [arg5] "{r8}" (arg5),
                  [arg6] "{r9}" (arg6),
                : .{ .rcx = true, .r11 = true, .memory = true }),
            else => |t| @compileError("unsupported architecture " ++ @tagName(t)),
        };
    }

    pub inline fn call7(
        syscall: Syscall,
        arg1: u64,
        arg2: u64,
        arg3: u64,
        arg4: u64,
        arg5: u64,
        arg6: u64,
        arg7: u64,
    ) i64 {
        return switch (builtin.cpu.arch) {
            .aarch64 => @panic("TODO"),
            .riscv64 => @panic("TODO"),
            .x86_64 => asm volatile ("syscall"
                : [ret] "={rax}" (-> i64),
                : [syscall] "{rax}" (syscall),
                  [arg1] "{rdi}" (arg1),
                  [arg2] "{rsi}" (arg2),
                  [arg3] "{rdx}" (arg3),
                  [arg4] "{rbx}" (arg4),
                  [arg5] "{r8}" (arg5),
                  [arg6] "{r9}" (arg6),
                  [arg7] "{r10}" (arg7),
                : .{ .rcx = true, .r11 = true, .memory = true }),
            else => |t| @compileError("unsupported architecture " ++ @tagName(t)),
        };
    }

    pub inline fn call8(
        syscall: Syscall,
        arg1: u64,
        arg2: u64,
        arg3: u64,
        arg4: u64,
        arg5: u64,
        arg6: u64,
        arg7: u64,
        arg8: u64,
    ) i64 {
        return switch (builtin.cpu.arch) {
            .aarch64 => @panic("TODO"),
            .riscv64 => @panic("TODO"),
            .x86_64 => asm volatile ("syscall"
                : [ret] "={rax}" (-> i64),
                : [syscall] "{rax}" (syscall),
                  [arg1] "{rdi}" (arg1),
                  [arg2] "{rsi}" (arg2),
                  [arg3] "{rdx}" (arg3),
                  [arg4] "{rbx}" (arg4),
                  [arg5] "{r8}" (arg5),
                  [arg6] "{r9}" (arg6),
                  [arg7] "{r10}" (arg7),
                  [arg8] "{r12}" (arg8),
                : .{ .rcx = true, .r11 = true, .memory = true }),
            else => |t| @compileError("unsupported architecture " ++ @tagName(t)),
        };
    }

    pub inline fn call9(
        syscall: Syscall,
        arg1: u64,
        arg2: u64,
        arg3: u64,
        arg4: u64,
        arg5: u64,
        arg6: u64,
        arg7: u64,
        arg8: u64,
        arg9: u64,
    ) i64 {
        return switch (builtin.cpu.arch) {
            .aarch64 => @panic("TODO"),
            .riscv64 => @panic("TODO"),
            .x86_64 => asm volatile ("syscall"
                : [ret] "={rax}" (-> i64),
                : [syscall] "{rax}" (syscall),
                  [arg1] "{rdi}" (arg1),
                  [arg2] "{rsi}" (arg2),
                  [arg3] "{rdx}" (arg3),
                  [arg4] "{rbx}" (arg4),
                  [arg5] "{r8}" (arg5),
                  [arg6] "{r9}" (arg6),
                  [arg7] "{r10}" (arg7),
                  [arg8] "{r12}" (arg8),
                  [arg9] "{r13}" (arg9),
                : .{ .rcx = true, .r11 = true, .memory = true }),
            else => |t| @compileError("unsupported architecture " ++ @tagName(t)),
        };
    }

    pub inline fn call10(
        syscall: Syscall,
        arg1: u64,
        arg2: u64,
        arg3: u64,
        arg4: u64,
        arg5: u64,
        arg6: u64,
        arg7: u64,
        arg8: u64,
        arg9: u64,
        arg10: u64,
    ) i64 {
        return switch (builtin.cpu.arch) {
            .aarch64 => @panic("TODO"),
            .riscv64 => @panic("TODO"),
            .x86_64 => asm volatile ("syscall"
                : [ret] "={rax}" (-> i64),
                : [syscall] "{rax}" (syscall),
                  [arg1] "{rdi}" (arg1),
                  [arg2] "{rsi}" (arg2),
                  [arg3] "{rdx}" (arg3),
                  [arg4] "{rbx}" (arg4),
                  [arg5] "{r8}" (arg5),
                  [arg6] "{r9}" (arg6),
                  [arg7] "{r10}" (arg7),
                  [arg8] "{r12}" (arg8),
                  [arg9] "{r13}" (arg9),
                  [arg10] "{r14}" (arg10),
                : .{ .rcx = true, .r11 = true, .memory = true }),
            else => |t| @compileError("unsupported architecture " ++ @tagName(t)),
        };
    }

    pub inline fn call11(
        syscall: Syscall,
        arg1: u64,
        arg2: u64,
        arg3: u64,
        arg4: u64,
        arg5: u64,
        arg6: u64,
        arg7: u64,
        arg8: u64,
        arg9: u64,
        arg10: u64,
        arg11: u64,
    ) i64 {
        return switch (builtin.cpu.arch) {
            .aarch64 => @panic("TODO"),
            .riscv64 => @panic("TODO"),
            .x86_64 => asm volatile ("syscall"
                : [ret] "={rax}" (-> i64),
                : [syscall] "{rax}" (syscall),
                  [arg1] "{rdi}" (arg1),
                  [arg2] "{rsi}" (arg2),
                  [arg3] "{rdx}" (arg3),
                  [arg4] "{rbx}" (arg4),
                  [arg5] "{r8}" (arg5),
                  [arg6] "{r9}" (arg6),
                  [arg7] "{r10}" (arg7),
                  [arg8] "{r12}" (arg8),
                  [arg9] "{r13}" (arg9),
                  [arg10] "{r14}" (arg10),
                  [arg11] "{r15}" (arg11),
                : .{ .rcx = true, .r11 = true, .memory = true }),
            else => |t| @compileError("unsupported architecture " ++ @tagName(t)),
        };
    }

    pub inline fn call12(
        syscall: Syscall,
        arg1: u64,
        arg2: u64,
        arg3: u64,
        arg4: u64,
        arg5: u64,
        arg6: u64,
        arg7: u64,
        arg8: u64,
        arg9: u64,
        arg10: u64,
        arg11: u64,
        arg12: u64,
    ) i64 {
        return switch (builtin.cpu.arch) {
            .aarch64 => @panic("TODO"),
            .riscv64 => @panic("TODO"),
            .x86_64 => asm volatile ("syscall"
                : [ret] "={rax}" (-> i64),
                : [syscall] "{rax}" (syscall),
                  [arg1] "{rdi}" (arg1),
                  [arg2] "{rsi}" (arg2),
                  [arg3] "{rdx}" (arg3),
                  [arg4] "{rbx}" (arg4),
                  [arg5] "{r8}" (arg5),
                  [arg6] "{r9}" (arg6),
                  [arg7] "{r10}" (arg7),
                  [arg8] "{r12}" (arg8),
                  [arg9] "{r13}" (arg9),
                  [arg10] "{r14}" (arg10),
                  [arg11] "{r15}" (arg11),
                  [arg12] "{rbp}" (arg12),
                : .{ .rcx = true, .r11 = true, .memory = true }),
            else => |t| @compileError("unsupported architecture " ++ @tagName(t)),
        };
    }
};
