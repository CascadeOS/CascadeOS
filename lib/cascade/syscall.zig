// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const builtin = @import("builtin");

pub const Syscall = enum(usize) {
    exit_thread = 0,

    pub inline fn call0(
        syscall: Syscall,
    ) isize {
        return switch (builtin.cpu.arch) {
            .aarch64 => @panic("TODO"),
            .riscv64 => @panic("TODO"),
            .x86_64 => asm volatile ("syscall"
                : [ret] "={rax}" (-> isize),
                : [syscall] "{rdi}" (syscall),
                : .{ .rcx = true, .r11 = true, .memory = true }),
            else => |t| @compileError("unsupported architecture " ++ @tagName(t)),
        };
    }

    pub inline fn call1(
        syscall: Syscall,
        arg1: usize,
    ) isize {
        return switch (builtin.cpu.arch) {
            .aarch64 => @panic("TODO"),
            .riscv64 => @panic("TODO"),
            .x86_64 => asm volatile ("syscall"
                : [ret] "={rax}" (-> isize),
                : [syscall] "{rdi}" (syscall),
                  [arg1] "{rsi}" (arg1),
                : .{ .rcx = true, .r11 = true, .memory = true }),
            else => |t| @compileError("unsupported architecture " ++ @tagName(t)),
        };
    }

    pub inline fn call2(
        syscall: Syscall,
        arg1: usize,
        arg2: usize,
    ) isize {
        return switch (builtin.cpu.arch) {
            .aarch64 => @panic("TODO"),
            .riscv64 => @panic("TODO"),
            .x86_64 => asm volatile ("syscall"
                : [ret] "={rax}" (-> isize),
                : [syscall] "{rdi}" (syscall),
                  [arg1] "{rsi}" (arg1),
                  [arg2] "{rdx}" (arg2),
                : .{ .rcx = true, .r11 = true, .memory = true }),
            else => |t| @compileError("unsupported architecture " ++ @tagName(t)),
        };
    }

    pub inline fn call3(
        syscall: Syscall,
        arg1: usize,
        arg2: usize,
        arg3: usize,
    ) isize {
        return switch (builtin.cpu.arch) {
            .aarch64 => @panic("TODO"),
            .riscv64 => @panic("TODO"),
            .x86_64 => asm volatile ("syscall"
                : [ret] "={rax}" (-> isize),
                : [syscall] "{rdi}" (syscall),
                  [arg1] "{rsi}" (arg1),
                  [arg2] "{rdx}" (arg2),
                  [arg3] "{rax}" (arg3),
                : .{ .rcx = true, .r11 = true, .memory = true }),
            else => |t| @compileError("unsupported architecture " ++ @tagName(t)),
        };
    }

    pub inline fn call4(
        syscall: Syscall,
        arg1: usize,
        arg2: usize,
        arg3: usize,
        arg4: usize,
    ) isize {
        return switch (builtin.cpu.arch) {
            .aarch64 => @panic("TODO"),
            .riscv64 => @panic("TODO"),
            .x86_64 => asm volatile ("syscall"
                : [ret] "={rax}" (-> isize),
                : [syscall] "{rdi}" (syscall),
                  [arg1] "{rsi}" (arg1),
                  [arg2] "{rdx}" (arg2),
                  [arg3] "{rax}" (arg3),
                  [arg4] "{r8}" (arg4),
                : .{ .rcx = true, .r11 = true, .memory = true }),
            else => |t| @compileError("unsupported architecture " ++ @tagName(t)),
        };
    }

    pub inline fn call5(
        syscall: Syscall,
        arg1: usize,
        arg2: usize,
        arg3: usize,
        arg4: usize,
        arg5: usize,
    ) isize {
        return switch (builtin.cpu.arch) {
            .aarch64 => @panic("TODO"),
            .riscv64 => @panic("TODO"),
            .x86_64 => asm volatile ("syscall"
                : [ret] "={rax}" (-> isize),
                : [syscall] "{rdi}" (syscall),
                  [arg1] "{rsi}" (arg1),
                  [arg2] "{rdx}" (arg2),
                  [arg3] "{rax}" (arg3),
                  [arg4] "{r8}" (arg4),
                  [arg5] "{r9}" (arg5),
                : .{ .rcx = true, .r11 = true, .memory = true }),
            else => |t| @compileError("unsupported architecture " ++ @tagName(t)),
        };
    }

    pub inline fn call6(
        syscall: Syscall,
        arg1: usize,
        arg2: usize,
        arg3: usize,
        arg4: usize,
        arg5: usize,
        arg6: usize,
    ) isize {
        return switch (builtin.cpu.arch) {
            .aarch64 => @panic("TODO"),
            .riscv64 => @panic("TODO"),
            .x86_64 => asm volatile ("syscall"
                : [ret] "={rax}" (-> isize),
                : [syscall] "{rdi}" (syscall),
                  [arg1] "{rsi}" (arg1),
                  [arg2] "{rdx}" (arg2),
                  [arg3] "{rax}" (arg3),
                  [arg4] "{r8}" (arg4),
                  [arg5] "{r9}" (arg5),
                  [arg6] "{rbx}" (arg6),
                : .{ .rcx = true, .r11 = true, .memory = true }),
            else => |t| @compileError("unsupported architecture " ++ @tagName(t)),
        };
    }

    pub inline fn call7(
        syscall: Syscall,
        arg1: usize,
        arg2: usize,
        arg3: usize,
        arg4: usize,
        arg5: usize,
        arg6: usize,
        arg7: usize,
    ) isize {
        return switch (builtin.cpu.arch) {
            .aarch64 => @panic("TODO"),
            .riscv64 => @panic("TODO"),
            .x86_64 => asm volatile ("syscall"
                : [ret] "={rax}" (-> isize),
                : [syscall] "{rdi}" (syscall),
                  [arg1] "{rsi}" (arg1),
                  [arg2] "{rdx}" (arg2),
                  [arg3] "{rax}" (arg3),
                  [arg4] "{r8}" (arg4),
                  [arg5] "{r9}" (arg5),
                  [arg6] "{rbx}" (arg6),
                  [arg7] "{r10}" (arg7),
                : .{ .rcx = true, .r11 = true, .memory = true }),
            else => |t| @compileError("unsupported architecture " ++ @tagName(t)),
        };
    }

    pub inline fn call8(
        syscall: Syscall,
        arg1: usize,
        arg2: usize,
        arg3: usize,
        arg4: usize,
        arg5: usize,
        arg6: usize,
        arg7: usize,
        arg8: usize,
    ) isize {
        return switch (builtin.cpu.arch) {
            .aarch64 => @panic("TODO"),
            .riscv64 => @panic("TODO"),
            .x86_64 => asm volatile ("syscall"
                : [ret] "={rax}" (-> isize),
                : [syscall] "{rdi}" (syscall),
                  [arg1] "{rsi}" (arg1),
                  [arg2] "{rdx}" (arg2),
                  [arg3] "{rax}" (arg3),
                  [arg4] "{r8}" (arg4),
                  [arg5] "{r9}" (arg5),
                  [arg6] "{rbx}" (arg6),
                  [arg7] "{r10}" (arg7),
                  [arg8] "{r12}" (arg8),
                : .{ .rcx = true, .r11 = true, .memory = true }),
            else => |t| @compileError("unsupported architecture " ++ @tagName(t)),
        };
    }

    pub inline fn call9(
        syscall: Syscall,
        arg1: usize,
        arg2: usize,
        arg3: usize,
        arg4: usize,
        arg5: usize,
        arg6: usize,
        arg7: usize,
        arg8: usize,
        arg9: usize,
    ) isize {
        return switch (builtin.cpu.arch) {
            .aarch64 => @panic("TODO"),
            .riscv64 => @panic("TODO"),
            .x86_64 => asm volatile ("syscall"
                : [ret] "={rax}" (-> isize),
                : [syscall] "{rdi}" (syscall),
                  [arg1] "{rsi}" (arg1),
                  [arg2] "{rdx}" (arg2),
                  [arg3] "{rax}" (arg3),
                  [arg4] "{r8}" (arg4),
                  [arg5] "{r9}" (arg5),
                  [arg6] "{rbx}" (arg6),
                  [arg7] "{r10}" (arg7),
                  [arg8] "{r12}" (arg8),
                  [arg9] "{r13}" (arg9),
                : .{ .rcx = true, .r11 = true, .memory = true }),
            else => |t| @compileError("unsupported architecture " ++ @tagName(t)),
        };
    }

    pub inline fn call10(
        syscall: Syscall,
        arg1: usize,
        arg2: usize,
        arg3: usize,
        arg4: usize,
        arg5: usize,
        arg6: usize,
        arg7: usize,
        arg8: usize,
        arg9: usize,
        arg10: usize,
    ) isize {
        return switch (builtin.cpu.arch) {
            .aarch64 => @panic("TODO"),
            .riscv64 => @panic("TODO"),
            .x86_64 => asm volatile ("syscall"
                : [ret] "={rax}" (-> isize),
                : [syscall] "{rdi}" (syscall),
                  [arg1] "{rsi}" (arg1),
                  [arg2] "{rdx}" (arg2),
                  [arg3] "{rax}" (arg3),
                  [arg4] "{r8}" (arg4),
                  [arg5] "{r9}" (arg5),
                  [arg6] "{rbx}" (arg6),
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
        arg1: usize,
        arg2: usize,
        arg3: usize,
        arg4: usize,
        arg5: usize,
        arg6: usize,
        arg7: usize,
        arg8: usize,
        arg9: usize,
        arg10: usize,
        arg11: usize,
    ) isize {
        return switch (builtin.cpu.arch) {
            .aarch64 => @panic("TODO"),
            .riscv64 => @panic("TODO"),
            .x86_64 => asm volatile ("syscall"
                : [ret] "={rax}" (-> isize),
                : [syscall] "{rdi}" (syscall),
                  [arg1] "{rsi}" (arg1),
                  [arg2] "{rdx}" (arg2),
                  [arg3] "{rax}" (arg3),
                  [arg4] "{r8}" (arg4),
                  [arg5] "{r9}" (arg5),
                  [arg6] "{rbx}" (arg6),
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
        arg1: usize,
        arg2: usize,
        arg3: usize,
        arg4: usize,
        arg5: usize,
        arg6: usize,
        arg7: usize,
        arg8: usize,
        arg9: usize,
        arg10: usize,
        arg11: usize,
        arg12: usize,
    ) isize {
        return switch (builtin.cpu.arch) {
            .aarch64 => @panic("TODO"),
            .riscv64 => @panic("TODO"),
            .x86_64 => asm volatile ("syscall"
                : [ret] "={rax}" (-> isize),
                : [syscall] "{rdi}" (syscall),
                  [arg1] "{rsi}" (arg1),
                  [arg2] "{rdx}" (arg2),
                  [arg3] "{rax}" (arg3),
                  [arg4] "{r8}" (arg4),
                  [arg5] "{r9}" (arg5),
                  [arg6] "{rbx}" (arg6),
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
