// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const builtin = @import("builtin");
const cascade = @import("cascade");

/// This entry point must be exposed from the root file like `pub export const _start = cascade._cascade_start;`
pub fn _cascade_start() callconv(.naked) noreturn {
    if (builtin.unwind_tables != .none or !builtin.strip_debug_info) {
        switch (builtin.cpu.arch) {
            .aarch64 => asm volatile (".cfi_undefined lr"),
            .riscv64 => if (builtin.zig_backend != .stage2_riscv64) asm volatile (".cfi_undefined ra"),
            .x86_64 => asm volatile (".cfi_undefined %%rip"),
            else => |t| @compileError("unsupported architecture " ++ @tagName(t)),
        }
    }

    if (builtin.cpu.arch == .riscv64 and builtin.zig_backend != .stage2_riscv64) {
        asm volatile (
            \\ .weak __global_pointer$
            \\ .hidden __global_pointer$
            \\ .option push
            \\ .option norelax
            \\ lla gp, __global_pointer$
            \\ .option pop
        );
    }

    asm volatile (switch (builtin.cpu.arch) {
            .aarch64 =>
            \\mov fp, #0
            \\mov lr, #0
            \\mov x0, sp
            \\and sp, x0, #-16
            \\b %[callMainAndExit]
            ,
            .riscv64 =>
            \\li fp, 0
            \\li ra, 0
            \\mv a0, sp
            \\andi sp, sp, -16
            \\tail %[callMainAndExit]@plt
            ,
            .x86_64 =>
            \\xor %%ebp, %%ebp
            \\mov %%rsp, %%rdi
            \\and $-16, %%rsp
            \\call %[callMainAndExit:P]
            ,
            else => |t| @compileError("unsupported architecture " ++ @tagName(t)),
        }
        :
        : [callMainAndExit] "X" (&callMainAndExit),
    );
}

fn callMainAndExit(entry_stack_pointer: [*]usize) callconv(.c) noreturn {
    _ = entry_stack_pointer;

    @setRuntimeSafety(false);
    @disableInstrumentation();

    // TODO: perform relocation `std.pie.relocate`
    if (builtin.link_mode == .static and builtin.position_independent_executable) {
        @panic("position independent executables not supported");
    }

    const opt_init_array_start = @extern([*]const *const fn () callconv(.c) void, .{
        .name = "__init_array_start",
        .linkage = .weak,
    });
    const opt_init_array_end = @extern([*]const *const fn () callconv(.c) void, .{
        .name = "__init_array_end",
        .linkage = .weak,
    });
    if (opt_init_array_start) |init_array_start| {
        const init_array_end = opt_init_array_end.?;
        const slice = init_array_start[0 .. init_array_end - init_array_start];
        for (slice) |func| func();
    }

    std.os.argv = &.{};
    std.os.environ = &.{};

    // TODO: register segfault handler (if that is even what it is going to be called)

    const return_value = std.start.callMain();
    _ = return_value; // TODO: don't just throw this away

    // TODO: exit the process rather than just the current thread
    cascade.exitThread();
}
