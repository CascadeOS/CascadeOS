// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const builtin = @import("builtin");

pub const Syscall = enum(usize) {
    exit_thread = 0,

    pub inline fn zeroArg(
        syscall: Syscall,
    ) usize {
        return switch (builtin.cpu.arch) {
            .aarch64 => @panic("TODO"),
            .riscv64 => @panic("TODO"),
            .x86_64 => asm volatile ("syscall"
                : [ret] "={rax}" (-> usize),
                : [syscall] "{rdi}" (syscall),
                : .{ .rcx = true, .r11 = true, .memory = true }),
            else => |t| @compileError("unsupported architecture " ++ @tagName(t)),
        };
    }

    pub inline fn oneArg(
        syscall: Syscall,
        arg1: usize,
    ) usize {
        return switch (builtin.cpu.arch) {
            .aarch64 => @panic("TODO"),
            .riscv64 => @panic("TODO"),
            .x86_64 => asm volatile ("syscall"
                : [ret] "={rax}" (-> usize),
                : [syscall] "{rdi}" (syscall),
                  [arg1] "{rsi}" (arg1),
                : .{ .rcx = true, .r11 = true, .memory = true }),
            else => |t| @compileError("unsupported architecture " ++ @tagName(t)),
        };
    }

    pub inline fn twoArg(
        syscall: Syscall,
        arg1: usize,
        arg2: usize,
    ) usize {
        return switch (builtin.cpu.arch) {
            .aarch64 => @panic("TODO"),
            .riscv64 => @panic("TODO"),
            .x86_64 => asm volatile ("syscall"
                : [ret] "={rax}" (-> usize),
                : [syscall] "{rdi}" (syscall),
                  [arg1] "{rsi}" (arg1),
                  [arg2] "{rdx}" (arg2),
                : .{ .rcx = true, .r11 = true, .memory = true }),
            else => |t| @compileError("unsupported architecture " ++ @tagName(t)),
        };
    }

    pub inline fn threeArg(
        syscall: Syscall,
        arg1: usize,
        arg2: usize,
        arg3: usize,
    ) usize {
        return switch (builtin.cpu.arch) {
            .aarch64 => @panic("TODO"),
            .riscv64 => @panic("TODO"),
            .x86_64 => asm volatile ("syscall"
                : [ret] "={rax}" (-> usize),
                : [syscall] "{rdi}" (syscall),
                  [arg1] "{rsi}" (arg1),
                  [arg2] "{rdx}" (arg2),
                  [arg3] "{rax}" (arg3),
                : .{ .rcx = true, .r11 = true, .memory = true }),
            else => |t| @compileError("unsupported architecture " ++ @tagName(t)),
        };
    }

    pub inline fn fourArg(
        syscall: Syscall,
        arg1: usize,
        arg2: usize,
        arg3: usize,
        arg4: usize,
    ) usize {
        return switch (builtin.cpu.arch) {
            .aarch64 => @panic("TODO"),
            .riscv64 => @panic("TODO"),
            .x86_64 => asm volatile ("syscall"
                : [ret] "={rax}" (-> usize),
                : [syscall] "{rdi}" (syscall),
                  [arg1] "{rsi}" (arg1),
                  [arg2] "{rdx}" (arg2),
                  [arg3] "{rax}" (arg3),
                  [arg4] "{r8}" (arg4),
                : .{ .rcx = true, .r11 = true, .memory = true }),
            else => |t| @compileError("unsupported architecture " ++ @tagName(t)),
        };
    }

    pub inline fn fiveArg(
        syscall: Syscall,
        arg1: usize,
        arg2: usize,
        arg3: usize,
        arg4: usize,
        arg5: usize,
    ) usize {
        return switch (builtin.cpu.arch) {
            .aarch64 => @panic("TODO"),
            .riscv64 => @panic("TODO"),
            .x86_64 => asm volatile ("syscall"
                : [ret] "={rax}" (-> usize),
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

    pub inline fn sixArg(
        syscall: Syscall,
        arg1: usize,
        arg2: usize,
        arg3: usize,
        arg4: usize,
        arg5: usize,
        arg6: usize,
    ) usize {
        return switch (builtin.cpu.arch) {
            .aarch64 => @panic("TODO"),
            .riscv64 => @panic("TODO"),
            .x86_64 => asm volatile ("syscall"
                : [ret] "={rax}" (-> usize),
                : [syscall] "{rdi}" (syscall),
                  [arg1] "{rsi}" (arg1),
                  [arg2] "{rdx}" (arg2),
                  [arg3] "{rax}" (arg3),
                  [arg4] "{r8}" (arg4),
                  [arg5] "{r9}" (arg5),
                  [arg6] "{r10}" (arg6),
                : .{ .rcx = true, .r11 = true, .memory = true }),
            else => |t| @compileError("unsupported architecture " ++ @tagName(t)),
        };
    }
};
